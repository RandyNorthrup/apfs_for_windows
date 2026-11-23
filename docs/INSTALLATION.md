# Installation

## Release Classification

APFS for Windows is distributed as an MSI installer. The installer and the
application binaries are Authenticode-signed by `CN=Randy Northrup` through
Azure Artifact Signing. The filesystem driver is WDK test-signed, so
installation requires persistent Windows Test Signing. This is an
owner-controlled public beta model, not production driver distribution.

Production kernel signing needs an EV certificate and Microsoft Partner Center
attestation, which the project does not have yet. Application signing confirms
the publisher. It does not guarantee Smart App Control or SmartScreen
reputation.

Neither the installer nor the supplied scripts enable `nointegritychecks`,
kernel debugging, or an HVCI bypass, and none of them restart Windows
automatically.

## Before Installation

1. Back up important APFS data.
2. Confirm administrator access.
3. Confirm BitLocker recovery information is available.
4. Disable Secure Boot in firmware when required by Windows Test Signing.
5. Download `APFS-for-Windows-<version>-test-signed.msi` from
   [GitHub Releases](https://github.com/RandyNorthrup/apfs_for_windows/releases).
   Optionally compare its SHA-256 value with `SHA256SUMS.txt` and confirm the
   signature under **Properties > Digital Signatures**.

### Upgrading from 0.1.0

0.1.0 was installed with PowerShell scripts. The MSI detects that install and
stops with a message. Remove it first from an elevated PowerShell:

```powershell
& "$env:ProgramFiles\APFS for Windows\uninstall-apfs-for-windows.ps1" -RemoveFiles
```

Keep Test Signing on when you plan to install the MSI straight away. Later
upgrades from one MSI version to the next happen in place and keep your mount
settings.

## Enable Test Signing

Do this once per machine. With Secure Boot off, run from an elevated prompt:

```powershell
bcdedit /set testsigning on
```

Restart Windows. The desktop shows a "Test Mode" watermark while Test Signing is
active.

You can use the guided helper instead. It is in the release ZIP, next to the
MSI on the release page. Extract the ZIP and open an elevated PowerShell in that
folder:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\configure-test-signing.ps1 -Action Status
.\configure-test-signing.ps1 -Action Enable -AcknowledgeSecurityRisk
```

The helper refuses to continue while Secure Boot is on and never changes Secure
Boot itself. Read the JSON result. When `restart_required` is true, restart
Windows manually and run the status command again. After installation the
helper is also in `%ProgramFiles%\APFS for Windows`.

## Install

Double-click the MSI and follow the setup wizard. Setup asks for administrator
approval. If Test Signing is not active in the current boot, setup stops with a
message that explains what to do.

Installation creates:

- the Automatic service `ApfsForWindowsMountService`, which restarts after
  failures;
- the dedicated side-by-side filesystem driver `WinFsp+apfs-main`, which
  leaves an existing stock WinFsp install alone;
- tray manager startup through one machine Run entry;
- an `APFS for Windows` Start menu shortcut and an Apps & Features entry;
- program files under `%ProgramFiles%\APFS for Windows`, including the
  Visual C++ runtime;
- runtime configuration and logs under `%ProgramData%\APFS for Windows`.
  Standard users can read this folder but cannot change it.

The final wizard page can open the manager. Supported APFS media mounts
automatically after installation and on later Windows starts.

## Enterprise Deployment

The MSI is per-machine and supports the standard `msiexec` options. From an
elevated prompt:

```powershell
msiexec /i APFS-for-Windows-<version>-test-signed.msi /qn /l*v apfs-install.log
```

- Turn on Test Signing (and turn off Secure Boot) as a separate, earlier
  deployment step. The MSI never changes boot settings.
- `SKIPTESTSIGNINGCHECK=1` skips the Test Signing check so imaging pipelines can
  install before the Test Mode restart. The driver loads only once Test Signing
  is active.
- Intune: upload the MSI as a line-of-business app. The install and uninstall
  commands are detected automatically.
- Group Policy: assign the MSI under **Computer Configuration > Software
  Settings > Software installation**.

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
msiexec /fa APFS-for-Windows-<version>-test-signed.msi
```

Repair restores installed files, the service, and the driver registration. It
does not restart Windows.

## Uninstall

Open **Settings > Apps > Installed apps**, find **APFS for Windows**, and choose
**Uninstall**. For a silent uninstall, run this from an elevated prompt:

```powershell
msiexec /x APFS-for-Windows-<version>-test-signed.msi /qn
```

Mounted volumes are unmounted cleanly first. The uninstaller removes the
service, driver, workers, tray manager, startup entry, shortcut, application
registration, configuration, logs, and installed files.

To turn Test Signing off afterward, run `bcdedit /set testsigning off` from an
elevated prompt and restart Windows. Do not turn it off while another test
driver depends on it.

## Script-Based Install

The release ZIP still contains the PowerShell install, repair, and uninstall
scripts for development and certification. The MSI is the supported install
path. Do not mix the two: remove a script-based install before using the MSI.

## Troubleshooting Installation

- "An earlier script-based installation ... was found": run the 0.1.0
  uninstall script shown above, then run the MSI again.
- "needs Windows Test Signing": turn off Secure Boot, run
  `bcdedit /set testsigning on`, restart, and run setup again.
- `Secure Boot is enabled` from the helper: disable Secure Boot in firmware,
  then retry.
- `restart_required` remains true: restart Windows and recheck status.
- "The previous APFS file system driver is still loaded" when reinstalling
  right after an uninstall: Windows keeps the file system driver loaded until
  the next restart once a volume has been mounted. Restart, then run setup
  again. Upgrades over an installed version do not need a restart.
- The driver does not start after an install with `SKIPTESTSIGNINGCHECK=1`:
  turn Test Signing on and restart.
- Setup fails: rerun with `/l*v apfs-install.log` and check the log. Download
  the MSI again and compare its SHA-256 value with `SHA256SUMS.txt`.
- Files are in use during upgrade or uninstall: setup closes the tray manager
  itself. Close Explorer windows and apps that have files open on APFS drives.
