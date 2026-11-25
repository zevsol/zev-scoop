#!/usr/bin/env python3
"""Fetch and verify the official Qoder CLI release before updating its manifest."""

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

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "bucket" / "qoder-cli.json"
CHANNEL_URL = "https://qoder-ide.oss-accelerate.aliyuncs.com/qodercli/channels/manifest.json"
OFFICIAL_HOST = "qoder-ide.oss-accelerate.aliyuncs.com"
USER_AGENT = "zev-scoop-qoder-updater/1.0"
MAX_METADATA_BYTES = 1_000_000
MAX_PACKAGE_BYTES = 1_000_000_000


class UpdateError(Exception):
    """An upstream response was invalid or could not be safely verified."""


def request_bytes(url: str, *, limit: int | None = None) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            from urllib.parse import urlsplit

            final_url = urlsplit(response.geturl())
            if final_url.scheme.lower() != "https" or final_url.hostname != OFFICIAL_HOST:
                raise UpdateError(f"Refusing redirected response URL: {response.geturl()}")
            data = response.read((limit + 1) if limit else -1)
    except (urllib.error.URLError, TimeoutError) as exc:
        raise UpdateError(f"Request failed for {url}: {exc}") from exc
    if limit is not None and len(data) > limit:
        raise UpdateError(f"Response exceeded {limit} bytes: {url}")
    return data


def load_channel() -> dict[str, Any]:
    try:
        data = json.loads(request_bytes(CHANNEL_URL, limit=MAX_METADATA_BYTES))
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise UpdateError(f"Official channel metadata is not valid JSON: {exc}") from exc
    version = data.get("latest")
    if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise UpdateError("Official channel has no valid stable latest version")
    return data


def select_windows_x64(data: dict[str, Any]) -> dict[str, str]:
    candidates = [
        item
        for item in data.get("files", [])
        if isinstance(item, dict)
        and item.get("os") == "windows"
        and item.get("arch") in {"amd64", "x64"}
        and item.get("variant", "standard") != "legacy"
    ]
    if len(candidates) != 1:
        raise UpdateError(f"Expected exactly one official standard Windows x64 artifact, found {len(candidates)}")
    item = candidates[0]
    url, digest = item.get("url"), item.get("sha256")
    version = data["latest"]
    expected_path = f"/qodercli/releases/{version}/qodercli-windows-x64.zip"
    from urllib.parse import urlsplit

    parsed = urlsplit(url if isinstance(url, str) else "")
    if parsed.scheme != "https" or parsed.hostname != OFFICIAL_HOST or parsed.path != expected_path:
        raise UpdateError(f"Unexpected official artifact URL: {url!r}")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", digest):
        raise UpdateError("Official artifact metadata has no valid SHA256")
    if item.get("min_windows_build") and int(item["min_windows_build"]) > 17763:
        raise UpdateError("Artifact requires a Windows build newer than the declared Windows 10 baseline")
    return {"url": url, "hash": digest.lower()}


def read_manifest() -> dict[str, Any]:
    try:
        value = json.loads(MANIFEST.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise UpdateError(f"Cannot read current manifest {MANIFEST}: {exc}") from exc
    if not isinstance(value, dict):
        raise UpdateError("Current manifest root must be a JSON object")
    return value


def download_and_verify(url: str, expected_hash: str) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    digest = hashlib.sha256()
    size = 0
    with tempfile.TemporaryDirectory(prefix="qoder-verify-") as directory:
        archive_path = Path(directory) / "qodercli.zip"
        try:
            with urllib.request.urlopen(request, timeout=60) as response, archive_path.open("wb") as output:
                from urllib.parse import urlsplit

                final_url = urlsplit(response.geturl())
                if final_url.scheme.lower() != "https" or final_url.hostname != OFFICIAL_HOST:
                    raise UpdateError(f"Refusing redirected artifact URL: {response.geturl()}")
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    size += len(chunk)
                    if size > MAX_PACKAGE_BYTES:
                        raise UpdateError(f"Package exceeds the {MAX_PACKAGE_BYTES}-byte safety limit")
                    digest.update(chunk)
                    output.write(chunk)
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise UpdateError(f"Package download failed for {url}: {exc}") from exc
        actual_hash = digest.hexdigest()
        if actual_hash != expected_hash:
            raise UpdateError(f"SHA256 mismatch: expected {expected_hash}, got {actual_hash}")
        try:
            with zipfile.ZipFile(archive_path) as package:
                names = [entry.filename for entry in package.infolist() if not entry.is_dir()]
        except (zipfile.BadZipFile, OSError) as exc:
            raise UpdateError(f"Official artifact is not a valid ZIP: {exc}") from exc
        if names != ["qodercli.exe"]:
            raise UpdateError(f"Unexpected archive contents: {names!r}; expected only qodercli.exe")


def atomic_write(value: dict[str, Any]) -> None:
    payload = json.dumps(value, ensure_ascii=False, indent=4) + "\n"
    fd, temp_name = tempfile.mkstemp(prefix="qoder-", suffix=".json", dir=MANIFEST.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, MANIFEST)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)


def update() -> dict[str, Any]:
    channel = load_channel()
    version = channel["latest"]
    artifact = select_windows_x64(channel)
    current = read_manifest()
    old_version = current.get("version")
    if old_version == version:
        print(json.dumps({"changed": False, "version": version, "source": CHANNEL_URL}))
        return {"changed": False, "version": version, "source": CHANNEL_URL}

    # Verify the complete new package before touching the checked-in manifest.
    download_and_verify(artifact["url"], artifact["hash"])
    updated = dict(current)
    updated["version"] = version
    updated["architecture"] = {
        "64bit": {"url": artifact["url"], "hash": artifact["hash"]}
    }
    atomic_write(updated)
    result = {
        "changed": True,
        "old_version": old_version,
        "new_version": version,
        "source": CHANNEL_URL,
        "url": artifact["url"],
        "sha256": artifact["hash"],
    }
    print(json.dumps(result, ensure_ascii=False))
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Report whether an update is available without downloading")
    args = parser.parse_args()
    try:
        if args.check:
            channel = load_channel()
            current = read_manifest()
            result = {
                "changed": current.get("version") != channel["latest"],
                "current_version": current.get("version"),
                "latest_version": channel["latest"],
                "source": CHANNEL_URL,
            }
            print(json.dumps(result, ensure_ascii=False))
        else:
            update()
    except (UpdateError, OSError, ValueError, TypeError, KeyError) as exc:
        print(f"update-qoder: error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
