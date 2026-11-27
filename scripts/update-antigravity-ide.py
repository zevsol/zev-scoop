#!/usr/bin/env python3
"""Verify official Antigravity IDE installers and update the Scoop manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "bucket" / "antigravity-ide.json"
DOWNLOAD_PAGE_URL = "https://antigravity.google/download"
PAGE_HOST = "antigravity.google"
ASSET_HOST = "edgedl.me.gvt1.com"
USER_AGENT = "zev-scoop-antigravity-ide-updater/1.0"
MAX_PAGE_BYTES = 5_000_000
MAX_PACKAGE_BYTES = 1_000_000_000
URL_PATTERN = re.compile(
    r"https://edgedl\.me\.gvt1\.com/edgedl/release2/j0qc3/antigravity/stable/"
    r"(\d+\.\d+\.\d+)-(\d+)/windows-(x64|arm64)/Antigravity%20IDE\.exe"
)
ARCH_MAP = {"x64": "64bit", "arm64": "arm64"}


class UpdateError(Exception):
    """An official download page or installer failed verification."""


def fetch_download_page(url: str = DOWNLOAD_PAGE_URL) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            final = urlsplit(response.geturl())
            if final.scheme != "https" or final.hostname != PAGE_HOST:
                raise UpdateError(f"Refusing non-official download page redirect: {response.geturl()}")
            raw = response.read(MAX_PAGE_BYTES + 1)
    except (urllib.error.URLError, TimeoutError) as exc:
        raise UpdateError(f"Could not retrieve official download page: {exc}") from exc
    if len(raw) > MAX_PAGE_BYTES:
        raise UpdateError("Official download page exceeds the configured size limit")
    return raw.decode("utf-8", errors="replace")


def parse_download_page(html: str) -> dict[str, Any]:
    found: dict[str, list[tuple[str, str, str]]] = {"64bit": [], "arm64": []}
    for match in URL_PATTERN.finditer(html):
        version, build, raw_arch = match.groups()
        arch = ARCH_MAP[raw_arch]
        entry = (version, build, match.group(0))
        if entry not in found[arch]:
            found[arch].append(entry)

    for arch in ("64bit", "arm64"):
        if len(found[arch]) != 1:
            raise UpdateError(f"Expected one unique Windows {arch} Antigravity IDE URL; found {len(found[arch])}")

    x64_ver, x64_build, x64_url = found["64bit"][0]
    arm_ver, arm_build, arm_url = found["arm64"][0]
    if (x64_ver, x64_build) != (arm_ver, arm_build):
        raise UpdateError(
            f"Antigravity IDE Windows architectures disagree on version/build: "
            f"64bit={x64_ver}-{x64_build}, arm64={arm_ver}-{arm_build}"
        )

    return {
        "version": x64_ver,
        "build": x64_build,
        "architecture": {"64bit": x64_url, "arm64": arm_url},
    }


def verify_authenticode(installer_path: Path) -> None:
    shell = shutil.which("pwsh") or shutil.which("powershell.exe")
    if not shell:
        raise UpdateError("PowerShell is required to verify the Windows Authenticode signature")
    command = (
        "Import-Module Microsoft.PowerShell.Security -ErrorAction Stop; "
        "$sig = Get-AuthenticodeSignature -LiteralPath $env:ZEV_INSTALLER_PATH; "
        "if ($sig.Status -ne 'Valid') { throw \"Invalid Authenticode status: $($sig.Status)\" }; "
        "$subj = [string]$sig.SignerCertificate.Subject; "
        "if ($subj -notmatch 'CN=Google LLC' -or $subj -notmatch 'O=Google LLC') { "
        "throw \"Unexpected signer subject: $subj\" }"
    )
    env = dict(os.environ)
    env["ZEV_INSTALLER_PATH"] = str(installer_path)
    result = subprocess.run(
        [shell, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command],
        capture_output=True,
        text=True,
        errors="replace",
        env=env,
        timeout=60,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        raise UpdateError(f"Authenticode signature verification failed: {detail}")


def download_and_verify_installer(url: str) -> str:
    parsed = urlsplit(url)
    if parsed.scheme != "https" or parsed.hostname != ASSET_HOST:
        raise UpdateError(f"Refusing non-official installer URL: {url!r}")
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    digest = hashlib.sha256()
    size = 0
    with tempfile.TemporaryDirectory(prefix="antigravity-ide-verify-") as temporary:
        installer_path = Path(temporary) / "AntigravityIDE.exe"
        try:
            with urllib.request.urlopen(request, timeout=180) as response, installer_path.open("wb") as output:
                final = urlsplit(response.geturl())
                if final.scheme != "https" or final.hostname != ASSET_HOST:
                    raise UpdateError(f"Refusing non-official installer redirect: {response.geturl()}")
                while chunk := response.read(1024 * 1024):
                    size += len(chunk)
                    if size > MAX_PACKAGE_BYTES:
                        raise UpdateError("Installer exceeds the configured size limit")
                    digest.update(chunk)
                    output.write(chunk)
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise UpdateError(f"Installer download failed for {url}: {exc}") from exc
        if os.name == "nt":
            verify_authenticode(installer_path)
    return digest.hexdigest().lower()


def read_manifest() -> dict[str, Any]:
    try:
        value = json.loads(MANIFEST.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise UpdateError(f"Cannot read manifest: {exc}") from exc
    if not isinstance(value, dict):
        raise UpdateError("Manifest root must be an object")
    return value


def atomic_write(value: dict[str, Any]) -> None:
    fd, name = tempfile.mkstemp(prefix="antigravity-ide-", suffix=".json", dir=MANIFEST.parent)
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
    release = parse_download_page(fetch_download_page())
    current = read_manifest()
    current_arch = current.get("architecture", {})
    same_version = current.get("version") == release["version"]
    same_urls = all(
        isinstance(current_arch.get(arch), dict) and current_arch[arch].get("url") == url
        for arch, url in release["architecture"].items()
    )
    if same_version and same_urls and not verify_current:
        return {"changed": False, "version": release["version"], "build": release["build"]}

    verified_arch: dict[str, dict[str, str]] = {}
    for arch, url in release["architecture"].items():
        sha256 = download_and_verify_installer(url)
        if verify_current and same_version and same_urls:
            expected_hash = str(current_arch[arch].get("hash", "")).lower()
            if sha256 != expected_hash:
                raise UpdateError(f"SHA256 mismatch for {arch}: expected {expected_hash}, got {sha256}")
        verified_arch[arch] = {"url": url, "hash": sha256}

    if verify_current and same_version and same_urls:
        return {
            "changed": False,
            "version": release["version"],
            "build": release["build"],
            "verified_architectures": list(verified_arch),
        }

    updated = dict(current)
    updated["version"] = release["version"]
    updated["architecture"] = verified_arch
    atomic_write(updated)
    return {
        "changed": True,
        "old_version": current.get("version"),
        "new_version": release["version"],
        "build": release["build"],
        "architectures": list(verified_arch),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Check latest version without downloading installers")
    parser.add_argument("--verify-current", action="store_true", help="Download and verify current manifest installers")
    args = parser.parse_args()
    try:
        if args.check:
            release = parse_download_page(fetch_download_page())
            current = read_manifest()
            current_arch = current.get("architecture", {})
            same_urls = all(
                isinstance(current_arch.get(arch), dict) and current_arch[arch].get("url") == url
                for arch, url in release["architecture"].items()
            )
            result = {
                "changed": current.get("version") != release["version"] or not same_urls,
                "current_version": current.get("version"),
                "latest_version": release["version"],
                "build": release["build"],
                "source": DOWNLOAD_PAGE_URL,
            }
        else:
            result = update(verify_current=args.verify_current)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (UpdateError, OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as exc:
        print(f"update-antigravity-ide: error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
