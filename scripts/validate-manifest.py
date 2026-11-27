#!/usr/bin/env python3
"""Validate Zev Scoop manifests without third-party dependencies."""

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
PACKAGE_RULES = {
    "qoder-cli": {"host": "qoder-ide.oss-accelerate.aliyuncs.com", "arches": ("64bit",)},
    "qoder-cn-cli": {"host": "static.qoder.com.cn", "arches": ("64bit",)},
    "antigravity-cli": {"host": "github.com", "arches": ("64bit", "arm64")},
}


def _validate_package(data: dict, package: str) -> list[str]:
    errors: list[str] = []
    if package not in PACKAGE_RULES:
        return [f"unsupported manifest filename: {package}.json"]
    rules = PACKAGE_RULES[package]
    for field in ("version", "description", "homepage", "license", "architecture", "bin"):
        if field not in data:
            errors.append(f"missing required field: {field}")
    version = data.get("version")
    if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+", version):
        errors.append("version must be a stable semantic version")
        version = ""
    architecture = data.get("architecture")
    if not isinstance(architecture, dict):
        errors.append("architecture must be an object")
        architecture = {}
    for arch in rules["arches"]:
        item = architecture.get(arch)
        if not isinstance(item, dict):
            errors.append(f"architecture.{arch} must be an object")
            continue
        parsed = urlsplit(item.get("url", "") if isinstance(item.get("url"), str) else "")
        if parsed.scheme != "https" or parsed.hostname != rules["host"]:
            errors.append(f"architecture.{arch}.url must use official HTTPS host {rules['host']}")
        digest = item.get("hash")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", digest):
            errors.append(f"architecture.{arch}.hash must be a 64-character SHA256")

    if package == "qoder-cli":
        item = architecture.get("64bit", {})
        parsed = urlsplit(item.get("url", ""))
        expected = f"/qodercli/releases/{version}/qodercli-windows-x64.zip"
        if parsed.path != expected:
            errors.append(f"download URL path must match manifest version: {expected}")
        if data.get("bin") != [["qodercli.exe", "qoder"]]:
            errors.append("bin must expose qodercli.exe as qoder")
        if data.get("checkver", {}).get("url") != "https://qoder-ide.oss-accelerate.aliyuncs.com/qodercli/channels/manifest.json":
            errors.append("checkver must use the official Qoder channel manifest")
    elif package == "qoder-cn-cli":
        item = architecture.get("64bit", {})
        parsed = urlsplit(item.get("url", ""))
        expected = f"/qoder-cli-cn/releases/{version}/qoderclicn-windows-x64.zip"
        if parsed.path != expected:
            errors.append(f"download URL path must match Qoder CN version: {expected}")
        if data.get("bin") != [["qodercn.cmd", "qodercn"], ["qodercn.cmd", "qoderclicn"]]:
            errors.append("bin must expose the isolated qodercn and qoderclicn wrapper shims")
        if data.get("persist") != "qodercn-config":
            errors.append("Qoder CN config must use its separate persisted directory")
        pre_install = "\n".join(data.get("pre_install", [])) if isinstance(data.get("pre_install"), list) else ""
        post_install = "\n".join(data.get("post_install", [])) if isinstance(data.get("post_install"), list) else ""
        if "QODERCN_CONFIG_DIR" not in pre_install or "qodercn.cmd" not in pre_install:
            errors.append("pre_install must create the Qoder CN wrapper before Scoop creates command shims")
        for expected_text in ("enableAutoUpdate", "false"):
            if expected_text not in post_install:
                errors.append(f"post_install must disable Qoder CN automatic updates: {expected_text}")
        if data.get("checkver", {}).get("url") != "https://static.qoder.com.cn/qoder-cli-cn/channels/manifest.json":
            errors.append("checkver must use the official Qoder CN channel manifest")
        autoupdate = data.get("autoupdate", {})
        if autoupdate.get("architecture", {}).get("64bit", {}).get("url") != "https://static.qoder.com.cn/qoder-cli-cn/releases/$version/qoderclicn-windows-x64.zip":
            errors.append("autoupdate must use Qoder CN's versioned x64 artifact URL")
        auto_hash = autoupdate.get("hash", {})
        if auto_hash.get("mode") != "json" or auto_hash.get("url") != "https://static.qoder.com.cn/qoder-cli-cn/channels/$version/manifest.json":
            errors.append("autoupdate hash must come from the versioned official Qoder CN channel")
    elif package == "antigravity-cli":
        for arch, suffix in (("64bit", "x64"), ("arm64", "arm64")):
            item = architecture.get(arch, {})
            parsed = urlsplit(item.get("url", ""))
            expected = f"/google-antigravity/antigravity-cli/releases/download/{version}/agy_cli_windows_{suffix}.zip"
            if parsed.path != expected:
                errors.append(f"architecture.{arch}.url must match the versioned official release asset: {expected}")
        if data.get("bin") != [["agy.cmd", "agy"]]:
            errors.append("bin must expose agy through the per-process update-control wrapper")
        pre_install = "\n".join(data.get("pre_install", [])) if isinstance(data.get("pre_install"), list) else ""
        post_install = "\n".join(data.get("post_install", [])) if isinstance(data.get("post_install"), list) else ""
        if "AGY_CLI_DISABLE_AUTO_UPDATE=true" not in pre_install or "agy.cmd" not in pre_install:
            errors.append("pre_install must create the update-isolating agy wrapper before Scoop creates its shim")
        if "antigravity.exe" not in post_install or "agy.exe" not in post_install:
            errors.append("post_install must rename the official executable to the wrapper's expected agy.exe")
        if data.get("checkver", {}).get("github") != "https://github.com/google-antigravity/antigravity-cli":
            errors.append("checkver must use the official Antigravity CLI repository")
        autoupdate = data.get("autoupdate", {})
        for arch, suffix in (("64bit", "x64"), ("arm64", "arm64")):
            expected = f"https://github.com/google-antigravity/antigravity-cli/releases/download/$version/agy_cli_windows_{suffix}.zip"
            if autoupdate.get("architecture", {}).get(arch, {}).get("url") != expected:
                errors.append(f"autoupdate architecture.{arch} must use the versioned official release asset")
        auto_hash = autoupdate.get("hash", {})
        if auto_hash.get("mode") != "json" or auto_hash.get("url") != "https://api.github.com/repos/google-antigravity/antigravity-cli/releases/tags/$version":
            errors.append("autoupdate hash must come from the matching official GitHub release metadata")
    return errors


def validate(path: Path, check_url: bool = False) -> list[str]:
    errors: list[str] = []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"cannot load JSON: {exc}"]
    if not isinstance(data, dict):
        return ["manifest root must be an object"]
    package = path.stem
    errors.extend(_validate_package(data, package))
    if check_url and not errors:
        expected_host = PACKAGE_RULES[package]["host"]
        for arch in PACKAGE_RULES[package]["arches"]:
            url = data["architecture"][arch]["url"]
            request = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "zev-scoop-validator/1.0"})
            try:
                with urllib.request.urlopen(request, timeout=45) as response:
                    final_url = urlsplit(response.geturl())
                    allowed_hosts = {expected_host, "release-assets.githubusercontent.com"}
                    if response.status != 200 or final_url.scheme != "https" or final_url.hostname not in allowed_hosts:
                        errors.append(f"architecture.{arch} URL check failed with HTTP {response.status}")
            except (urllib.error.URLError, TimeoutError) as exc:
                errors.append(f"architecture.{arch} URL check failed: {exc}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=MANIFEST)
    parser.add_argument("--all", action="store_true", help="Validate every supported manifest in bucket/")
    parser.add_argument("--check-url", action="store_true", help="Make an HTTPS HEAD request to the package URL")
    args = parser.parse_args()
    paths = sorted((ROOT / "bucket").glob("*.json")) if args.all else [args.manifest]
    failed = False
    for path in paths:
        errors = validate(path, args.check_url)
        if errors:
            failed = True
            for error in errors:
                print(f"validate-manifest: error: {path.name}: {error}", file=sys.stderr)
        else:
            print(f"Valid manifest: {path}")
    if not paths:
        print("validate-manifest: error: no manifests found", file=sys.stderr)
        return 1
    if failed:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
