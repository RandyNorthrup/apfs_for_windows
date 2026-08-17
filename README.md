# APFS for Windows

Native APFS access in Windows Explorer.

[![Repository gates](https://github.com/RandyNorthrup/apfs_for_windows/actions/workflows/repository-gates.yml/badge.svg?branch=main)](https://github.com/RandyNorthrup/apfs_for_windows/actions/workflows/repository-gates.yml)
[![Latest release](https://img.shields.io/github/v/release/RandyNorthrup/apfs_for_windows?include_prereleases&sort=semver)](https://github.com/RandyNorthrup/apfs_for_windows/releases)
[![Platform](https://img.shields.io/badge/platform-Windows%2011%20x64-0078D4?logo=windows11&logoColor=white)](docs/INSTALLATION.md)
[![Status](https://img.shields.io/badge/status-public%20beta-F59E0B)](docs/PRODUCTION_READINESS.md)
[![License](https://img.shields.io/github/license/RandyNorthrup/apfs_for_windows)](LICENSE)

APFS for Windows runs an Automatic Windows service that discovers supported
APFS devices, assigns a drive letter, and keeps the mount available until the
product is uninstalled. A tray manager provides mount status and controls.

> [!NOTE]
> The public beta uses a test-signed filesystem driver, so Windows Test Signing
> is required. Review the [installation requirements](docs/INSTALLATION.md)
> before setup and safely eject writable media before disconnecting it.

## Features

- Automatic mounting of supported unencrypted, unsealed APFS devices.
- Explorer read, write, create, rename, move, and delete operations.
- Files, directories, symbolic links, hard links, timestamps, attributes,
  security metadata, extended attributes, and alternate data streams.
- Automatic service startup and worker recovery.
- Persistent stacked `AP`/`FS` tray icon with `Open` and `Exit` actions.
- Drive-letter, read-only/read-write, automount, and unmount controls.
- Clean product, service, driver, tray, task, and file removal.

## Requirements

- Windows 11 x64.
- Administrator access for Test Mode configuration and installation.
- Secure Boot disabled before enabling Windows Test Signing.
- BitLocker recovery information available before changing firmware settings.
- A supported APFS device and a current backup.

The release package includes the dedicated WinFsp runtime and test-signed
filesystem driver. Stock WinFsp does not need to be installed.

## Install

1. Download the latest test-signed ZIP from
   [GitHub Releases](https://github.com/RandyNorthrup/apfs_for_windows/releases).
2. Extract the ZIP.
3. Open an elevated PowerShell in the extracted directory.
4. Check and enable Windows Test Signing:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\configure-test-signing.ps1 -Action Status
.\configure-test-signing.ps1 -Action Enable -AcknowledgeSecurityRisk
```

5. Restart Windows manually when the status reports `restart_required: true`.
6. Return to an elevated PowerShell in the extracted directory and install:

```powershell
.\install-apfs-for-windows.ps1 -AllowTestSignedDriver
```

The installer does not restart Windows. After installation, supported APFS
devices mount automatically with a free drive letter and appear in Explorer.

See [Installation](docs/INSTALLATION.md) for security boundaries, repair,
verification, and uninstall instructions.

## Use

Plug in a supported APFS device. The service discovers it and mounts it
read/write by default unless an explicit saved policy says otherwise.

Open the tray icon to:

- inspect service and mount health;
- open a mounted drive;
- change its drive letter;
- switch between read-only and read/write;
- enable or disable automount;
- unmount a device.

Eject or unmount writable media before disconnecting it. See the
[User Guide](docs/USER_GUIDE.md) for normal operation and troubleshooting.

## Supported Scope

Current automatic writable mounting is limited to APFS volumes that pass the
project's safety policy. Sealed, encrypted, per-file-key, unknown-policy, and
non-APFS targets fail closed. Protected Apple content-critical metadata is not
exposed for generic mutation.

See [Production Readiness](docs/PRODUCTION_READINESS.md) for exact claim limits.

## Uninstall

From an elevated PowerShell in the extracted release directory:

```powershell
.\configure-test-signing.ps1 -Action Disable
& "$env:ProgramFiles\APFS for Windows\uninstall-apfs-for-windows.ps1" -RemoveFiles
```

Restart Windows manually after uninstalling when Test Signing was disabled. Do
not disable Test Signing when another installed test driver still needs it.

## Documentation

- [Installation](docs/INSTALLATION.md)
- [User Guide](docs/USER_GUIDE.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Development](docs/DEVELOPMENT.md)
- [Testing](docs/TESTING.md)
- [Releasing](docs/RELEASING.md)
- [Privacy](docs/PRIVACY.md)
- [Production Readiness](docs/PRODUCTION_READINESS.md)
- [Implementation and Certification Plan](docs/APFS_WINDOWS_EXPLORER_NATIVE_MOUNT_PLAN.md)
- [Security Policy](SECURITY.md)
- [Contributing](CONTRIBUTING.md)
- [Third-Party Licenses](THIRD_PARTY_LICENSES.md)

## License

Project license terms are in [LICENSE](LICENSE). Third-party notices are in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

## Author

Created and maintained by [Randy Northrup](https://randynorthrup.com). See
[GitHub](https://github.com/RandyNorthrup) for additional projects.
