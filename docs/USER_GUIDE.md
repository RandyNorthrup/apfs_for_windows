# User Guide

## Automatic Mounting

The mount service starts automatically with Windows. When supported APFS media
appears, the service validates the device, chooses the lowest free drive letter
from `D:` onward, and starts a supervised filesystem worker. A device the service
has not seen before mounts read-only. To change files on it, turn on
**Read/write access** for that volume in the tray (see
[Mount Controls](#mount-controls)). The choice is saved per volume, and saved
policy always wins on later connections.

The filesystem transport is the official WinFsp driver installed system-wide
(see [Installation](INSTALLATION.md)). If WinFsp is removed, volumes cannot
mount until it is installed again.

When the service stops or Windows shuts down, every volume is unmounted cleanly
first. Unmount writable media before unplugging it. Physical surprise-unplug
and power-loss recovery are untested.

## Tray Manager

The stacked `AP`/`FS` icon starts when you sign in and stays available when the
main window is closed. A small colored badge shows the overall state:

| Badge | Meaning |
|---|---|
| Green | Service running, at least one volume mounted |
| None | Service running, nothing mounted (or still loading) |
| Amber | A volume cannot mount because its drive letter is in use |
| Red | Service stopped or not installed |

Hover over the icon for a one-line summary. Left-click or double-click opens the
manager window.

### Tray Menu

Right-click the icon for:

- **Service status**: the first line, for example
  `Service running · 1 volume mounted`.
- **One submenu per volume**, named with its label and status (`Mounted`,
  `Unmounted`, `Not connected`, `Automount off`, or `Drive letter in use`):
  - **Open in Explorer**;
  - **Read/write access**: checked when writable;
  - **Mount automatically**: checked when automount is on;
  - **Change drive letter…**;
  - **Unmount**, or **Mount** for a volume you unmounted earlier.
- **Search for APFS devices**: asks the service to rescan now.
- **Open**: opens the manager window.
- **Settings**:
  - **Start at sign-in**: starts the tray when you sign in. This setting is
    per user and matches the entry in **Settings > Apps > Startup**;
  - **Show notifications**: turns tray notifications on or off for your
    account.
- **View logs**: opens `%ProgramData%\APFS for Windows\logs`.
- **About APFS for Windows**.
- **Exit**: closes the tray icon only.

Exiting the tray does not stop the Automatic service or unmount anything. The
tray returns at the next sign-in when Start at sign-in is on.

### Notifications

When notifications are on, the tray tells you when:

- a volume is mounted and ready, with its access mode;
- a volume is removed or no longer mounted;
- the APFS service stops or starts again;
- a volume cannot mount because its drive letter is taken.

Click a notification to open the manager.

## Manager Window

The window lists every known volume with its drive, label, access mode, status,
automount setting, and device. The toolbar and the right-click menu on each row
offer the same actions as the tray, plus:

- **Refresh** and **Search for Devices**;
- **Diagnostics**: shows the raw service health JSON;
- **Copy JSON**: copies health details for a support request.

## Mount Controls

- **Read-only** blocks create, update, rename, and delete operations. Turning
  read/write on asks for confirmation. The service then checks the exact APFS
  target and its safety policy. Sealed, encrypted, and unsupported volumes stay
  read-only.
- **Automount off** unmounts the volume and keeps it unmounted, even across
  restarts and reconnects, until you turn automount back on.
- **Unmount (eject)** closes the volume so the device can be removed. Close
  files on the volume first. The service remembers the choice, so the volume
  stays unmounted while the device remains connected. It mounts again
  automatically after you disconnect and reconnect the device, or right away
  when you choose **Mount**.
- **Change drive letter** moves the volume to any free letter you pick.

## Standard Users and Administrators

The tray runs without elevation. Any user signed in at the computer can manage
volumes the service already knows about: open, unmount, mount, read-only or
read/write, automount, drive letter, and device search. The service still
applies its write-safety policy to every request.

Adding a new mount target by hand (`apfs_mount_service.exe --add-mount`)
requires an elevated administrator. Devices found automatically need no
elevation, because the service adds them itself. Remote and network callers are
always refused. Mount policy and logs in `%ProgramData%\APFS for Windows` are
read-only for standard users.

## Supported File Operations

Explorer access includes regular file and directory operations, timestamps,
Windows attributes, compatible security metadata, symbolic links, extended
attributes, and alternate data streams. APFS content-critical and
filesystem-owned metadata remains protected.

Hard links that already exist on the APFS volume open and read normally, and
their contents can be changed. Creating a new hard link from Windows (for
example `mklink /H` or `fsutil hardlink create`) is not supported with the
official WinFsp driver and fails. Create hard links on a Mac if you need them.

Current limits, which remain until the planned new write engine lands:

- Writes are committed one operation at a time, so copying many small files is
  slow and slows further as a directory grows. Reads, large files, and ordinary
  edits are not affected the same way.
- The current write engine re-checks the whole volume on every change. If
  any folder on the volume holds 1,000 or more items, or folders are nested
  more than 16 deep, the whole volume is write-protected from Windows: it
  still lists and reads completely, and changes report "The media is write
  protected". Many Mac system and user volumes exceed this; simple external
  drives usually do not.

## Protected Volumes

Writable mount requests fail closed for sealed, encrypted, per-file-key,
unknown-policy, malformed, and non-APFS targets. The manager reports the policy
reason instead of forcing a writable mount.

## Health Commands

```powershell
& "$env:ProgramFiles\APFS for Windows\apfs_mount_service.exe" --health
& "$env:ProgramFiles\APFS for Windows\apfs_mount_service.exe" --discover-apfs --max-physical-drives 8
& "$env:ProgramFiles\APFS for Windows\apfs_mount_manager.exe" --status
```

## Troubleshooting

- No drive appears: choose **Search for APFS devices**, inspect health JSON,
  and confirm the volume is supported, automount is on, and you did not unmount
  it earlier. A volume you unmounted shows `Unmounted`; choose **Mount** or
  reconnect the device.
- Drive letter in use (amber badge): choose another free letter with **Change
  drive letter…**.
- Write denied: check whether the mount or volume policy is read-only. New
  devices start read-only; turn on **Read/write access** in the tray.
- "The media is write protected": the volume has a folder with 1,000 or more
  items, or folders nested more than 16 deep, somewhere on it. This version
  cannot write to such a volume.
- New hard link fails: creating hard links from Windows is not supported.
- Tray missing: launch `APFS for Windows` from the Start menu and check
  **Settings > Start at sign-in**. Its single-instance guard prevents duplicate
  tray icons.
- Worker stopped: the Automatic service restarts it, backing off after repeated
  failures. Persistent failure details appear in service health and in
  **View logs**.
- Device removed unexpectedly: reconnect it, inspect health, and verify data from
  a backup-aware workflow before continuing writes.

For security issues, follow [SECURITY.md](../SECURITY.md).
