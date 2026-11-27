# Qoder CN CLI

| Property | Value |
|---|---|
| Scoop package | `qoder-cn-cli` |
| Commands | `qodercn`; compatibility alias `qoderclicn` |
| Platform | Windows x64 |
| Current manifest version | `1.1.99` |
| Status | Local isolated and GitHub-hosted Windows x64 install, command, uninstall, and reinstall PASS |

## Official source and install behavior

The [official Qoder CN CLI installation guide](https://docs.qoder.cn/cli/installation) documents a native standalone Windows executable, the `qodercn` command, and the legacy `qoderclicn` name. The guide currently says Windows ARM64 is unsupported, so this package enables x64 only even though the channel feed may list other artifacts.

The manifest downloads the versioned ZIP directly from `static.qoder.com.cn`; it does not run the remote `install.ps1`. The official channel metadata supplies the current version, x64 URL, and SHA256. [`update-qoder-cn-cli.py`](../../scripts/update-qoder-cn-cli.py) checks that metadata, downloads the archive, recalculates SHA256, validates the archive members, and updates the manifest only after verification. The archive contains `qoderclicn.exe` and the upstream `THIRD-PARTY-LICENSES` file.

The Scoop package creates a `qodercn` command shim and a `qoderclicn` compatibility shim. Both invoke the same official executable. The international `qoder-cli` package and its `qoder` shim are unchanged.

## Configuration and updates

Qoder CN documents `QODERCN_CONFIG_DIR` as the configuration-directory override and `general.enableAutoUpdate: false` as the setting to disable CLI self-updates. The package persists a dedicated `qodercn-config` directory and its wrapper points only Qoder CN at that directory; it does not read or write the international Qoder configuration.

Scoop owns package version updates and uninstall. The official updater script's PATH registration and self-install behavior are not used. Uninstall removes Scoop-managed binaries and shims while Scoop's persistent package data follows Scoop persistence semantics.

## Verification status

- Current official x64 ZIP SHA256 and archive structure were downloaded and verified locally.
- JSON/Manifest rule tests cover Qoder CN's official channel selection and URL/version checks.
- A local isolated Scoop run installed version `1.1.99`; Scoop reported the manifest SHA256 check as `OK`. `qodercn --version`, `qodercn --help`, and the `qoderclicn --version` compatibility shim passed. The test verified the shim/EXE paths and persisted `general.enableAutoUpdate=false`, then uninstalled, reinstalled, reran commands, and uninstalled again.
- The local run used a unique Scoop root, bucket, cache, and Qoder CN configuration under a temporary test root. Process and user/machine PATH snapshots matched afterward. The Scoop root was removed. Qoder may create a native dependency cache outside that root; the test did not use broad TEMP cleanup, so cleanup is reported as partial.
- GitHub-hosted Windows x64 lifecycle CI passed in [Test AI CLI packages](https://github.com/zevsol/zev-scoop/actions/runs/46002829984) (install, SHA256, `qodercn`/`qoderclicn` commands, config isolation, uninstall, reinstall, final uninstall). A distinct historical-version upgrade was unavailable and was skipped rather than simulated.
- A distinct historical-version upgrade test runs only when the workflow can locate a different previous manifest and download that version.

Sources: [installation guide](https://docs.qoder.cn/cli/installation), [configuration and environment reference](https://docs.qoder.cn/cli/settings-reference), [official installer source](https://static.qoder.com.cn/qoder-cli-cn/install.ps1), [official channel manifest](https://static.qoder.com.cn/qoder-cli-cn/channels/manifest.json), [CLI changelog](https://changelog.qoder.cn/cli).
