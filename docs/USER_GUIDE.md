# User Guide

## Automatic Mounting

The mount service starts automatically with Windows. When supported APFS media
appears, the service validates the device, chooses a free drive letter, and
starts a supervised filesystem worker. Newly discovered supported media mounts
read/write by default. Explicit saved policy always wins.

Unmount or eject writable media before unplugging it. Physical surprise-unplug
and power-loss recovery are not certified.

## Tray Manager

The stacked `AP`/`FS` icon starts at logon and remains available when the main
window is closed. Right-click actions include:

- `Open`: open the mount manager;
- `Exit`: close the interactive tray manager.

Exiting the tray does not stop the Automatic service or mounted filesystems. The
tray returns at the next logon unless the product is uninstalled.

## Mount Controls

Select a mount in the manager to:

- open its Explorer drive;
- refresh health and discovery;
- change the drive letter;
- switch read-only/read-write mode;
- enable or disable automount;
- unmount the current device;
- copy health details for support.

Read-only mode blocks create, update, rename, and delete operations. Disabling
automount preserves policy but removes the active mount.

## Supported File Operations

Explorer access includes regular file and directory operations, timestamps,
Windows attributes, compatible security metadata, symbolic links, hard links,
extended attributes, and alternate data streams. APFS content-critical and
filesystem-owned metadata remains protected.

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

- No drive appears: refresh discovery, inspect health JSON, and confirm the
  volume is supported and no saved policy disables it.
- Drive-letter collision: choose another free letter in the manager.
- Write denied: check whether the mount or volume policy is read-only.
- Tray missing: launch `APFS Mount Manager` from the Start menu; its
  single-instance guard prevents duplicate tray icons.
- Worker stopped: the Automatic service normally restarts it. Persistent failure
  details appear in service health and rotating logs.
- Device removed unexpectedly: reconnect it, inspect health, and verify data from
  a backup-aware workflow before continuing writes.

For security issues, follow [SECURITY.md](../SECURITY.md).
