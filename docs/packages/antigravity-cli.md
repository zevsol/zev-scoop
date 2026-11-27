# Antigravity CLI

| Property | Value |
|---|---|
| Scoop package | `antigravity-cli` |
| Command | `agy` |
| Platform | Windows x64 and ARM64 |
| Current manifest version | `1.5.18` |
| Status | Local isolated and GitHub-hosted Windows x64 install, command, uninstall, and reinstall PASS; ARM64 runtime untested |

## Official source and package layout

The package uses versioned ZIP assets from Google's [official Antigravity CLI repository](https://github.com/google-antigravity/antigravity-cli). The GitHub Releases API provides SHA256 digests for the x64 and ARM64 assets. The current assets are `agy_cli_windows_x64.zip` and `agy_cli_windows_arm64.zip`; each ZIP contains `antigravity.exe`. The official Windows installer places this executable under the name `agy.exe`, so the Scoop manifest applies the same rename and creates the `agy` command wrapper.

The release archive currently contains only the CLI executable; the upstream release metadata declares no additional runtime dependencies. Runtime compatibility is still subject to the hosted Windows tests.

The installer script is not run by Scoop. [`update-antigravity-cli.py`](../../scripts/update-antigravity-cli.py) reads the official stable release metadata, validates both versioned asset URLs and published SHA256 digests, downloads the assets, recomputes the digests, checks archive contents, and only then updates the manifest. The GitHub API download is used for byte verification; the manifest itself points to the versioned browser download URL.

The upstream repository does not declare an open-source license. The manifest marks this Google product as proprietary; check Google's applicable product terms before use.

## Self-update and Scoop lifecycle

Antigravity CLI documents the `AGY_CLI_DISABLE_AUTO_UPDATE=true` environment variable for disabling its background updater. The Scoop `agy` wrapper sets that variable only for the CLI process it starts, leaving the user's environment untouched. Scoop handles version upgrades and removes its package files and shims on uninstall. User-level CLI data is outside the Scoop app directory and is not deleted by the manifest.

## Verification status

- Official release metadata and the published SHA256 values for both architectures are validated by local unit tests.
- The current x64 ZIP was downloaded locally: its SHA256 was `3f705965ba256add649a68be8834f73185034bdf206a457255b8a3d3c0497cac`, matching the official GitHub release metadata, and its archive contains `antigravity.exe`. The ARM64 SHA256 is read and checked against the official release metadata by the updater; the ARM64 archive itself was not downloaded in this local run.
- A local isolated Scoop run on x64 installed version `1.5.18`; Scoop reported the manifest SHA256 check as `OK`. `agy --version`, `agy --help`, the shim and executable paths passed. The CLI command ran with `AGY_CLI_DISABLE_AUTO_UPDATE=true` from its wrapper, an isolated process `USERPROFILE`, and temporary `TEMP/TMP`; no sign-in or Agent task was started. The package was uninstalled, reinstalled and tested again, then uninstalled.
- Process and user/machine PATH snapshots matched afterward, and the isolated Scoop root, cache, and test bucket were removed. The Windows Credential Manager is per-user and is not namespaced by `USERPROFILE`; the tested version/help commands did not perform login or access credentials.
- ARM64 is declared by the official release and manifest, and its official GitHub release SHA256 is verified by the updater, but no ARM64 runner was used locally or in CI. GitHub-hosted Windows x64 lifecycle CI passed in [Test AI CLI packages](https://github.com/zevsol/zev-scoop/actions/runs/46002829984).
- No distinct historical package manifest exists at the current Git baseline, so upgrade was skipped rather than simulated.

Sources: [official download page](https://antigravity.google/download), [CLI installation guide](https://antigravity.google/docs/cli/getting-started), [CLI troubleshooting](https://antigravity.google/docs/cli/troubleshooting), [official CLI releases](https://github.com/google-antigravity/antigravity-cli/releases).
