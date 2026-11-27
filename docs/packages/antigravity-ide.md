# Antigravity IDE (Standalone)

**Status: BLOCKED for a Scoop package.** This is the standalone IDE product, not Antigravity App. No manifest is provided and no installer was executed.

## Official release evidence

The [official download page](https://antigravity.google/download) currently lists Antigravity IDE Standalone `2.8.0`, with Windows x64 and ARM64 installers. It links to versioned Google Edge download URLs:

| Architecture | Official URL | Size | Locally measured SHA256 |
|---|---|---:|---|
| x64 | `https://edgedl.me.gvt1.com/edgedl/release2/j0qc3/antigravity/stable/2.8.0-6733682917113856/windows-x64/Antigravity%20IDE.exe` | 199,656,240 bytes | `0F63D94C0BE212E25157125EB3757272B5AA95EA06538298631C14A3D7709197` |
| ARM64 | `https://edgedl.me.gvt1.com/edgedl/release2/j0qc3/antigravity/stable/2.8.0-6733682917113856/windows-arm64/Antigravity%20IDE.exe` | 193,642,328 bytes | `A73715B233A32E99B3584AC6388575DD8ACA721F9E9EF001FF21B126439E1C1C` |

These hashes were computed locally from downloads; Google does not publish a corresponding SHA256 feed or checksum file on the download page. Both files had a valid Authenticode signature from Google LLC, issued by DigiCert Trusted G4 Code Signing RSA4096 SHA384 2021 CA1. The file metadata reports version `2.8.0`, company `Google`, and description `Antigravity IDE Setup`.

The download page and its versioned release page are the official version-discovery sources found. The page exposes the version and full artifact links in its HTML; no documented JSON release API was found. Therefore the build identifier embedded in the URL cannot safely be generated from `$version` alone.

## Installer and lifecycle findings

Static inspection of the signed x64 installer identified Inno Setup `6.4.0`. Its embedded setup script declares `DefaultDirName={userpf}\Antigravity IDE`, `PrivilegesRequired=lowest`, and x64 architecture. It includes an Inno uninstaller, Start Menu shortcut, optional desktop and Quick Launch shortcuts, and optional tasks for context-menu entries, file associations, and PATH changes. The setup script contains HKCU file-association registrations and a post-install launch action. The ARM64 artifact is separately offered by Google; its metadata and signature were verified, but its embedded setup script was not separately unpacked.

The upstream installer uses custom Inno code and does not document Google-supported silent install or uninstall switches. Inno's generic command-line switches are not enough to establish that every custom task and side effect is safe for Scoop. The installer's normal UI offers installation choices, and the setup script's destination is dynamically resolved. We did not test alternate `/DIR` behavior, unattended installation, registry cleanup, shortcut cleanup, or user-data preservation.

Google's [IDE documentation](https://antigravity.google/docs/cli-getting-started?app=antigravity-ide) says Windows downloads updates in the background and prompts for a restart (system-wide installs show an install-update action). The official [releases page](https://antigravity.google/releases?tab=ide&version=2.8.0) says automatic updates are enabled by default and can be changed to manual or none in settings, but does not document a supported Scoop-side configuration file or unattended switch to enforce that policy. An in-app updater could therefore modify a Scoop-managed version directory and interfere with Scoop upgrades.

## Scoop assessment

Scoop's Inno Setup installer support is a possible implementation route, but it would require verified silent install/uninstall behavior, control of optional registry/shortcut/PATH tasks, a reliable way to turn off the IDE self-updater, and evidence that uninstall preserves user data. The current investigation did not establish those guarantees. Do not create a manifest or run the installer until these lifecycle controls are documented or independently verified in a disposable Windows VM.

No installer or application was installed during this investigation. The official files were downloaded to a unique temporary directory for hash, signature, PE metadata, and Inno script inspection only; that temporary directory was removed automatically.
