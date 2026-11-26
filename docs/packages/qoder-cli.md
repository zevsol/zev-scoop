# Qoder CLI

| Property | Value |
|---|---|
| Scoop package | `qoder-cli` |
| Command shim | `qoder` |
| Category | AI / CLI |
| Current architecture | Windows x64 |
| Manifest | [`bucket/qoder-cli.json`](../../bucket/qoder-cli.json) |
| Status | Manifest implemented; local checks and current GitHub-hosted Windows install lifecycle pass. Upgrade testing is skipped when no distinct historical version is available. |

## Install and manage

```powershell
scoop bucket add zev https://github.com/zevsol/zev-scoop
scoop install zev/qoder-cli
qoder --version
qoder --help
scoop update qoder-cli
scoop uninstall qoder-cli
```

Scoop uninstallation removes the package files and shim. It does not delete Qoder's user configuration, sessions, or other user data.

## Official source and package design

Qoder recommends its native standalone CLI distribution through its [Installation and Upgrade guide](https://docs.qoder.com/cli/installation). This package downloads the versioned Windows x64 ZIP directly from the official Qoder host, without running `install.ps1`. The official channel provides the latest version, artifact URL and SHA256. The updater downloads the archive, recalculates SHA256, checks the archive structure, and only then replaces the manifest.

The official installer script extracts the same standalone executable and invokes `qodercli.exe install --force`. The Scoop package instead lets Scoop own the downloaded binary and exposes `qodercli.exe` as the `qoder` shim. The direct-manifest lifecycle has not yet completed successfully on a hosted runner.

## Architecture and Windows requirements

The manifest currently enables **Windows x64** only. The standard official x64 artifact declares minimum Windows build 17763 (Windows 10 version 1809). Qoder describes the software as proprietary and licenses use under its [Terms of Service](https://qoder.com/product-service).

The official channel currently lists an ARM64 artifact and the installer script contains ARM64 selection logic, while the [CLI installation guide](https://docs.qoder.com/cli/installation) and [installation troubleshooting guide](https://docs.qoder.com/cli/troubleshoot-install) state that Windows ARM64 is not supported. This package follows the explicit documentation and does not advertise ARM64 support until Qoder resolves the discrepancy.

## Version updates and self-update

[`scripts/update-qoder.py`](../../scripts/update-qoder.py) is a Qoder-specific updater. It reads the official release channel and applies strict host, URL, version, archive and SHA256 checks. The Manifest also uses Scoop `checkver` metadata and a versioned `autoupdate` URL template; the scheduled GitHub workflow is responsible for obtaining the official checksum and updating the checked-in hash.

Qoder documents that CLI auto-upgrade is enabled by default and can be disabled with `general.enableAutoUpdate: false` in the user `settings.json`. The default location is `~/.qoder/settings.json`; the official `QODER_CONFIG_DIR` environment variable overrides that user configuration directory. See the [official settings reference](https://docs.qoder.com/cli/settings-reference) and [configuration files guide](https://docs.qoder.com/cli/settings).

The lifecycle test sets `QODER_CONFIG_DIR` to a unique directory under its temporary test root and writes `{"general":{"enableAutoUpdate":false}}` to that directory's `settings.json`. This is based on Qoder's documented configuration mechanism and leaves the runner user's normal Qoder configuration untouched. Runtime confirmation that the tested CLI build honors this setting has not yet been performed in GitHub Actions.

## Validation status and limitations

- The manifest has passed the official Scoop JSON schema check, local URL/field validation, and local Python tests.
- The current official package hash and archive layout were checked locally.
- GitHub Actions history: [Validate bucket manifests](https://github.com/zevsol/zev-scoop/actions/runs/45805498069) passed. [Test Qoder CLI](https://github.com/zevsol/zev-scoop/actions/runs/45805498015) failed while passing the excluded Scoop paths to the Scoop bootstrap process. The failure occurred before the Qoder installation lifecycle completed; it does not establish that installation, command checks, or uninstall passed. The upgrade check was skipped because no distinct historical version was available.
- Persisted local logs in `test-logs/` record earlier JSON transport (18 cases) and standard Junction cleanup runs under Windows PowerShell 5.1 and PowerShell 7.7. They predate the latest TOCTOU replacement test and do not contain its result.
- The latest local TOCTOU replacement test and rerun of the JSON and standard Junction checks passed under both PowerShell versions; those results were captured in the test execution output but were not written to persistent log files. Local checks do not verify the current changes on GitHub Actions.
- Current GitHub Actions: [Validate bucket manifests](https://github.com/zevsol/zev-scoop/actions/runs/45834466314) passed. [Test Qoder CLI](https://github.com/zevsol/zev-scoop/actions/runs/45834466262) passed current-version Scoop installation, SHA256 verification, `qoder --version`, `qoder --help`, Shim and executable path checks, and uninstall. The upgrade step was skipped because no distinct historical version was available. Isolation snapshots matched and the isolated Scoop test root was removed; Qoder's possible `qodercli-natives-*` cache outside that root was not deleted, and cleanup is therefore reported as partial. The GitHub-hosted runner is ephemeral and is recycled after the job. Runtime confirmation that the CLI honors the temporary auto-update setting remains pending.
- Scoop's unique test root is removed by the test script. Qoder may also create a `qodercli-natives-*` dependency cache in the Windows TEMP directory outside that root. The script does not attempt broad TEMP cleanup and reports `CLEANUP=PARTIAL` when the Scoop root is removed but this external cache is unmanaged. The workflow uses a GitHub-hosted Windows runner; GitHub provisions a VM per job and decommissions it after the job ([runner lifecycle](https://docs.github.com/en/actions/how-tos/manage-runners/github-hosted-runners/use-github-hosted-runners)).
- A real upgrade is reported separately and runs only when a distinct historical Manifest is available and that versioned artifact can still be downloaded. Otherwise the upgrade check is marked skipped.
- No upstream signature file was found; checksum trust relies on the official HTTPS release channel.

Detailed source evidence is in the [Qoder CLI source audit](../qoder-cli-source-audit.md).
