#!/usr/bin/env python3
"""Verify and update the Qoder CN CLI manifest from its official channel feed."""

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
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "bucket" / "qoder-cn-cli.json"
CHANNEL_URL = "https://static.qoder.com.cn/qoder-cli-cn/channels/manifest.json"
OFFICIAL_HOST = "static.qoder.com.cn"
MAX_METADATA_BYTES = 1_000_000
MAX_PACKAGE_BYTES = 1_000_000_000


class UpdateError(Exception):
    """The official channel or package could not be verified."""


def fetch(url: str, *, max_bytes: int | None = None) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "zev-scoop-qoder-cn-updater/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            final = urlsplit(response.geturl())
            if final.scheme != "https" or final.hostname != OFFICIAL_HOST:
                raise UpdateError(f"Refusing non-official redirect: {response.geturl()}")
            data = response.read(max_bytes + 1 if max_bytes else -1)
    except (urllib.error.URLError, TimeoutError) as exc:
        raise UpdateError(f"Request failed for {url}: {exc}") from exc
    if max_bytes is not None and len(data) > max_bytes:
        raise UpdateError(f"Response exceeds size limit: {url}")
    return data


def load_channel(url: str = CHANNEL_URL) -> dict[str, Any]:
    try:
        value = json.loads(fetch(url, max_bytes=MAX_METADATA_BYTES))
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise UpdateError(f"Official channel feed is invalid JSON: {exc}") from exc
    if not isinstance(value, dict) or not isinstance(value.get("latest"), str):
        raise UpdateError("Official channel feed has no latest version")
    if not re.fullmatch(r"\d+\.\d+\.\d+", value["latest"]):
        raise UpdateError(f"Unexpected stable version: {value['latest']!r}")
    return value


def select_windows_x64(channel: dict[str, Any], version: str | None = None) -> dict[str, str]:
    version = version or channel["latest"]
    matches = [
        row for row in channel.get("files", [])
        if isinstance(row, dict) and row.get("os") == "windows" and
        row.get("arch") in {"amd64", "x64"} and row.get("variant") == "standard"
    ]
    if len(matches) != 1:
        raise UpdateError(f"Expected one standard Windows x64 artifact, got {len(matches)}")
    row = matches[0]
    url, digest = row.get("url"), row.get("sha256")
    expected = f"/qoder-cli-cn/releases/{version}/qoderclicn-windows-x64.zip"
    parsed = urlsplit(url if isinstance(url, str) else "")
    if parsed.scheme != "https" or parsed.hostname != OFFICIAL_HOST or parsed.path != expected:
        raise UpdateError(f"Unexpected official artifact URL: {url!r}")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", digest):
        raise UpdateError("Official feed does not contain a valid SHA256")
    if int(row.get("min_windows_build", 0)) > 17763:
        raise UpdateError("The standard x64 artifact exceeds the declared Windows 10 baseline")
    return {"url": url, "hash": digest.lower()}


def verify_artifact(url: str, expected_hash: str) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": "zev-scoop-qoder-cn-updater/1.0"})
    digest = hashlib.sha256()
    size = 0
    with tempfile.TemporaryDirectory(prefix="qoder-cn-cli-verify-") as temporary:
        archive_path = Path(temporary) / "qoderclicn.zip"
        try:
            with urllib.request.urlopen(request, timeout=90) as response, archive_path.open("wb") as output:
                final = urlsplit(response.geturl())
                if final.scheme != "https" or final.hostname != OFFICIAL_HOST:
                    raise UpdateError(f"Refusing non-official artifact redirect: {response.geturl()}")
                while chunk := response.read(1024 * 1024):
                    size += len(chunk)
                    if size > MAX_PACKAGE_BYTES:
                        raise UpdateError("Package exceeds the configured size limit")
                    digest.update(chunk)
                    output.write(chunk)
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise UpdateError(f"Package download failed: {exc}") from exc
        actual = digest.hexdigest()
        if actual != expected_hash.lower():
            raise UpdateError(f"SHA256 mismatch: expected {expected_hash}, got {actual}")
        validate_archive(archive_path)


ALLOWED_DOC_EXTENSIONS = {"", ".txt", ".md"}
ALLOWED_DOC_STEM_KEYWORDS = ("LICENSE", "NOTICE", "COPYING", "README", "CHANGELOG")


def is_allowed_doc_file(name: str) -> bool:
    if "/" in name:
        return False
    path_obj = Path(name)
    if path_obj.suffix.lower() not in ALLOWED_DOC_EXTENSIONS:
        return False
    upper_stem = path_obj.stem.upper()
    return any(keyword in upper_stem for keyword in ALLOWED_DOC_STEM_KEYWORDS)


def validate_archive(path: Path) -> list[str]:
    try:
        with zipfile.ZipFile(path) as archive:
            files = [item.filename for item in archive.infolist() if not item.is_dir()]
    except (zipfile.BadZipFile, OSError) as exc:
        raise UpdateError(f"Official artifact is not a valid ZIP: {exc}") from exc
    normalized = [name.replace("\\", "/") for name in files]
    if any(name.startswith("/") or re.match(r"^[A-Za-z]:", name) or ".." in name.split("/") for name in normalized):
        raise UpdateError(f"Unsafe path in official archive: {files!r}")
    required_exe = "qoderclicn.exe"
    if required_exe not in normalized or any(name != required_exe and not is_allowed_doc_file(name) for name in normalized):
        raise UpdateError(f"Unexpected archive contents: {files!r}")
    return normalized


def read_manifest() -> dict[str, Any]:
    try:
        data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise UpdateError(f"Cannot read manifest: {exc}") from exc
    if not isinstance(data, dict):
        raise UpdateError("Manifest root must be an object")
    return data


def atomic_write(data: dict[str, Any]) -> None:
    fd, name = tempfile.mkstemp(prefix="qoder-cn-cli-", suffix=".json", dir=MANIFEST.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(data, stream, ensure_ascii=False, indent=4)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, MANIFEST)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def update(*, verify_current: bool = False) -> dict[str, Any]:
    channel = load_channel()
    candidate = select_windows_x64(channel)
    current = read_manifest()
    version = channel["latest"]
    if verify_current and current.get("version") == version:
        verify_artifact(candidate["url"], candidate["hash"])
        return {"changed": False, "version": version, "verified": True, **candidate}
    if current.get("version") == version:
        return {"changed": False, "version": version, **candidate}
    verify_artifact(candidate["url"], candidate["hash"])
    updated = dict(current)
    updated["version"] = version
    updated["architecture"] = {"64bit": candidate}
    atomic_write(updated)
    return {"changed": True, "old_version": current.get("version"), "new_version": version, **candidate}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Check versions without downloading")
    parser.add_argument("--verify-current", action="store_true", help="Download and verify the current manifest artifact")
    args = parser.parse_args()
    try:
        if args.check:
            channel = load_channel()
            current = read_manifest()
            result = {"changed": current.get("version") != channel["latest"], "current_version": current.get("version"), "latest_version": channel["latest"], "source": CHANNEL_URL}
        else:
            result = update(verify_current=args.verify_current)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (UpdateError, OSError, ValueError, TypeError, KeyError) as exc:
        print(f"update-qoder-cn-cli: error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
