#!/usr/bin/env python3
"""Verify official Antigravity CLI release assets and update the Scoop manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile
from typing import Any
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "bucket" / "antigravity-cli.json"
RELEASE_URL = "https://api.github.com/repos/google-antigravity/antigravity-cli/releases/latest"
API_HOST = "api.github.com"
ASSET_HOSTS = {"github.com", "release-assets.githubusercontent.com"}
ASSETS = {"64bit": "agy_cli_windows_x64.zip", "arm64": "agy_cli_windows_arm64.zip"}
MAX_METADATA_BYTES = 5_000_000
MAX_PACKAGE_BYTES = 1_000_000_000


class UpdateError(Exception):
    """An official release or downloaded asset failed validation."""


def request_json(url: str) -> Any:
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "zev-scoop-antigravity-cli-updater/1.0"}
    if os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = f"Bearer {os.environ['GITHUB_TOKEN']}"
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            final = urlsplit(response.geturl())
            if final.scheme != "https" or final.hostname != API_HOST:
                raise UpdateError(f"Refusing non-official metadata redirect: {response.geturl()}")
            raw = response.read(MAX_METADATA_BYTES + 1)
    except (urllib.error.URLError, TimeoutError) as exc:
        raise UpdateError(f"Could not retrieve official release metadata: {exc}") from exc
    if len(raw) > MAX_METADATA_BYTES:
        raise UpdateError("Official release metadata exceeds the size limit")
    try:
        return json.loads(raw)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise UpdateError(f"Official release metadata is invalid JSON: {exc}") from exc


def select_assets(release: dict[str, Any]) -> dict[str, dict[str, str]]:
    version = release.get("tag_name")
    if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise UpdateError(f"Unexpected official release tag: {version!r}")
    if release.get("draft") or release.get("prerelease"):
        raise UpdateError("Latest official release is not a stable published release")
    assets = release.get("assets")
    if not isinstance(assets, list):
        raise UpdateError("Official GitHub release has no asset list")
    selected: dict[str, dict[str, str]] = {}
    for architecture, name in ASSETS.items():
        matches = [item for item in assets if isinstance(item, dict) and item.get("name") == name]
        if len(matches) != 1:
            raise UpdateError(f"Expected one {name} release asset; found {len(matches)}")
        item = matches[0]
        url = item.get("browser_download_url")
        api_url = item.get("url")
        asset_id = item.get("id")
        digest = item.get("digest")
        parsed = urlsplit(url if isinstance(url, str) else "")
        if parsed.scheme != "https" or parsed.hostname != "github.com":
            raise UpdateError(f"Asset URL is not the official GitHub release host: {url!r}")
        expected_path = f"/google-antigravity/antigravity-cli/releases/download/{version}/{name}"
        if parsed.path != expected_path:
            raise UpdateError(f"Asset URL does not match release/version: {url!r}")
        if not isinstance(asset_id, int) or not isinstance(api_url, str) or api_url != f"https://{API_HOST}/repos/google-antigravity/antigravity-cli/releases/assets/{asset_id}":
            raise UpdateError(f"Official release asset has an invalid API download URL: {api_url!r}")
        match = re.fullmatch(r"sha256:([0-9a-fA-F]{64})", digest if isinstance(digest, str) else "")
        if not match:
            raise UpdateError(f"Official release has no SHA256 digest for {name}")
        selected[architecture] = {"url": url, "download_url": api_url, "hash": match.group(1).lower()}
    return selected


def verify_asset(url: str, expected_hash: str) -> None:
    headers = {"Accept": "application/octet-stream", "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "zev-scoop-antigravity-cli-updater/1.0"}
    if os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = f"Bearer {os.environ['GITHUB_TOKEN']}"
    request = urllib.request.Request(url, headers=headers)
    digest = hashlib.sha256()
    size = 0
    with tempfile.TemporaryDirectory(prefix="antigravity-cli-verify-") as temporary:
        archive_path = Path(temporary) / "agy-cli.zip"
        try:
            with urllib.request.urlopen(request, timeout=90) as response, archive_path.open("wb") as output:
                final = urlsplit(response.geturl())
                if final.scheme != "https" or final.hostname not in ASSET_HOSTS:
                    raise UpdateError(f"Refusing unexpected asset redirect: {response.geturl()}")
                while chunk := response.read(1024 * 1024):
                    size += len(chunk)
                    if size > MAX_PACKAGE_BYTES:
                        raise UpdateError("Release asset exceeds the configured size limit")
                    digest.update(chunk)
                    output.write(chunk)
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise UpdateError(f"Asset download failed for {url}: {exc}") from exc
        actual = digest.hexdigest()
        if actual != expected_hash.lower():
            raise UpdateError(f"SHA256 mismatch: expected {expected_hash}, got {actual}")
        validate_archive(archive_path)


def validate_archive(path: Path) -> list[str]:
    try:
        with zipfile.ZipFile(path) as archive:
            names = [entry.filename for entry in archive.infolist() if not entry.is_dir()]
    except (zipfile.BadZipFile, OSError) as exc:
        raise UpdateError(f"Official release asset is not a valid ZIP: {exc}") from exc
    normalized = [name.replace("\\", "/") for name in names]
    if "antigravity.exe" not in normalized or any(
        name.startswith("/") or re.match(r"^[A-Za-z]:", name) or ".." in name.split("/")
        for name in normalized
    ):
        raise UpdateError(f"Unexpected ZIP structure; expected a safe archive containing antigravity.exe: {names!r}")
    return normalized


def read_manifest() -> dict[str, Any]:
    try:
        value = json.loads(MANIFEST.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise UpdateError(f"Cannot read manifest: {exc}") from exc
    if not isinstance(value, dict):
        raise UpdateError("Manifest root must be an object")
    return value


def atomic_write(value: dict[str, Any]) -> None:
    fd, name = tempfile.mkstemp(prefix="antigravity-cli-", suffix=".json", dir=MANIFEST.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=4)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, MANIFEST)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def update(*, verify_current: bool = False) -> dict[str, Any]:
    release = request_json(RELEASE_URL)
    if not isinstance(release, dict):
        raise UpdateError("Official GitHub release response root must be an object")
    version = str(release.get("tag_name", ""))
    assets = select_assets(release)
    current = read_manifest()
    if verify_current and current.get("version") == version:
        for architecture, asset in assets.items():
            verify_asset(asset["download_url"], asset["hash"])
        return {"changed": False, "version": version, "verified_architectures": list(assets)}
    if current.get("version") == version:
        return {"changed": False, "version": version}
    for asset in assets.values():
        verify_asset(asset["download_url"], asset["hash"])
    updated = dict(current)
    updated["version"] = version
    updated["architecture"] = {
        architecture: {"url": asset["url"], "hash": asset["hash"]}
        for architecture, asset in assets.items()
    }
    atomic_write(updated)
    return {"changed": True, "old_version": current.get("version"), "new_version": version, "architectures": list(assets)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Check latest version without downloading assets")
    parser.add_argument("--verify-current", action="store_true", help="Download and verify current manifest assets")
    args = parser.parse_args()
    try:
        if args.check:
            release = request_json(RELEASE_URL)
            current = read_manifest()
            result = {"changed": current.get("version") != release.get("tag_name"), "current_version": current.get("version"), "latest_version": release.get("tag_name"), "source": RELEASE_URL}
        else:
            result = update(verify_current=args.verify_current)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (UpdateError, OSError, ValueError, TypeError, KeyError) as exc:
        print(f"update-antigravity-cli: error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
