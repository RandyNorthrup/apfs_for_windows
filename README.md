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
> The installer and application binaries are signed by `CN=Randy Northrup`.
> The filesystem driver is still test-signed, so Windows Test Signing is
> required. Review the [installation requirements](docs/INSTALLATION.md)
> before setup and safely eject writable media before disconnecting it.

## Features

- Automatic mounting of supported unencrypted, unsealed APFS devices.
- Explorer read, write, create, rename, move, and delete operations.
- Files, directories, symbolic links, hard links, timestamps, attributes,
  security metadata, extended attributes, and alternate data streams.
- Automatic service startup, clean unmount at shutdown, and worker recovery.
- Stacked `AP`/`FS` tray icon whose color shows service and mount state.
- Per-volume tray menus: open, read-only/read-write, automount, drive letter,
  and unmount (eject) or mount.
- Device search, Start at sign-in, notifications, and log access from the tray.
- Signed MSI installer with silent install for enterprise deployment.
- Clean product, service, driver, tray, and file removal.

## Requirements

- Windows 11 x64.
- Administrator access for Test Mode configuration and installation.
- Secure Boot disabled before enabling Windows Test Signing.
- BitLocker recovery information available before changing firmware settings.
- A supported APFS device and a current backup.

The installer includes the dedicated WinFsp runtime, the test-signed
filesystem driver, and the Visual C++ runtime. Stock WinFsp does not need to be
installed, and an existing stock WinFsp install is left alone.

## Install

1. Download `APFS-for-Windows-<version>-test-signed.msi` from
   [GitHub Releases](https://github.com/RandyNorthrup/apfs_for_windows/releases).
2. Turn on Windows Test Signing once, if it is not on already. Turn off Secure
   Boot in firmware first, then run `bcdedit /set testsigning on` from an
   elevated prompt and restart. You can use the guided helper from the release
   ZIP instead. It checks Secure Boot and reports whether a restart is needed:

   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass
   .\configure-test-signing.ps1 -Action Status
   .\configure-test-signing.ps1 -Action Enable -AcknowledgeSecurityRisk
   ```

3. Double-click the MSI and follow the setup wizard.

Setup stops with a message if Test Signing is not active yet. It does not
restart Windows. After installation, supported APFS devices mount automatically
with a free drive letter and appear in Explorer.

For a silent install, run this from an elevated prompt:

```powershell
msiexec /i APFS-for-Windows-<version>-test-signed.msi /qn
```

Add `SKIPTESTSIGNINGCHECK=1` when an imaging pipeline installs before the Test
Mode restart. The driver loads only once Test Signing is active. The same
command line works for Intune and Group Policy software deployment.

Upgrading from 0.1.0: remove the script-based install with its uninstall script
first. The MSI stops with a message until you do. See the
[0.2.0 release notes](docs/releases/0.2.0.md).

See [Installation](docs/INSTALLATION.md) for security boundaries, enterprise
deployment, verification, and uninstall instructions.

## Use

Plug in a supported APFS device. The service discovers it and mounts it
read/write by default unless an explicit saved policy says otherwise.

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

See [Production Readiness](docs/PRODUCTION_READINESS.md) for exact claim limits.

## Uninstall

Open **Settings > Apps > Installed apps**, find **APFS for Windows**, and
choose **Uninstall**. For a silent uninstall, run this from an elevated prompt:

```powershell
msiexec /x APFS-for-Windows-<version>-test-signed.msi /qn
```

Uninstall removes the service, driver, tray manager, configuration, logs, and
installed files. To turn Test Signing off afterward, run
`bcdedit /set testsigning off` from an elevated prompt and restart. Do not turn
it off while another installed test driver still needs it.

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
