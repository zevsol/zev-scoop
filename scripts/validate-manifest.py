#!/usr/bin/env python3
"""Validate the Qoder Scoop manifest without third-party dependencies."""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "bucket" / "qoder-cli.json"
OFFICIAL_HOST = "qoder-ide.oss-accelerate.aliyuncs.com"


def validate(path: Path, check_url: bool = False) -> list[str]:
    errors: list[str] = []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"cannot load JSON: {exc}"]
    if not isinstance(data, dict):
        return ["manifest root must be an object"]
    for field in ("version", "description", "homepage", "license", "architecture", "bin"):
        if field not in data:
            errors.append(f"missing required field: {field}")
    version = data.get("version")
    if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+", version):
        errors.append("version must be a stable semantic version")
        version = ""
    arch = data.get("architecture", {}).get("64bit") if isinstance(data.get("architecture"), dict) else None
    if not isinstance(arch, dict):
        errors.append("architecture.64bit must be an object")
        arch = {}
    url, digest = arch.get("url"), arch.get("hash")
    parsed = urlsplit(url if isinstance(url, str) else "")
    if parsed.scheme != "https" or parsed.hostname != OFFICIAL_HOST:
        errors.append("architecture.64bit.url must use the official HTTPS Qoder download host")
    expected = f"/qodercli/releases/{version}/qodercli-windows-x64.zip"
    if parsed.path != expected:
        errors.append(f"download URL path must match manifest version: {expected}")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        errors.append("architecture.64bit.hash must be a lowercase 64-character SHA256")
    bins = data.get("bin")
    if bins != [["qodercli.exe", "qoder"]]:
        errors.append("bin must expose qodercli.exe as the qoder command")
    checkver = data.get("checkver", {})
    if checkver.get("url") != "https://qoder-ide.oss-accelerate.aliyuncs.com/qodercli/channels/manifest.json":
        errors.append("checkver must use the official Qoder channel manifest")
    if check_url and url and not errors:
        request = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "zev-scoop-validator/1.0"})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                final_url = urlsplit(response.geturl())
                if response.status != 200 or final_url.scheme != "https" or final_url.hostname != OFFICIAL_HOST:
                    errors.append(f"download URL check failed with HTTP {response.status}")
        except (urllib.error.URLError, TimeoutError) as exc:
            errors.append(f"download URL check failed: {exc}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=MANIFEST)
    parser.add_argument("--check-url", action="store_true", help="Make an HTTPS HEAD request to the package URL")
    args = parser.parse_args()
    errors = validate(args.manifest, args.check_url)
    if errors:
        for error in errors:
            print(f"validate-manifest: error: {error}", file=sys.stderr)
        return 1
    print(f"Valid manifest: {args.manifest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
