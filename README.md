# APFS for Windows

Native Windows Explorer APFS mount utility.

Current classification: **development-certified, not production-ready**. See
`docs/PRODUCTION_READINESS.md` for closed gates and exact blockers.

Current state:

- Local APFS core copy lives under `third_party/sak_apfs_core`, imported from
  source commit `5587736df4d27e0eb5ca6e9f60f3c69614023b13` and patched only
  inside this repository.
- Apple LZFSE/LZVN reference code is vendored under `third_party/lzfse` for
  APFS compression paths.
- Stock WinFsp runtime/SDK remains supported for development mounts. Release
  packages carry the dedicated side-by-side runtime/driver from a public repository
  `RandyNorthrup/winfsp-apfs` commit
  `b4650b187f2d0d95a660bb687177f67efc07588f` through one submodule on `main`.
  The dedicated driver coexists with stock WinFsp and transports native Windows
  hard-link create requests.
- `apfs_probe` can probe APFS images/raw devices, list the root directory, and
  read files by APFS path with SHA-256 output. It also has `--debug-file` for
  APFS inode/xattr/extent diagnostics on one path.
- `apfs_winfs_worker` implements a WinFsp APFS mount over the copied APFS
  reader/writer. Read-only remains default; read/write requires `--read-write`,
  and physical raw writes also require `--allow-raw-writes`.
- File create/write/delete/rename/move now routes arbitrary parent paths into
  the APFS writer instead of the old one-directory child APIs.
- Repeated Explorer reads use one copied-core reader session per mounted APFS
  generation. Uncompressed range reads fetch only the requested extents, and
  every successful mutation rebuilds the session before callbacks resume.
- Directory create/delete/rename/move now routes parent paths through copied core
  wrappers; empty directory delete and directory rename/move rebuild the APFS
  tree with one copy-on-write checkpoint.
- Large same-handle raw writes stage to a temp host file and stream through the
  APFS raw writer on flush, avoiding the old 64 MiB memory cap for Explorer
  copy-style writes. Image mounts keep the 64 MiB buffered guard.
- Existing-file overwrite now stages truncate plus payload as one APFS commit.
  Image commits use atomic `ReplaceFileW` promotion, and dead-worker scratch
  images are removed on the next image mount.
- `apfs_mount_service` installs as `ApfsForWindowsMountService` with Automatic
  startup, reads mount mappings from `C:\ProgramData\APFS for Windows\mounts.json`,
  discovers APFS whole devices plus GPT/MBR partitions by on-disk signature at
  service start, periodically syncs
  live config/device changes, supervises worker processes, and restarts failed
  mount workers so mounts return to normal Explorer/user sessions. It also has a
  local service IPC path so installed CLI/manager requests can update safe mount
  policy through the service instead of writing ProgramData directly.
- `apfs_mount_service --health` reports installed service state, startup type,
  service recovery policy, configured mounts, APFS filesystem identity, volume
  label, visible root entries, and drive-letter collisions as JSON. An unrelated
  volume occupying a configured letter is reported as a collision, not an APFS
  mount.
- Whole-device and zero-offset partition aliases are canonicalized to one raw
  region and one worker. The exact partition target wins, preventing two drive
  letters from mounting the same writable APFS bytes concurrently.
- Service and worker logs rotate at 8 MiB. Service startup also removes legacy
  oversized logs so an always-running installation cannot grow logs without a
  bound.
- `apfs_mount_manager` is now a Qt Widgets manager UI with an accessible mount
  table, refresh/discover/open/change-letter/read-write-mode/enable-disable/unmount/copy
  actions, raw health JSON view, and `--status`/`--self-test` verification
  modes. `--help`, `-h`, and `/?` print usage and exit without starting the UI.
- `apfs_mount_manager` creates a persistent tray icon using a stacked `AP` over
  `FS` icon. Right-click menu includes `Open` and `Exit`; closing the window no
  longer exits the app. Install/repair registers a machine-wide logon task plus
  an HKLM Run fallback for hidden `--tray` launch, and a local single-instance
  channel prevents duplicate icons.
- `apfs_core_selftest` verifies copied APFS writer/reader behavior against
  temporary images and a file-backed raw target: format/list/read, root and
  nested file write/rename/delete, directory create/delete/rename/move, raw
  streaming nested file write, raw file rename/move/delete, and preservation of
  an existing 16 MiB file. It also creates an Apple-compatible symbolic link and
  proves a later copy-on-write mutation preserves its directory type, inode mode,
  and `com.apple.fs.symlink` xattr. It also creates, replaces, deletes, recreates,
  and converts a regular-file data-stream xattr while preserving file content.
- Writable mounts commit Windows basic-info changes on files, named directories,
  and the volume root to APFS create/access/modify/change times and BSD flags.
  Windows security changes on all three persist APFS POSIX mode, owner, and group while a
  compatibility ACL keeps the mounted drive usable by the interactive user and
  service account.
- WinFsp reparse callbacks expose Apple symbolic links and create, follow,
  retarget, clear, or delete relative and same-volume absolute symbolic links.
  External absolute targets fail closed.
- WinFsp `GetEa`/`SetEa` callbacks expose APFS extended attributes on regular
  files, named directories, and the mounted volume root. Values through 3,804
  bytes remain embedded. Larger regular-file values transparently use APFS data
  streams up to the Windows EA wire limit: 65,535 bytes for direct printable
  ASCII names and 65,534 bytes for aliased names. Directory and volume-root
  mutations remain embedded-only. Windows defines zero-length EA sets as
  deletion and EA names as ASCII, so exact empty APFS values and UTF-8 APFS names
  use reserved `APFS.XATTR.<BASE32-UTF8>` wire aliases with a version byte.
  Aliases are transport only; raw APFS probes and macOS see exact original names
  and values. Create, read, remount persistence, update, and delete pass on local
  images and the physical USB target; embedded values also pass native macOS
  round trips. Content-critical attributes remain hidden and all recovered APFS
  `FILE_SYSTEM_OWNED` attributes fail closed on generic mutation. Protocol
  boundary:
  [Microsoft FILE_FULL_EA_INFORMATION](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-fscc/0eb94f48-6aac-41df-a878-79f4dcfd8989).
- Copied SAK APFS source is Randy-authored project code imported into this
  repo. Copied source-app license tags and branding notices were removed from
  code/docs per owner direction. Third-party notices remain for Qt, WinFsp, and
  Apple LZFSE.
- WinFsp file handles are owned by the mount state and reclaimed through a
  deferred close quarantine, avoiding the earlier unbounded raw `FileContext`
  allocation leak during repeated Explorer open/close cycles.
- Raw-device writes are still blocked by default. They require explicit
  read/write mount policy, `--allow-raw-writes`, exact-target APFS signature
  verification inside the service, and serial-pinned verifier evidence before
  USB write/delete proof is considered current.

Build:

```powershell
cmake -S . -B build -G "Visual Studio 17 2022" -A x64 -DCMAKE_PREFIX_PATH=C:\Qt\6.10.3\msvc2022_64 -DWinFsp_ROOT="C:\Program Files (x86)\WinFsp"
cmake --build build --config Release --parallel
ctest --test-dir build -C Release --output-on-failure
```

Production-mode configuration additionally requires a clean checkout of the
pinned dedicated WinFsp runtime, native hard-link ABI, `/W4 /WX`, and explicit coherent
WinFsp header/library/runtime paths. It also enables deterministic compilation,
`/Brepro`, and a stable source path map. Build metadata is emitted beside binaries.

Developer install, from elevated PowerShell:

```powershell
.\scripts\install-apfs-for-windows.ps1
```

Repair current install and verify automatically discovered APFS mounts, from
elevated PowerShell:

```powershell
.\scripts\repair-apfs-for-windows-install.ps1
```

From a normal PowerShell, use the guarded launcher. It refuses to start a new
UAC prompt if one is already pending and uses an encoded PowerShell command so
raw targets beginning with `\\?\` survive `Start-Process` argument handling:

```powershell
.\scripts\start-repair-elevated.ps1
```

The repair script redeploys the current build to `C:\Program Files\APFS for
Windows`, stops any lingering installed APFS worker processes before copying,
stops/relaunches the tray manager when run through the guarded launcher, keeps
`ApfsForWindowsMountService` Automatic/running, verifies auto-discovered mounts
and installed binary hashes, and writes
`artifacts\repair\install-repair-proof.json`. It does not reboot.
Packaged install/repair resolves Qt DLLs and `platforms\qwindows.dll` from the
extracted package before using a developer Qt path. Both scripts support
non-admin `-ValidatePayloadOnly` checks.
`start-repair-elevated.ps1 -SelfTest` validates encoded target/mount round-trip
without elevation; release-package verification runs this check automatically.

To pin one known mount to read-only during repair, pass both values:

```powershell
.\scripts\start-repair-elevated.ps1 -UsbTarget '\\?\GLOBALROOT\Device\Harddisk1\Partition1' -UsbMount V:
```

Configure a persistent read-only APFS mount:

```powershell
& "$env:ProgramFiles\APFS for Windows\apfs_mount_service.exe" --add-mount --target "\\.\PhysicalDrive2" --mount Z:
Start-Service ApfsForWindowsMountService
```

Verify installed service and APFS USB mount state:

```powershell
& "$env:ProgramFiles\APFS for Windows\apfs_mount_service.exe" --health
& "$env:ProgramFiles\APFS for Windows\apfs_mount_service.exe" --discover-apfs --max-physical-drives 8
& "$env:ProgramFiles\APFS for Windows\apfs_mount_manager.exe" --self-test
.\scripts\verify-current-apfs-state.ps1
.\scripts\verify-winfsp-prerequisite.ps1
.\scripts\verify-local-worker-rw-smoke.ps1
.\scripts\verify-local-worker-fileops.ps1
.\scripts\verify-local-worker-robocopy-stress.ps1
.\scripts\verify-local-worker-large-existing-fileops.ps1
.\scripts\verify-apple-vm-roundtrip.ps1 -MacHost <host> -MacUser <user> -PasswordFile <ignored-path>
.\scripts\verify-apple-vm-directory-root-stream-xattrs.ps1 -MacHost <host> -MacUser <user> -PasswordFile <ignored-path>
.\scripts\verify-service-control-ipc.ps1
.\scripts\verify-sak-source-boundary.ps1
.\scripts\verify-license-notices.ps1
.\scripts\build-release-package.ps1
.\scripts\verify-release-package.ps1
.\scripts\verify-reproducible-build.ps1
.\scripts\verify-service-recovery-policy.ps1
.\scripts\verify-start-menu-entries.ps1
.\scripts\verify-installed-app-registration.ps1
.\scripts\verify-installed-service-mode-policy.ps1 -PreflightOnly
.\scripts\deploy-current-worker-for-certification.ps1
.\scripts\start-repair-elevated.ps1
.\scripts\run-apfs-for-windows-certification.ps1 -UsbExpectedSerial '<serial>' -RunUsbWriteProof
.\scripts\verify-usb-mounted-file-actions.ps1 -CleanupStaleProofEntries
.\scripts\verify-apfs-boot-persistence.ps1 -VerifyNow
.\scripts\verify-service-worker-restart.ps1 -ExpectedSha256 5DE304A213068C0F526D99253D0D4A18A4652E95D010A0E96D43CB5ED758A32B
.\scripts\verify-apfs-auto-discovery.ps1 -RestoreOriginalConfig
.\scripts\verify-service-live-sync.ps1
.\scripts\verify-service-remove-mount.ps1
.\scripts\verify-service-drive-letter.ps1
.\scripts\verify-service-policy.ps1
.\scripts\verify-service-target-loss.ps1
.\scripts\verify-service-device-notifications.ps1
.\scripts\verify-usb-raw-rw.ps1 -ExpectedSerial '<serial>'
.\scripts\verify-usb-normal-user-rw.ps1 -ExpectedSerial '<serial>' -NoDiagnostics
```

`deploy-current-worker-for-certification.ps1` validates exact clean-main build
metadata without elevation by default. Run it from Administrator PowerShell with
`-Apply` only for a worker-only physical-USB certification deployment. It hashes
the source and installed worker, preserves Automatic service mode, verifies the
driver did not change, and rolls back a failed replacement.

Apple VM round-trip verification accepts connection data only as runtime
parameters. No password, key, or password-file content is copied into source or
proof JSON. It creates a Windows APFS image, mutates and checks it with the macOS
kernel plus `fsck_apfs`, mutates it again through WinFsp on Windows, then runs a
second native macOS mount and `fsck_apfs` pair. File, named-directory, and
volume-root xattrs are mutated in both directions; root basic-info and POSIX
security metadata are also validated through raw APFS inode state and native
macOS presentation. Empty xattr values and exact UTF-8 names are included on
regular files, named directories, and the volume root. A separate lane verifies
9,001-byte Windows-created root/directory stream xattrs, 12,017-byte macOS
replacement, Windows return readback, and three native `fsck_apfs` passes.
Latest sanitized evidence:
`docs/evidence/apple-vm-roundtrip-2026-08-17.json` and
`docs/evidence/directory-root-stream-xattrs-2026-08-17.json`.

Serial-pinned normal-user USB write/delete proof is current. The verifier keeps
file actions in the non-admin parent process, uses service IPC only to switch
the pinned mount policy temporarily, restores the selected mount read-only, and writes
`artifacts\usb-rw\usb-normal-user-rw-proof.json`. Use the non-mutating state
check first:

```powershell
.\scripts\verify-current-apfs-state.ps1 -UsbTarget '\\?\GLOBALROOT\Device\Harddisk1\Partition1'
.\scripts\verify-usb-normal-user-rw.ps1 -DiskNumber 1 -PartitionNumber 1 -ExpectedSerial '<serial>' -Mount V: -NoDiagnostics
```

`-NoDiagnostics` uses the same mutation path but skips large trace/log tails in
the final JSON so the proof cannot stall after successful file operations.

Normal Explorer-style file actions are expected to run as the current user once
the APFS mount is configured. The current verifier proves a root proof directory
plus one direct child file create/write/rename/overwrite/delete, then deletes the
empty proof directory without elevation or service policy changes:

```powershell
.\scripts\verify-usb-mounted-file-actions.ps1 -PreflightOnly
.\scripts\verify-usb-mounted-file-actions.ps1 -CleanupStaleProofEntries
.\scripts\run-apfs-for-windows-certification.ps1 -UsbExpectedSerial '<serial>' -RunUsbMountedFileActions
```

Service policy changes still touch ProgramData; the current machine rejected a
non-admin read-only restore with
`Unable to write C:/ProgramData/APFS for Windows/mounts.json`.

Arm a next-login persistence proof before reboot:

```powershell
.\scripts\verify-apfs-boot-persistence.ps1 -ArmNextLogon -OutputPath artifacts\boot-persistence\post-reboot-verification.json
```

For no-reboot current-state proof on a large mounted USB file, use partial-read
mode:

```powershell
$f = "Predator Badlands 2025 1080p WEB-DL HEVC x265 5.1 BONE.mkv"
$entries = ".Spotlight-V100", ".fseventsd", "New folder", $f
.\scripts\verify-apfs-boot-persistence.ps1 -VerifyNow -Mount Y: -ExpectedFile $f -ExpectedEntries $entries -ReadProbeOnly -ReadProbeBytes 4096
```

Uninstall:

```powershell
.\scripts\uninstall-apfs-for-windows.ps1 -RemoveFiles
```

The uninstaller stops the service, waits for worker/mount and tray-manager
teardown, deletes the service, removes the logon task and HKLM Run fallback,
optionally removes installed files, and writes
`artifacts\uninstall\uninstall-proof.json`.
Install/repair also deploy Start Menu shortcuts for the manager and elevated
uninstall flow; `scripts\verify-start-menu-entries.ps1` verifies those shortcuts
and the installed uninstall script.
Install/repair register `APFS for Windows` under Windows Apps & Features with an
uninstall command; `scripts\verify-installed-app-registration.ps1` verifies that
registration.

Build a release ZIP without installing:

```powershell
.\scripts\build-release-package.ps1
.\scripts\verify-release-package.ps1
```

Production packaging is the default and requires a production-signed dedicated
driver. It stages `artifacts\package\APFS-for-Windows-0.1.0`, creates
`artifacts\package\APFS-for-Windows-0.1.0.zip`, and verifies the required
binaries, bundled side-by-side WinFsp DLL/driver, Qt runtime files,
install/repair/uninstall scripts, README, license notices, APFS/WinFsp
provenance, build metadata, payload manifest, and SHA-256 list. Package
verification also rehashes every manifest and ZIP entry and runs install and
repair payload-only validation from the staged directory. Tracked text is
normalized to UTF-8 without a BOM and LF during staging. Package manifests use
compact UTF-8 JSON with fixed LF endings and ordinal paths. ZIP entries use
stored data, ordinal path ordering, and a fixed timestamp so identical staged
payloads produce identical archives across supported PowerShell runtimes.
Packaging refuses a dirty checkout or build metadata that does not
exactly match `HEAD`, and records that source commit in the release manifest.
`verify-reproducible-build.ps1` checks out one commit at two distinct
temporary paths, builds and tests both, verifies both packages, compares every
shipped project executable and metadata file, compares the complete ZIP, and
removes both worktrees. Packaging runs once under Windows PowerShell 5.1 and
once under PowerShell 7 to detect runtime-dependent archive bytes. It does not
install, elevate, or reboot.
Exact source commit `0c51b376d1890004ea41aff67555fef6a3aebd04` passed the
cross-runtime two-worktree proof with two 13/13 CTest runs, package verification
under Windows PowerShell 5.1 and PowerShell 7, and byte-identical binaries,
metadata, and 31,709,496-byte test-signed ZIP. ZIP SHA-256 was
`FB484D4FD07C235248E92EB51A083309027F4C8EC9217143367B710FF182AC86`.
Sanitized evidence is retained in
`docs\evidence\reproducible-build-2026-08-17.json`.

The explicit test path uses `-DriverSigningMode Test -AllowTestSignedDriver` on
both scripts and emits `APFS-for-Windows-0.1.0-test-signed.zip`. The current test
candidate passed clean Windows 11 VM install, Automatic service and mount
persistence across VM reboot, exact installed runtime hashes, one interactive
stacked `AP`/`FS` tray icon with `Open` and `Exit`, and uninstall with no product
or dedicated-driver residue. This closes the development lifecycle gate only;
production still requires Microsoft-compatible driver signing and
Authenticode-signed application binaries. Exact package identity is recorded
outside the archive in `docs\evidence\winfsp-hardlink-package-2026-08-17.json`.
Clean-source test candidate SHA-256
`50EECCD5ECDD4A3393FD26C8DF932E3C13858D35476574DF226681EC8B432FA5`
passed build/package/interoperability proof. A second clean-source package,
SHA-256 `55A7CEAA0FE3FC975AD9D2B1D282F0CA3AF26080E4EF888CAAE9DB5DA2D677DA`,
passed exact Windows VM install/reboot/tray/uninstall lifecycle. Evidence is in
`docs\evidence\clean-candidate-2026-08-17.json`. Both remain test-signed and are
not production releases.

License notices:

```powershell
.\scripts\verify-license-notices.ps1
```

This verifies project license presence plus Qt, WinFsp, and Apple LZFSE notices.

WinFsp prerequisite:

```powershell
.\scripts\verify-winfsp-prerequisite.ps1
```

This development check verifies stock WinFsp registry registration, SDK
header/import library, runtime DLL/driver, and worker support. Release packages
instead install and verify their pinned dedicated side-by-side runtime.

Copied APFS core source boundary:

Do not edit `C:\Users\Randy\Coding\S.A.K.-Utility` for this project. Copy or
import code into this repository first, then modify the local copy only.
`scripts\verify-sak-source-boundary.ps1` verifies the source checkout status,
recorded commit/blob/file hashes, exact copied APFS file set, and declared local
copied-core deltas under `third_party\sak_apfs_core`. Unrelated source-checkout
work is reported but does not invalidate unchanged imported APFS paths.

Repository and production gates:

Repository hygiene enforces `main` as the only owned local branch. Detached
GitHub Actions checkouts are accepted, but additional owned branches fail.

```powershell
.\scripts\verify-repository-hygiene.ps1
.\scripts\verify-winfsp-runtime-boundary.ps1
.\scripts\verify-production-readiness.ps1
```

Strict production readiness intentionally fails while production driver/app
signing, production-signed exact-package lifecycle, physical fault recovery,
remaining APFS policy, and release-governance evidence remain open.

Verified USB evidence:

- Disk 2, Seagate Expansion Desk, serial redacted, USB, non-boot/non-system,
  stayed Windows-offline/RAW for raw-device proof.
- Service-launched `Z:` read-only APFS mount lists `clone.bin`, `link.bin`,
  `src.bin` in normal shell.
- Earlier startup auto-discovery found GPT APFS
  `\\?\GLOBALROOT\Device\Harddisk1\Partition2` and mounted it read-only at `Y:`.
- All three files read as `A7-RAW-CERT-SHARED-PAYLOAD-2026` with SHA-256
  `5DE304A213068C0F526D99253D0D4A18A4652E95D010A0E96D43CB5ED758A32B`.
- Normal write attempt to `Z:\normal-write-deny-test.txt` is denied.
- In the July media layout, Disk 1, `USB DISK 3.0`, serial redacted, GPT APFS partition 2,
  30,832,287,744-byte APFS partition, is pinned for destructive USB RW proof.
  Earlier proof artifacts are historical; current USB RW verifiers use one root
  proof directory plus one direct child file, then restore read-only config
  without rebooting or restarting the service.
- Historical serial-pinned normal-user USB RW proof: on
  `2026-07-10T06:51:00Z`, `scripts\verify-usb-normal-user-rw.ps1 -NoDiagnostics`
  passed against Disk 1 partition 2 at `Y:` as a normal user without reboot:
  proof directory create passed, child file write hash matched
  `84430AC23FB71E125BF33F1D9A1DE3E30676F8EE776CB4B790BCDCD4905F2FC1`, rename
  passed, file delete passed, directory delete passed, service PID stayed
  `128168`, and `Y:` was restored read-only with raw writes disabled. Artifact:
  `artifacts\usb-rw\usb-normal-user-rw-proof.json`.
- `scripts\verify-usb-mounted-file-actions.ps1` is the direct mounted-drive file
  action proof. It never elevates, never edits service config, refuses a stale
  installed worker by default, supports `-PreflightOnly` for a zero-mutation
  readiness check, optionally removes stale root proof directories with the
  `sak-user-rw-manual-proof-*` prefix, waits for final mount visibility, records
  initial/final mount policy, reports any stale entries still visible after
  cleanup, labels `-AllowStaleInstalledWorker` runs as
  `current_installed_mount_only`, and only mutates its own
  `sak-mounted-file-actions-proof-*` directory on the selected mount during full
  proof. It verifies file, named-directory, and volume-root EA
  create/read/update/delete, including exact UTF-8 names and zero-byte values,
  in addition to file namespace, metadata, ACL, and symbolic-link operations.
  It also performs a transient volume-root basic-info
  proof and restores original Windows-visible times and flags within Windows
  `FILETIME` precision; it does not modify physical root security.
  Current certification wraps this proof in an explicit temporary writable
  policy window, then restores the selected mount read-only afterward.
- Current volume-root USB proof completed at `2026-08-17T00:58:11Z` against the
  serial-pinned Partition 1 target at `V:`. Root basic-info accepted fixed
  create/access/write times plus Hidden/Archive flags, then restored original
  Windows-visible values within 100 ns `FILETIME` precision. Root,
  named-directory, and file EA create/read/update/delete also passed for direct,
  exact UTF-8-name, and empty-value cases; proof tree
  was removed; root security was not changed; `V:` was restored read-only with
  raw writes disabled. Artifact:
  `artifacts\usb-rw\usb-mounted-ea-edge-proof.json` and sanitized evidence
  `docs\evidence\xattr-edge-cases-2026-08-17.json`.
- Latest current-build USB proof completed at `2026-08-17T04:27:41Z` against
  the exact Partition 1 target at `V:`. The installed and build workers matched
  SHA-256 `9F01F88C...125B2`. Non-admin create/read/rename/overwrite/delete,
  metadata, ACL, symlink, file/directory/root EAs, cleanup, and exact 9,001-byte
  then 12,017-byte regular-file stream EA replacement/deletion passed. The proof
  directory was removed and root metadata was restored. Per owner direction,
  the pinned test mount remains explicitly read/write with raw writes enabled;
  newly discovered mounts still default read-only. Sanitized evidence:
  `docs\evidence\stream-xattr-usb-2026-08-17.json`.
- Current media layout changed during SAK recertification. On
  `2026-08-16T17:22:33Z`, the same pinned 31,042,043,904-byte USB disk exposed
  Windows MBR Partition 1 at `V:` while the exact target probe identified a
  536,870,912-byte APFS container by `RawSignature`. Normal-user proof passed:
  directory create, file write/hash, rename/hash, file delete, directory delete,
  no service restart, no reboot, and automatic restore to read-only/raw-disabled.
  Hash: `89BB2ED96A9521257813B3E5FF3AD25466F6FEEB71AE04D1C1EF1D0A9E0AEA8B`.
  Artifact: `artifacts\usb-rw\usb-normal-user-rw-proof.json`.
- Current extended normal-user proof is
  `artifacts\usb-rw\usb-native-extended-unicode-proof.json`. It passed nested
  Unicode names, a 394-character path, Robocopy with a 1 MiB payload, four
  concurrent readers with matching hashes, recursive cleanup, and read-only/
  raw-disabled restoration without restarting the service or Windows. The
  persistent reader session reduced this lane from 71.8 seconds to 34.3 seconds.
- `artifacts\service-aliases\raw-alias-deduplication-session-proof.json` proves
  `\\.\PhysicalDrive1` and Partition 1 resolve to `disk:1:offset:0`, while only
  exact Partition 1 remains configured at `V:` across service resync intervals.
- `scripts\verify-current-apfs-state.ps1` generated
  `artifacts\state\current-apfs-state.json`. The latest direct proof independently
  confirms the installed worker matches the current build, stale proof entries
  are gone, and the service is Automatic/running. The pinned `V:` test mapping
  is intentionally writable; this does not change the default read-only policy
  for newly discovered media.
- `artifacts\usb-rw\icons8-jester-debug-before-delete.json` captured the stale
  `icons8-jester.svg` inode before cleanup. `apfs_probe --debug-file` showed no
  decmpfs/resource-fork payload and an impossible APFS extent block
  `1753640960` outside the 30 GB container, so the file was classified as
  corrupt test-media metadata rather than a compression reader gap.
- `artifacts\usb-rw\delete-corrupt-icons8-svg-ready-wait.json` proves the
  corrupt `Y:\icons8-jester.svg` entry was deleted through the mounted WinFsp
  drive after waiting for the live writable worker ACL/attributes, then `Y:` was
  restored read-only without reboot.
- `scripts\repair-apfs-for-windows-install.ps1` is ready for the required
  elevated recovery step. It stops the service, reaps any lingering installed
  APFS worker/manager processes, redeploys current binaries, optionally restores
  an explicitly pinned USB mount to read-only, otherwise verifies automatic
  discovery, configures restart-on-failure service recovery, verifies
  service/binary/mount state, records `worker_cleanup`, and writes
  `artifacts\repair\install-repair-proof.json`.
- `scripts\start-repair-elevated.ps1` is the normal-user guarded launcher for
  repair. It writes `artifacts\repair\start-repair-elevated-proof.json`, refuses
  to create another UAC prompt while `consent.exe` is already pending, and waits
  for the elevated repair proof artifact when launched.
- `scripts\verify-service-recovery-policy.ps1` checks the installed service is
  Automatic with three SCM restart actions and non-crash failure recovery enabled.
- `scripts\verify-service-control-ipc.ps1` generated
  `artifacts\service-control\service-control-ipc-proof.json`. It runs without
  admin or USB mutation and proves service-control request handlers, local socket
  transport, safe read-only/read-write policy changes, raw-write denial, and
  manager UI command surface are present in the current build.
- `scripts\verify-local-worker-fileops.ps1` generates
  `artifacts\local-fileops\worker-fileops-proof.json`. It runs without admin or
  USB mutation and proves a generated APFS image mount accepts Robocopy direct
  child-file copy into one root proof directory, all-file hash verification,
  edit, `MoveFileEx` replace-existing rename, file rename, recursive delete, and
  post-unmount probe.
  Default mount selection falls back to a free drive letter when its preferred
  letter is occupied; an explicitly requested conflicting letter remains a hard
  failure.
- `scripts\verify-local-worker-robocopy-stress.ps1` generated
  `artifacts\local-robocopy-stress\worker-robocopy-stress-proof.json`. It runs
  without admin or USB mutation and repeats the Explorer-style Robocopy
  copy/hash/edit/`MoveFileEx` replace/recursive-delete flow 10 times against a
  generated APFS image at `T:`.
- `scripts\verify-local-worker-large-existing-fileops.ps1` generates
  `artifacts\local-large-fileops\worker-large-existing-fileops-proof.json`. It
  runs without admin or USB mutation and proves the current worker can mount an
  APFS image containing existing 16 MiB `large.bin`, create one root proof
  directory, write/rename/overwrite/delete one direct child file, remove the
  proof directory, then probe `large.bin` after unmount with the same SHA-256.
  It also auto-selects a free default mount when physical APFS mounts occupy its
  preferred letter.
- `scripts\verify-local-worker-crash-recovery.ps1` generates
  `artifacts\local-crash-recovery\worker-crash-recovery-proof.json`. It mounts
  fresh APFS image copies read/write and forces worker exit code `197` immediately
  before and after atomic image replacement. Raw probe plus read-only remount
  select only expected old bytes before replacement and expected new bytes after
  replacement. A pre-replace scratch image is detected, then removed by remount
  recovery. Test fault options reject raw targets and read-only mounts.
- `scripts\verify-windows-vm-disposable-raw-interruption.ps1` uses the named
  Windows VM for an elevated, no-host-reboot raw-device test. It installs the
  exact package, attaches a disposable fixed VHD, first requires a completed
  16 MiB copy to retain the exact payload after probe/remount, then terminates
  the worker during a later raw commit and accepts only the complete old or new
  APFS generation. It uninstalls the package and removes the remote run after a
  pass. Current proof passed an exact 16 MiB completed copy, then terminated the
  worker after 328 raw blocks changed but before checkpoint completion; remount
  selected the complete old generation and preserved the invariant file. This
  synthetic lane does not replace physical surprise-unplug proof. Sanitized
  evidence: `docs/evidence/windows-vm-raw-interruption-final-2026-08-17.json`.
- `scripts\verify-apple-vm-interrupted-image.ps1` sends the selected interrupted
  image to macOS for two `fsck_apfs -n` passes and a kernel read-only mount. The
  current image passed exact transfer, invariant, and complete old-generation
  hashes, then detached and removed all remote artifacts. Sanitized evidence:
  `docs/evidence/apple-vm-raw-interruption-final-2026-08-17.json`.
- `scripts\verify-installed-service-mode-policy.ps1` is ready for the post-repair
  installed-service proof. It runs without admin or USB mutation, mounts a
  generated APFS image through the installed service, proves read-only write
  denial, flips to read/write through service policy, writes/deletes a file,
  flips back to read-only, and removes the mapping. Current post-repair
  preflight passes.
- `scripts\run-apfs-for-windows-certification.ps1` writes
  `artifacts\certification\apfs-for-windows-certification.json`. It runs build,
  CTest, script parse, local worker, service IPC, package, license, WinFsp,
  copied-core, installed-state, raw-alias, direct mounted-drive USB file-action,
  deterministic image crash recovery, and serial-pinned USB RW proof gates. With
  `-RunAppleVmRoundTrip`, it also requires the general native macOS mutation
  round trip plus the root/directory stream-xattr lane, with seven clean
  `fsck_apfs` passes across both artifacts.
  Treat that artifact as the authoritative result for the checked-out build.
  Current local proof includes a 100-iteration Robocopy soak and real APFS
  basic-info/security, symbolic-link, and file/named-directory/volume-root EA
  mutation on both disposable images and the serial-pinned physical USB.
  Regular-file, named-directory, and volume-root stream-backed EAs pass 9,001-
  byte create/read, 12,017-byte replacement, and deletion. Volume-root basic-info
  and POSIX security persistence also pass
  copied-core, local remount, and native macOS round-trip lanes; physical USB
  basic-info is changed and restored within Windows 100 ns timestamp precision,
  while physical root security is intentionally left unchanged. Native hard-link
  creation and regular-file/directory/root stream-backed xattr mutation are
  implemented and development-certified. APFS xattr names that differ only by
  case use distinct deterministic aliases; ambiguous direct writes fail closed.
  Remaining public-RW gates are physical raw-media power-loss recovery, real
  surprise-unplug, and sealed/FileVault/filesystem-owned mutation policy beyond
  current fail-closed behavior.
  Empty values and exact UTF-8 xattr names are certified through the reserved
  Windows EA transport.
  Existing Apple hard links remain preserved across Windows mutations. Copied
  APFS core now creates arbitrary-depth hard links and preserves sibling IDs.
  Dedicated `winfsp-apfs` runtime transports native Windows hard-link requests and
  reports link counts. Exact test-driver/DLL/worker runtime proof and package
  install/reboot/uninstall now pass; production driver signing remains open.

Verified copied-core mutation evidence:

- Current `ctest --test-dir build -C Release --output-on-failure` passes 13/13,
  including `apfs_service_partition_parser`, `apfs_service_control_self_test`,
  `apfs_service_ipc_self_test`, and `apfs_service_log_rotation`.
  These exercise service-side safe config requests, set-enabled/remove behavior,
  raw-write denial, and actual local socket transport against a temporary
  ProgramData root.
- The previous worker-side physical raw mutation guard has been removed after
  importing the recertified APFS writer code. Physical raw writes remain
  opt-in through read/write mount policy plus `--allow-raw-writes`.
- `artifacts\service-control\service-control-ipc-proof.json` proves those same
  service-control paths plus the manager self-test from a non-admin PowerShell
  verifier, including the manager read/write mode control.
- `apfs_core_selftest` proves temp APFS image format/list/read plus image-only
  COW root-file insert, replace, rename, delete, root-directory create/delete,
  direct directory-child write/rename, child move to root, nested directory
  create, and file-backed raw directory create/delete while preserving a 16 MiB
  existing file through the vendored `third_party\sak_apfs_core` code. It also
  creates, reads, preserves across unrelated COW mutations, and deletes a
  volume-root embedded xattr. Regular-file, named-directory, and volume-root
  xattr coverage includes data-stream create/read at 9,001 bytes, replacement at
  12,017 bytes, deletion, persistence across unrelated mutation, and conversion
  back to embedded storage. Directory deletion queues owned stream blocks for
  crash-safe reclaim. Worker policy regression verifies deterministic aliases
  for case-colliding names and rejects ambiguous direct writes.
- `apfs_core_selftest` also composes interrupted checkpoint images from the real
  pre-commit and committed bytes. The current insert changes 18 blocks: readers
  select the old generation before checkpoint-map publication, the old generation
  before checkpoint-superblock publication, and the new generation after that
  superblock is published even if the primary block-zero mirror is absent. Each
  phase preserves the seed-file hash and reports `old_or_new_only=true`.
- `artifacts\rw-mount\rw-mounted-y-smoke.json` proves a WinFsp APFS image mount
  at `Y:` created, read, renamed, replaced, and deleted `renamed-mount.txt`.
- `artifacts\rw-mount\rw-fixture-after-mount-probe.json` proves the final image
  is readable after unmount and contains only the expected original `renamed.txt`.
- `artifacts\rw-mount\rw-mounted-y-directory-smoke.json` proves a WinFsp APFS
  image mount created `ProofFolder`, wrote and renamed a child file, moved it to
  root, and deleted the empty directory.
- `artifacts\rw-mount\rw-dir-fixture-after-mount-probe.json` and
  `artifacts\rw-mount\rw-dir-fixture-read-moved-root.json` prove the final image
  is readable after unmount and `/moved-root.txt` has the expected payload hash.
- `scripts\verify-local-worker-rw-smoke.ps1` generates
  `artifacts\local-mount-smoke\worker-rw-smoke-proof.json`, proving the freshly
  built worker can mount a generated APFS image at `W:` without admin, create one
  root proof directory, write/hash/rename/delete a direct child file, delete the
  empty proof directory, unmount, and leave the APFS image probeable.
- `artifacts\local-fileops\worker-fileops-proof.json` proves Explorer-style file
  operations against a generated APFS image at `V:`: Robocopy copies direct child
  files into one root proof directory; hashes match; a child file is edited;
  `MoveFileEx` replaces an existing file through WinFsp rename; a file is
  renamed; the proof directory is recursively deleted; and the image probes
  cleanly after unmount with only `large.bin` and `seed.txt` at root.
- `artifacts\local-robocopy-stress\worker-robocopy-stress-proof.json` proves
  the same Explorer-style Robocopy mutation sequence over 10 repeated proof
  directories at `T:`. Each iteration copies direct child files, verifies all
  hashes, edits one child file, replaces an existing file through `MoveFileEx`,
  removes the proof tree recursively, and the final APFS probe shows only
  `large.bin` and `seed.txt` at root.
- `artifacts\local-large-fileops\worker-large-existing-fileops-proof.json`
  proves the current worker handles the USB-failure class locally: image has
  existing 16 MiB `large.bin`, mounted at `U:` without admin, root proof
  directory plus direct child-file create/rename/overwrite/delete pass,
  `large.bin` SHA-256 stays
  `35D355B6F8D7D459B5FC1E66B6C459238F330BCFAE7B291583DA5C528BE0ED5D`, and
  post-unmount probe showed no `LargeExistingProof` residue.
- `artifacts\handle-lifetime\handle-lifetime-stress.json` proves 250 repeated
  directory/read/hash iterations on a mounted APFS image, with 4,010 close events
  and no worker exit.
- `artifacts\install-upgrade\install-upgrade.log` proves the installed Automatic
  service was upgraded with the current binaries and restarted.
- `artifacts\service-supervision\worker-restart-proof.json` proves the installed
  Automatic service restarted a killed `apfs_winfs_worker.exe` child and restored
  `Z:` with expected entries and SHA-256 intact.
- `artifacts\auto-discovery\service-auto-discovery-proof.json` proves the
  installed service can start from an empty mount config, discover both APFS
  devices read-only, mount Disk 2 at a free drive letter, verify `src.bin`
  SHA-256, deny writes, and restore the original config without rebooting.
- `artifacts\live-sync\service-live-sync-proof.json` proves the already-running
  service picked up a new APFS image mapping at `X:`, served
  `moved-root.txt`, then removed the worker after config restore without service
  restart or reboot.
- `artifacts\remove-mount\service-remove-mount-proof.json` proves
  `apfs_mount_service --remove-mount` removes a configured APFS image mount, live
  sync stops the worker, `X:` disappears, and service PID stays unchanged.
- `artifacts\drive-letter\service-drive-letter-proof.json` proves
  `apfs_mount_service --set-mount` changes a configured APFS image from `X:` to
  `W:`, live sync remounts it at the new letter, expected SHA-256 still matches,
  the old letter disappears, cleanup removes the worker, and service PID stays
  unchanged.
- `artifacts\policy\service-policy-proof.json` proves
  `apfs_mount_service --set-enabled --target ... --enabled false|true` retains a
  disabled mapping in config, removes the worker while disabled, remounts after
  enable, restores the original config, and keeps the service PID unchanged.
- `artifacts\target-loss\service-target-loss-proof.json` proves live sync skips
  unavailable APFS targets, removes the failed worker/mount while keeping the
  saved config, remounts when the target returns, and keeps the service PID
  unchanged.
- `artifacts\device-notifications\service-device-notifications-proof.json`
  proves the installed Automatic service registered Windows disk device
  notifications for APFS resync after service start, with no registration
  failures and both APFS mounts still present read-only.
- `artifacts\manager\installed-manager-status.json` and
  `artifacts\manager\installed-manager-self-test.json` prove the installed Qt
  manager can load, read service health, see both APFS mounts, expose accessible
  controls including automount policy, and use the deployed Qt
  Widgets/Gui/qwindows runtime.
- `artifacts\usb-probe\service-mounted-z-write-deny-after-dir-upgrade.json` proves
  the physical USB mount at `Z:` still denies writes after the directory-RW worker
  upgrade.
- `artifacts\usb-probe\service-mounted-z-handle-stress.json` proves 200 repeated
  normal-user reads from the physical USB mount after the handle-table upgrade,
  with the service still running and hashes stable.
- `artifacts\boot-persistence\service-health-installed.json` proves the installed
  service binary reports Automatic/running state and sees `Z:` plus discovered
  `Y:` APFS mounts with expected root entries.
- `artifacts\boot-persistence\current-persistence-verification.json` proves the
  earlier installed service/mount persistence state before the normal-user RW
  diagnostic: service Automatic, `Z:` mounted, expected file hash matches, and
  write probe is denied. Current post-repair state separately confirms `Y:` is
  read-only with raw writes disabled. Host post-reboot proof remains prohibited,
  but Windows 11 VM reboot persistence and uninstall lifecycle proof now pass and
  are tracked under `docs\evidence`.
- `artifacts\boot-persistence\apfs-persistence-y-verification.json` proves the
  current no-reboot `Y:` persistence state: service Automatic/running, mounted
  root entries visible, existing movie file read probe returns 4096 bytes, and a
  read-only write probe is denied.
- The July USB read gap was closed by deleting the
  corrupt `icons8-jester.svg` entry. The remaining July `Y:` root entries were
  `.Spotlight-V100`, `.fseventsd`, `New folder`, and the existing movie file.
  Broad public claims still need larger-media read coverage beyond this one USB.
