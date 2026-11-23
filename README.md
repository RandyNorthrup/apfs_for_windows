# APFS for Windows

Native APFS access in Windows Explorer.

[![Repository gates](https://github.com/RandyNorthrup/apfs_for_windows/actions/workflows/repository-gates.yml/badge.svg?branch=main)](https://github.com/RandyNorthrup/apfs_for_windows/actions/workflows/repository-gates.yml)
[![Latest release](https://img.shields.io/github/v/release/RandyNorthrup/apfs_for_windows?sort=semver)](https://github.com/RandyNorthrup/apfs_for_windows/releases)
[![Platform](https://img.shields.io/badge/platform-Windows%2011%20x64-0078D4?logo=windows11&logoColor=white)](docs/INSTALLATION.md)
[![Status](https://img.shields.io/badge/status-public%20beta-F59E0B)](docs/PRODUCTION_READINESS.md)
[![License](https://img.shields.io/github/license/RandyNorthrup/apfs_for_windows)](LICENSE)

APFS for Windows runs an Automatic Windows service that discovers supported
APFS devices, assigns a drive letter, and keeps the mount available until the
product is uninstalled. A tray manager provides mount status and controls.

> [!NOTE]
> Setup and the application binaries are signed by `CN=Randy Northrup`. The
> filesystem driver is the official WinFsp driver, signed by Microsoft, so
> Windows Test Mode is not needed and Secure Boot can stay on. Review the
> [installation requirements](docs/INSTALLATION.md) before setup and safely
> eject writable media before disconnecting it.

## Features

- Automatic mounting of supported unencrypted, unsealed APFS devices.
- New devices mount read-only until you switch them to read/write in the tray.
- Explorer read, write, create, rename, move, and delete operations.
- Files, directories, symbolic links, timestamps, attributes, security
  metadata, extended attributes, and alternate data streams. Existing APFS hard
  links open normally. Windows apps cannot create new hard links (see
  [Supported Scope](#supported-scope)).
- Automatic service startup, clean unmount at shutdown, and worker recovery.
- Stacked `AP`/`FS` tray icon whose color shows service and mount state.
- Per-volume tray menus: open, read-only/read-write, automount, drive letter,
  and unmount (eject) or mount.
- Device search, Start at sign-in, notifications, and log access from the tray.
- Signed `Setup.exe` that installs WinFsp for you when it is missing, plus a
  signed MSI for silent enterprise deployment.
- Clean product, service, tray, and file removal.

## Requirements

- Windows 11 x64.
- Administrator access for installation.
- A supported APFS device and a current backup.

APFS for Windows uses the official [WinFsp](https://winfsp.dev/) 2.2 driver,
installed system-wide. `Setup.exe` installs it automatically if it is missing.
The Visual C++ runtime is included.

## Install

1. Download `APFS-for-Windows-<version>-Setup.exe` from
   [GitHub Releases](https://github.com/RandyNorthrup/apfs_for_windows/releases).
2. Double-click it and follow the setup wizard.

Setup installs WinFsp if needed, then APFS for Windows. It does not restart
Windows. After installation, supported APFS devices mount automatically with a
free drive letter and appear in Explorer.

For a silent install, run this from an elevated prompt:

```powershell
.\APFS-for-Windows-<version>-Setup.exe /quiet
```

Enterprise tools that deploy MSI packages can install the official WinFsp MSI
first and then `APFS-for-Windows-<version>.msi`, both silently. See
[Enterprise Deployment](docs/INSTALLATION.md#enterprise-deployment).

Upgrading from 0.2.0: setup removes the old test-signed driver. Afterwards you
can turn Test Mode off and turn Secure Boot back on. See
[Upgrading from 0.2.0](docs/INSTALLATION.md#upgrading-from-020) and the
[0.2.1 release notes](docs/releases/0.2.1.md).

See [Installation](docs/INSTALLATION.md) for security boundaries, enterprise
deployment, verification, and uninstall instructions.

## Use

Plug in a supported APFS device. The service discovers it and mounts it. A
device it has not seen before mounts read-only. Switch it to read/write in the
tray when you want to change files. The choice is saved for that volume.

Right-click the tray icon to:

- see service and mount health at a glance;
- open a mounted drive;
- change its drive letter;
- switch between read-only and read/write;
- turn automount on or off;
- unmount (eject) a device, or mount it again;
- search for newly connected devices;
- choose Start at sign-in and notifications;
- open the service logs.

Standard users can manage volumes the service already knows about. Adding a
mount target by hand requires an elevated administrator.

Unmount writable media before disconnecting it. See the
[User Guide](docs/USER_GUIDE.md) for normal operation and troubleshooting.

## Supported Scope

Current automatic writable mounting is limited to APFS volumes that pass the
project's safety policy. Sealed, encrypted, per-file-key, unknown-policy, and
non-APFS targets fail closed. Protected Apple content-critical metadata is not
exposed for generic mutation.

Creating new hard links from Windows is not supported with the official WinFsp
driver. Hard links that already exist on the volume keep working.

Known limits in this release: writes are slow, especially when copying many
small files, and a volume is write-protected from Windows when any folder on the volume holds 1,000 or more items, or folders are nested more than 16 deep
anywhere on it (it still lists and reads completely). Both limits remain until
the new write engine lands.

See [Production Readiness](docs/PRODUCTION_READINESS.md) for exact claim limits.

## Uninstall

Open **Settings > Apps > Installed apps**, find **APFS for Windows**, and
choose **Uninstall**. For a silent uninstall, run this from an elevated prompt:

```powershell
msiexec /x APFS-for-Windows-<version>.msi /qn
```

Uninstall removes the service, tray manager, configuration, logs, and installed
files. WinFsp stays installed because other apps may use it. Remove **WinFsp**
from Installed apps separately if nothing else needs it.

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
