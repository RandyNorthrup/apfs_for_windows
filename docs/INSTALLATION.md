# Installation

## Release Classification

APFS for Windows is distributed as an unsigned application package with a WDK
test-signed filesystem driver. Installation requires persistent Windows Test
Signing. This is an owner-controlled prerelease model, not production driver
distribution.

The supplied scripts never enable `nointegritychecks`, kernel debugging, or an
HVCI bypass. They never restart Windows automatically.

## Before Installation

1. Back up important APFS data.
2. Confirm administrator access.
3. Confirm BitLocker recovery information is available.
4. Disable Secure Boot in firmware when required by Windows Test Signing.
5. Download and extract the latest ZIP from
   [GitHub Releases](https://github.com/RandyNorthrup/apfs_for_windows/releases).

## Enable Test Signing

Open an elevated PowerShell in the extracted release directory:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\configure-test-signing.ps1 -Action Status
.\configure-test-signing.ps1 -Action Enable -AcknowledgeSecurityRisk
```

Read the JSON result. Restart Windows manually when `restart_required` is true,
then run the status command again. The installer refuses a test-signed driver
unless Test Signing is configured and explicitly allowed.

## Install

From elevated PowerShell:

```powershell
.\install-apfs-for-windows.ps1 -AllowTestSignedDriver
```

Installation creates:

- Automatic service `ApfsForWindowsMountService`;
- dedicated side-by-side filesystem driver `WinFsp+apfs-main`;
- tray manager startup registration;
- Start menu shortcuts and Apps & Features registration;
- program files under `$env:ProgramFiles\APFS for Windows`;
- runtime configuration and logs under `$env:ProgramData\APFS for Windows`.

Supported APFS media mounts automatically after installation and on later
Windows starts.

## Verify

Run these commands from a normal PowerShell after installation:

```powershell
& "$env:ProgramFiles\APFS for Windows\apfs_mount_service.exe" --health
& "$env:ProgramFiles\APFS for Windows\apfs_mount_manager.exe" --self-test
```

Both commands return JSON. `ok` should be true. Plug in supported APFS media and
confirm a drive letter appears in Explorer and in the mount manager.

## Repair

From the extracted release directory, open elevated PowerShell:

```powershell
.\repair-apfs-for-windows-install.ps1 -AllowTestSignedDriver
```

Repair redeploys the exact extracted package, restores Automatic service mode,
restarts the tray manager, and verifies installed file hashes. It does not
restart Windows.

## Uninstall

Keep the extracted release directory until uninstall is complete. From elevated
PowerShell:

```powershell
.\configure-test-signing.ps1 -Action Disable
& "$env:ProgramFiles\APFS for Windows\uninstall-apfs-for-windows.ps1" -RemoveFiles
```

The uninstaller removes product services, driver, workers, tray manager,
startup registrations, shortcuts, application registration, configuration,
logs, and installed files. Restart Windows manually after disabling Test
Signing. Do not disable it when another test driver depends on it.

## Troubleshooting Installation

- `Secure Boot is enabled`: disable Secure Boot in firmware, then retry Test
  Signing configuration.
- `Test-signed driver was not allowed`: rerun installer with
  `-AllowTestSignedDriver` after reviewing this release model.
- `restart_required` remains true: restart Windows and recheck status.
- payload validation fails: download the release ZIP again and compare its
  SHA-256 value with the release asset digest.
- installation remains locked: close product tools and rerun repair; the scripts
  report a restart requirement instead of terminating Explorer or shared
  services.
