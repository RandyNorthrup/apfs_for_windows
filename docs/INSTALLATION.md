# Installation

## Release Classification

APFS for Windows is distributed as a signed `Setup.exe` and a signed MSI. Both
installers and the application binaries are Authenticode-signed by
`CN=Randy Northrup` through Azure Artifact Signing. This is an owner-controlled
public beta, not a production release.

The filesystem driver is the official WinFsp driver, installed system-wide. Its
kernel driver is signed by Microsoft Windows Hardware Compatibility Publisher,
and the WinFsp MSI and DLL are signed by NAVIMATICS LLC. Windows Test Mode is not
needed, and Secure Boot, Memory Integrity, and BitLocker stay as they are.

Application signing confirms the publisher. It does not guarantee Smart App
Control or SmartScreen reputation.

Neither installer changes boot settings or restarts Windows automatically.

## Before Installation

1. Back up important APFS data.
2. Confirm administrator access.
3. Download `APFS-for-Windows-<version>-Setup.exe` from
   [GitHub Releases](https://github.com/RandyNorthrup/apfs_for_windows/releases).
   Optionally compare its SHA-256 value with `SHA256SUMS.txt` and confirm the
   signature under **Properties > Digital Signatures**.

### WinFsp

APFS for Windows needs the official WinFsp 2.2 release installed system-wide.
The pinned build is WinFsp 2.2.26323 (`winfsp-2.2.26323.msi`, tag `v2.2`) with
SHA-256 `36CE01F9EEDBBE6842B7FB4BEDC79D7D4F71983E8ACEB6877B46A07B331C7E19`.
`Setup.exe` installs it automatically if it is missing. WinFsp is a separate
component with its own license (GPLv3 with FLOSS exception). It appears as
**WinFsp** in Installed apps.

### Upgrading from 0.2.0

0.2.0 used a test-signed driver, `WinFsp+apfs-main`, and needed Windows Test
Mode. Run the 0.2.1 `Setup.exe` over it. Setup removes the old test-signed
driver, installs the official WinFsp if needed, and upgrades the application in
place. Your mount settings are kept.

When setup finishes, Test Mode is no longer needed by APFS for Windows. To turn
it off, run this from an elevated prompt and restart Windows:

```powershell
bcdedit /set testsigning off
```

Do not turn it off while another installed test-signed driver still needs it.
After the restart you can turn Secure Boot back on in your firmware settings.
Have your BitLocker recovery key ready before you change firmware settings.

### Upgrading from 0.1.0

0.1.0 was installed with PowerShell scripts. The MSI detects that install and
stops with a message. Remove it first from an elevated PowerShell:

```powershell
& "$env:ProgramFiles\APFS for Windows\uninstall-apfs-for-windows.ps1" -RemoveFiles
```

Then run the 0.2.1 `Setup.exe`. Later upgrades from one installer version to
the next happen in place and keep your mount settings.

## Install

Double-click `APFS-for-Windows-<version>-Setup.exe` and follow the setup wizard.
Setup asks for administrator approval, installs WinFsp if it is missing, and
then installs APFS for Windows.

Installation creates:

- the Automatic service `ApfsForWindowsMountService`, which restarts after
  failures;
- tray manager startup through one machine Run entry;
- an `APFS for Windows` Start menu shortcut and an Apps & Features entry;
- program files under `%ProgramFiles%\APFS for Windows`, including the
  Visual C++ runtime;
- runtime configuration and logs under `%ProgramData%\APFS for Windows`.
  Standard users can read this folder but cannot change it.

When WinFsp was missing, setup also installs the official WinFsp package, which
adds its own driver and launcher service.

The final wizard page can open the manager. Supported APFS media mounts
automatically after installation and on later Windows starts. A device the
service has not seen before mounts read-only; switch it to read/write per
volume in the tray.

## Enterprise Deployment

For a silent install of the bundle, run this from an elevated prompt:

```powershell
.\APFS-for-Windows-<version>-Setup.exe /quiet /log apfs-setup.log
```

MSI-based deployment tools can install the two packages in order instead. Use
the official WinFsp MSI first, then the APFS for Windows MSI, both silent:

```powershell
msiexec /i winfsp-2.2.26323.msi /qn /l*v winfsp-install.log
msiexec /i APFS-for-Windows-<version>.msi /qn /l*v apfs-install.log
```

Download the WinFsp MSI from
<https://github.com/winfsp/winfsp/releases/download/v2.2/winfsp-2.2.26323.msi>
and check its SHA-256 value against the one under [WinFsp](#winfsp).

- Intune: upload both MSIs as line-of-business apps and make APFS for Windows
  depend on WinFsp.
- Group Policy: assign WinFsp and then APFS for Windows under **Computer
  Configuration > Software Settings > Software installation**.
- Neither package changes boot settings or restarts Windows.

## Verify

Run these commands from a normal PowerShell after installation:

```powershell
& "$env:ProgramFiles\APFS for Windows\apfs_mount_service.exe" --health
& "$env:ProgramFiles\APFS for Windows\apfs_mount_manager.exe" --self-test
```

Both commands return JSON. `ok` should be true. Plug in supported APFS media and
confirm a drive letter appears in Explorer and in the mount manager.

## Repair

Open **Settings > Apps > Installed apps**, choose **APFS for Windows**, and run
the installer's repair option. Or, from an elevated prompt:

```powershell
msiexec /fa APFS-for-Windows-<version>.msi
```

Repair restores installed files and the service. It does not restart Windows.
If WinFsp itself is damaged, repair or reinstall **WinFsp** from Installed apps.

## Uninstall

Open **Settings > Apps > Installed apps**, find **APFS for Windows**, and choose
**Uninstall**. For a silent uninstall, run this from an elevated prompt:

```powershell
msiexec /x APFS-for-Windows-<version>.msi /qn
```

Mounted volumes are unmounted cleanly first. The uninstaller removes the
service, workers, tray manager, startup entry, shortcut, application
registration, configuration, logs, and installed files.

WinFsp stays installed, because other applications may use it. If nothing else
needs it, remove **WinFsp** from Installed apps afterward.

## Troubleshooting Installation

- "An earlier script-based installation ... was found": run the 0.1.0
  uninstall script shown above, then run setup again.
- APFS drives do not appear after an upgrade from 0.2.0: Windows can keep the
  old file system driver loaded until the next restart once a volume has been
  mounted. Restart Windows once.
- APFS drives do not mount and the service log says WinFsp is missing:
  install it with `Setup.exe` or with the official WinFsp MSI, then restart
  Windows.
- Setup fails: rerun with `/log apfs-setup.log` (Setup.exe) or
  `/l*v apfs-install.log` (MSI) and check the log. Download the installer again
  and compare its SHA-256 value with `SHA256SUMS.txt`.
- Files are in use during upgrade or uninstall: setup closes the tray manager
  itself. Close Explorer windows and apps that have files open on APFS drives.
