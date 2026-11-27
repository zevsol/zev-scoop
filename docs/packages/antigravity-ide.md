# Antigravity IDE (Standalone)

| Property | Value |
|---|---|
| Scoop package | `antigravity-ide` |
| CLI Command | `antigravity-ide` |
| Shortcut | `Antigravity IDE` (`Antigravity IDE.exe`) |
| Platform | Windows x64 and ARM64 |
| Current manifest version | `2.8.0` |
| Status | Manifest implemented with `innosetup: true` (`extract_dir: "{code_GetDestDir}"`); local schema/unit/URL checks PASS; GitHub-hosted Windows lifecycle CI pending |

## Official release evidence

The [official download page](https://antigravity.google/download) currently lists Antigravity IDE Standalone `2.8.0`, with Windows x64 and ARM64 installers. It links to versioned Google Edge download URLs:

| Architecture | Official URL | Size | Locally measured SHA256 |
|---|---|---:|---|
| x64 | `https://edgedl.me.gvt1.com/edgedl/release2/j0qc3/antigravity/stable/2.8.0-6733682917113856/windows-x64/Antigravity%20IDE.exe` | 199,656,240 bytes | `0f63d94c0be212e25157125eb3757272b5aa95ea06538298631c14a3d7709197` |
| ARM64 | `https://edgedl.me.gvt1.com/edgedl/release2/j0qc3/antigravity/stable/2.8.0-6733682917113856/windows-arm64/Antigravity%20IDE.exe` | 193,642,328 bytes | `a73715b233a32e99b3584ac6388575dd8aca721f9e9ef001ff21b126439e1c1c` |

These hashes were computed locally from downloads; Google does not publish a corresponding SHA256 feed or checksum file on the download page. Both files had a valid Authenticode signature from Google LLC, issued by DigiCert Trusted G4 Code Signing RSA4096 SHA384 2021 CA1. The file metadata reports version `2.8.0`, company `Google`, and description `Antigravity IDE Setup`.

The download page HTML is the official version-discovery source (`checkver` regex captures both `version` and `build`). Because no JSON release API or checksum feed is published, [`update-antigravity-ide.py`](../../scripts/update-antigravity-ide.py) parses both architecture links from the official download page, downloads both installers, verifies their Windows Authenticode signature (`CN=Google LLC`, `O=Google LLC`), computes SHA256 hashes, and updates [`bucket/antigravity-ide.json`](../../bucket/antigravity-ide.json).

## Scoop packaging and lifecycle design

Static inspection of the Inno Setup `6.4.0` script (`install_script.iss`) showed that all IDE application files (`Antigravity IDE.exe`, `bin\antigravity-ide.cmd`, `resources\app\...`) live under `{code_GetDestDir}`, whereas the Inno background updater (`tools\inno_updater.exe`) and uninstaller metadata live outside `{code_GetDestDir}` under `{app}\tools`.

By setting:

- `"innosetup": true`
- `"extract_dir": "{code_GetDestDir}"`

Scoop uses `innounp` to unpack only the application directory without executing the Inno installer binary or its registry/PATH/context-menu/launch side effects, and without unpacking `tools\inno_updater.exe`.

## Self-update and user data

- Scoop owns installation, upgrades, Start Menu shortcuts (`Antigravity IDE`), and the `antigravity-ide` CLI shim (`bin\antigravity-ide.cmd`). Note that `antigravity-ide --version` prints the underlying VS Code OSS core version (`1.107.0`), while the Windows lifecycle test verifies the Antigravity IDE release version via `resources\app\product.json` and PE `VersionInfo` metadata.
- Automatic updates are enabled by default in Antigravity IDE settings; users should set `"update.mode": "none"` in IDE settings so Scoop manages updates without out-of-band modifications to the Scoop-managed directory.
- User profile/data directories under `%APPDATA%` / `%USERPROFILE%` are preserved by Scoop across upgrades and uninstalls.

## Verification status

- Local Scoop JSON schema check, manifest rule checks (`validate-manifest.py`), unit tests, and HTTPS HEAD URL checks pass.
- Both installers' SHA256 hashes and Google LLC Authenticode signatures were verified locally against the official `2.8.0` installers; `install_script.iss` confirmed `{code_GetDestDir}` layout.
- GitHub-hosted Windows lifecycle testing (using `innounp` extraction in an isolated Scoop environment) is configured in `.github/workflows/test-ai-cli-packages.yml` and awaits its first runner execution.
