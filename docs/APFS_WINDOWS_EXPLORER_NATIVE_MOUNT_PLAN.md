# APFS Native Windows Explorer Mount Plan

## Goal

Build a new Windows APFS mount project that reuses the source APFS reader,
writer, raw I/O, certification scripts, and evidence where practical, then exposes
APFS partitions in Windows Explorer as normal mounted volumes with read, write,
rename, delete, directory create/delete, and metadata-aware behavior.

The finished product must install like a normal Windows filesystem utility and run
with Windows until explicitly uninstalled. After install, APFS partition discovery,
mount policy, and saved mount mappings should survive reboot without the user
manually starting the app.

This is a new project, not a source-project UI feature. The source checkout
provides the APFS filesystem engine and proof harness; this project owns Windows mount plumbing,
partition discovery, Explorer behavior, installer/service lifecycle, and mount
certification.

Hard source boundary: do not modify `C:\Users\Randy\Coding\S.A.K.-Utility` for
this project. Treat the source checkout as read-only until specific files are copied,
vendored, subtree-imported, or submodule-pinned into this repository. After import,
only edit the local copy in `apfs_for_windows`.

## Current APFS Assets To Reuse

Use these directly first:

- APFS reader:
  `C:\Users\Randy\Coding\S.A.K.-Utility\include\sak\partition_apfs_file_system_reader.h`
  and `src\core\partition_apfs_file_system_reader.cpp`
  expose directory listing, file read, xattrs, FileVault credential unlock, and
  directory export.
- APFS writer:
  `include\sak\partition_apfs_writer.h` and
  `src\core\partition_apfs_writer.cpp` expose raw in-place COW commits for file
  write/insert/delete/rename/move/patch, directory create/delete/child write/delete,
  clone, hard link, snapshot create/delete/revert, repair, format, and resize.
- Raw Windows block I/O:
  `include\sak\partition_raw_device_io.h` and
  `src\core\partition_raw_device_io.cpp` already handle Windows raw paths,
  read/write alignment, sparse files, and `\\?\GLOBALROOT\Device\HarddiskN\PartitionM`.
- CLI and integration bridge:
  `src\tools\sak_apfs_writer_cli.cpp` is useful as a reference API contract and
  smoke-test executable, but the mount service should call the C++ engine directly
  after M1.
- Tests and certification:
  `scripts\test_sak_apfs_writer_cli.ps1`,
  `scripts\run_file_management_live_filesystem_certification.ps1`,
  `tests\certification\file_management_live_certifier.cpp`,
  `tests\unit\test_partition_manager_core.cpp`, and APFS evidence under
  `artifacts\partition-manager-certification\vm-lab\external-evidence\external.apfs-*`.

## Scan Findings

- Source docs claim APFS A1-A8 full-driver certification, with Apple
  `fsck_apfs`, macOS-kernel mount, physical USB destructive proof, crash proof,
  snapshots, multi-volume, compression, credential-gated encryption, clone,
  hard-link, sparse, xattr/ACL, and resize coverage.
- The source app intentionally does not install a Windows filesystem driver or mount APFS
  as a Windows volume. `docs\APFS_HFS_FULL_DRIVER_WRITE_PLAN.md` says this scope is
  userspace raw-block access against dismounted volumes and parks WinFsp/Dokany as
  optional future convenience.
- Current File Management bridge has a useful API shape, but it is not enough for
  Windows Explorer yet. It caps APFS File Management mutations to root files or one
  root-directory child. Native Explorer needs arbitrary path depth, open handles,
  directory cursors, flush/cleanup semantics, rename by handle, oplock/cache policy,
  security descriptors, timestamps, attributes, and error mapping.
- Current source checkout has dirty, uncommitted changes in File Management,
  File Explorer, raw I/O, and related files. Treat those as live user work; fork
  from a deliberate commit after user chooses a baseline.
- Current source/docs disagree on APFS generated-container ceiling: source/tests
  use 24 TiB in `kMaximumApfsGeneratedContainerBytes`; several docs say 32 TiB.
  Resolve this before any public mount claim.

## Fork Target Choice

Use WinFsp first.

Why:

- It exposes user-mode filesystems as Windows drive letters/mount points visible
  to Explorer.
- It avoids writing a new kernel filesystem driver before the APFS engine has a
  stable mount-facing API.
- APFS core already uses C++/Qt types; a user-mode WinFsp service can keep
  Qt Core initially and wrap callbacks around the existing reader/writer.
- Failure isolation is better for early destructive APFS work: process crash is
  recoverable; kernel crash risk is lower.

Dokan stays fallback if WinFsp blocks on licensing, installer, or callback model.
Do not fork WinBtrfs-style kernel driver for v1; keep that as a later performance
or deep-shell-integration track after user-mode semantics are certified.

Ownership note: copied APFS source is Randy-authored project code imported into
this repo, not third-party code with a separate outside owner. This repo can
carry it under the APFS for Windows project license without the previous
source-app branding/licensing notice. Third-party notices still apply to Qt,
WinFsp, and Apple LZFSE.

## Architecture

```text
Windows startup
        |
        v
apfs_mount_service.exe (Windows Service, Automatic)
  - starts with Windows
  - monitors disk arrival/removal
  - restores saved APFS mount mappings
  - keeps workers alive until unmount/uninstall
        |
        v
Windows disk/volume scan
        |
        v
apfs_mount_manager.exe
  - tray/settings UI for user control
  - talks to the service over local IPC
  - configures auto-mount, drive letters, credentials, read-only/RW policy
        |
        v
service worker supervisor
  - locks/dismounts target where needed
  - launches/restarts one mount worker per APFS volume
        |
        v
apfs_winfs_worker.exe --target \\?\GLOBALROOT\Device\HarddiskN\PartitionM --mount X:
  - WinFsp filesystem callbacks
  - path normalization and inode/object-id cache
  - APFS read/write transaction queue
  - credential broker for FileVault volumes
        |
        v
sak_apfs_core library
  - reader/writer/raw I/O/crypto/keybag/compression
        |
        v
raw APFS partition
```

## Milestones

### M0 - Repo Bootstrap

- Fork/seed `C:\Users\Randy\Coding\apfs_for_windows`.
- Add CMake project with `apfs_core`, `apfs_winfs_worker`, `apfs_mount_manager`,
  `apfs_mount_service`, installer scripts, and tests.
- Vendor/import APFS source as a subtree or submodule from a pinned commit.
- Do not patch the source checkout during extraction. Needed APFS core
  changes happen only after the code exists in this repo.
- Keep Qt Core initially to avoid a rewrite of `QString`, `QByteArray`, `QVector`,
  and `QIODevice` APIs.
- Document license, source provenance, and imported source commit.

Exit gate: builds a no-op worker and unit tests run.

### M1 - Read-Only Explorer Mount

- Implement WinFsp callbacks for volume info, root open, directory list, file info,
  file read, cleanup, and close.
- Map APFS entries to Windows attributes:
  directories, regular files, symlinks as reparse-point blockers for v1, timestamps
  where APFS reader exposes them, sizes, file indexes from APFS object IDs.
- Implement path cache with object ID and parent-child validation.
- Mount one selected APFS partition to a drive letter.
- Keep writes disabled with exact `STATUS_MEDIA_WRITE_PROTECTED`/access-denied
  mapping.

Exit gate: Explorer can browse and copy out files from an APFS test partition;
PowerShell `Get-ChildItem` and `Get-FileHash` match APFS reader output.

### M2 - Write Transaction API

- Build a mount-facing `ApfsTransactionService` over `PartitionApfsWriter`.
- Replace one-shot File Management wrappers with arbitrary path-depth operations.
- Serialize metadata mutations per volume; allow concurrent reads with generation
  invalidation after commit.
- Map Windows operations to APFS COW commits:
  create file, overwrite file, write ranges, truncate, create directory, delete
  empty directory, delete file, rename, move, clone/hard-link later.
- Add rollback/rescan after failed commit.

Exit gate: unit tests mutate APFS images through the mount API and validate through
APFS reader plus `sak_apfs_writer_cli` parity.

### M3 - Write-Enabled Explorer Mount

- Enable `Create`, `Write`, `SetFileSize`, `Rename`, `CanDelete`, `Unlink`,
  `SetBasicInfo`, `Flush`, and cleanup behavior.
- Implement temp-write coalescing: Explorer often writes temp files, renames, then
  deletes. Buffer write ranges until close or explicit flush, then perform one APFS
  COW commit where possible.
- Return honest Windows errors for unsupported APFS states:
  Fusion/Tier2, missing FileVault credential, sealed-system volume without explicit
  override, unsupported compression/resource-fork paths, unsupported symlink target
  mutation, too-large or out-of-certified-range generated layouts.
- Add safe volume lock policy: never mount read-write while Windows or another
  worker holds conflicting raw access.

Exit gate: Explorer can create, edit, rename, move, and delete files/folders on
disposable APFS media; post-mount Apple `fsck_apfs` and macOS mount pass.

### M4 - Install, Startup, And Persistent Mounts

- Add installer that installs the mount service, manager UI, worker executable,
  APFS core DLL/static payload, WinFsp prerequisite check/install flow, Start Menu
  entries, logs directory, and uninstaller.
- Register `apfs_mount_service.exe` as a Windows Service with Automatic start.
- Store mount policy in ProgramData:
  APFS partition identity, preferred drive letter or mount folder, read-only/RW
  default, credential-needed state, last successful mount evidence, and user opt-out.
- On boot and disk arrival, service scans APFS partitions and remounts saved
  mappings automatically.
- If a credential-gated FileVault volume is present, service mounts read-only
  locked/blocker state until the user unlocks through the manager UI. Do not store
  raw secrets by default.
- On uninstall, stop service, unmount all APFS volumes, remove service, remove
  shell/tray startup entries, and leave user data/log deletion as an explicit
  installer choice.

Exit gate: install -> reboot -> APFS volume remounts in Explorer without manually
launching the app; uninstall removes service and mount points cleanly.

### M5 - Partition Discovery And Native UX

- Detect APFS whole devices plus GPT/MBR partitions automatically by APFS
  signatures; use GPT GUID `{7C3457EF-0000-11AA-AA11-00306543ECAC}` as useful
  metadata, not the sole admission rule.
- Add tray/manager UI:
  mount/unmount, drive-letter selection, read-only/read-write mode, evidence link,
  credential prompt, safety status, and logs.
- UI must be keyboard accessible, screen-reader labeled, high-DPI aware, and
  responsive at narrow widths.
- Add installer path for WinFsp prerequisite detection and clear blocker text when
  missing.

Exit gate: non-technical user can mount/unmount APFS from UI without command line.

### M6 - Certification

- Port APFS evidence lanes into this repo:
  image unit tests, CLI parity, live raw USB tests, Apple `fsck_apfs`, macOS kernel
  mount/read/write, crash/rollback.
- Add Windows Explorer-specific tests:
  Explorer create/edit/delete/rename, PowerShell copy, Robocopy smoke, long paths,
  Unicode names, hidden/system attributes, concurrent reads, large files, forced
  worker crash, surprise unplug.
- Create disposable-media scripts only; never run destructive tests without explicit
  disk serial and confirmation.

Exit gate: release checklist passes with artifacts under this repo.

## Current Milestone Status

- M0 complete: independent repo, copied core, build, tests, provenance, license,
  installer, and release packaging exist here. Source checkout remains read-only.
- M1 complete for current tested media: Explorer/PowerShell listing, reads, hashes,
  read-only denial, raw image, and physical APFS partition mounts pass.
- M2 complete for current file/directory transaction surface: arbitrary nested
  create/write/rename/move/delete, generation refresh, and rollback/crash lanes pass.
- M3 file-content, namespace, file/named-directory/volume-root basic-info and
  POSIX security metadata, symbolic-link, and supported
  regular-file/named-directory/volume-root EA exit gates pass on disposable
  image, physical USB where non-destructive, and native macOS round-trip media.
  Hard-link creation, zero-length EA values, non-ASCII-name EAs, and large
  stream-backed xattr mutation remain outside the current Windows callback surface.
- M4 exit gate passes in a clean Windows 11 VM. Package install, Automatic service,
  saved mount restoration across a reboot, Start Menu, Apps & Features, one
  interactive tray process, installed hashes, and complete uninstall cleanup pass.
  Actual host post-reboot proof remains prohibited by user instruction.
- M5 discovery/manager/tray implementation passes current automated lanes. Real
  physical surprise-unplug behavior remains unproven.
- M6 passes local CTest, crash recovery, installed service, current 30 GB USB,
  Unicode/long-path/Robocopy/concurrent-read, a 100-iteration Robocopy soak, and
  native Apple round-trip lanes.
  Remaining certification work is listed under Blockers.

## Must-Fix Before Public RW Claim

- Resolve any remaining large-container cap mismatch in source/docs and import one
  truth into this project.
- Keep the worker on the arbitrary-path transaction layer instead of the old
  root/one-child helper APIs.
- Decide policy for arbitrary Apple-written APFS media. Current source-app UI exposure
  still fails closed for arbitrary non-generated writes even though `import-image`
  exists for readable snapshot-free images.
- Define FileVault credential lifetime, recovery-key path, and no-secret-in-logs
  rules for long-running mount workers.
- Define sealed-system-volume write policy. Default should be read-only.
- Confirm WinFsp license/distribution compatibility with the desired installer
  model.

## First Concrete Build Slice

1. Pin source commit after current user changes are intentionally committed or
   set aside.
2. Create `apfs_core` by importing:
   `apfs_crypto`, `apfs_keybag`, `apfs_compression`,
   `partition_apfs_file_system_reader`, `partition_apfs_writer`,
   `partition_raw_device_io`, and minimal detector/types dependencies.
3. Add `apfs_winfs_worker` with read-only WinFsp callbacks and a fake in-memory
   APFS fixture first.
4. Switch worker backend from fake fixture to APFS reader on an APFS image.
5. Mount a disposable APFS image read-only as `X:` and prove Explorer/PowerShell
   copy-out.
6. Add `apfs_mount_service` automatic startup and persist one read-only mount
   mapping across reboot.
7. Only then enable raw partition target and write path.

## Implementation Progress

- Repo initialized locally.
- APFS core copied into `third_party/sak_apfs_core` from source commit
  `2f1d9844fabb3e6e8190f906e5cf4906e5e5f281`; source checkout remains
  unmodified and off-limits.
- CMake project builds `sak_apfs_core`, `apfs_probe`, `apfs_mount_service`,
  `apfs_winfs_worker`, `apfs_mount_manager`, and `apfs_core_selftest`.
- `apfs_probe` is a read-only APFS/GPT probe that uses copied APFS detector,
  reader, and raw-device I/O. It can scan GPT entries and list APFS root entries
  when raw access is available. It now also supports `--read-file` with SHA-256
  output for APFS path reads.
- WinFsp 2025 `2.1.25156` was installed locally and CMake links the real SDK.
- `scripts\verify-winfsp-prerequisite.ps1` verifies the installed WinFsp
  prerequisite without admin: registry registration/version, SDK header/import
  library, runtime DLL/driver, and built worker `--status` reporting WinFsp
  enabled.
- `apfs_winfs_worker` now implements a WinFsp APFS mount over the copied
  APFS reader/writer. Read-only remains default. Read/write requires
  `--read-write`; physical raw writes also require `--allow-raw-writes`.
- `apfs_mount_service` has real Windows service install/uninstall commands,
  registers as Automatic startup, reads persisted mappings from
  `C:\ProgramData\APFS for Windows\mounts.json`, supervises worker processes,
  restarts failed mount workers, and auto-discovers APFS physical disks/partitions
  at service start. While running, it periodically resyncs config and device
  discovery, starts newly configured/discovered workers, and stops workers whose
  mappings were removed. It now hosts a local service control IPC endpoint so
  installed CLI/manager requests can ask the running service to update safe mount
  policy, avoiding direct non-admin writes to ProgramData.
- `apfs_mount_service --health` now reports installed service state/start type,
  service recovery policy, configured mount mappings, mount availability, and
  visible root entries as JSON.
- `apfs_mount_service --discover-apfs` scans `\\.\PhysicalDriveN` targets
  read-only with the copied APFS detector/reader, reports whole-device plus
  GPT/MBR partition APFS candidates, and `--configure-discovered` persists missing read-only mount
  mappings.
- `apfs_mount_manager` is no longer a scaffold. It is a Qt Widgets manager UI
  with an accessible/responsive mount table,
  refresh/discover/open/change-letter/read-write-mode/enable-disable/unmount/copy
  actions, raw service-health JSON, and `--status`/`--self-test` verification
  modes.
- Developer install/uninstall scripts exist under `scripts/`.
  The installer now deploys `Qt6Core.dll`, `Qt6Gui.dll`, `Qt6Network.dll`,
  `Qt6Widgets.dll`, and `platforms\qwindows.dll` next to the installed binaries
  so the manager and service IPC support launch from
  `C:\Program Files\APFS for Windows`.
- Install/repair now deploy the installed uninstall script plus Start Menu
  shortcuts for `APFS Mount Manager` and `Uninstall APFS for Windows`.
  `scripts\verify-start-menu-entries.ps1` verifies those entries without admin.
- Install/repair now register the utility under Windows Apps & Features
  (`HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall\APFS for Windows`)
  with an uninstall command. `scripts\verify-installed-app-registration.ps1`
  verifies this without admin.
- Install/repair register `APFS for Windows Mount Manager` as a machine-wide
  Users-group logon task with unlimited runtime, plus a machine Run-key fallback.
  Each interactive user gets the stacked `AP` over `FS` tray icon at logon.
  Manager uses a local single-instance channel; later launches show the existing
  window instead of creating duplicate tray icons. Uninstall removes both startup
  registrations and waits for the installed manager process to exit.
- `scripts\build-release-package.ps1` creates a non-admin release ZIP under
  `artifacts\package\APFS-for-Windows-0.1.0.zip` with built binaries, Qt runtime
  DLLs, platform plugin, install/repair/uninstall scripts, README, and APFS
  core provenance note. `scripts\verify-release-package.ps1` verifies the staged
  package layout and runs install/repair `-ValidatePayloadOnly` from the staged
  package. Install/repair prefer package-local Qt files before developer Qt.
  The current ZIP SHA-256 is recorded in
  `artifacts\package\package-proof.json` so README changes cannot leave a stale
  self-referential package hash.
- `LICENSE`, `THIRD_PARTY_LICENSES.md`, and
  `scripts\verify-license-notices.ps1` now cover project license presence plus
  Qt, WinFsp, and Apple LZFSE notices required by the release package.
- `apfs_mount_service --uninstall` now stops the service, waits for the service
  stop path to tear down workers/mounts, then deletes the service. The PowerShell
  uninstaller also waits for tray-manager exit, removes both startup mechanisms,
  writes `artifacts\uninstall\uninstall-proof.json`, and can remove installed
  files with `-RemoveFiles`. Missing registry values are handled idempotently.
- `scripts\repair-apfs-for-windows-install.ps1` is the focused elevated recovery
  path for the current machine: it stops the service, reaps lingering installed
  APFS worker processes, redeploys current build binaries, keeps the Windows
  service Automatic/running with restart-on-failure recovery, verifies automatic
  APFS discovery or an optional explicit read-only target/mount pair, verifies
  installed binary hashes, records worker/manager cleanup, and writes
  `artifacts\repair\install-repair-proof.json` without rebooting.
- `scripts\start-repair-elevated.ps1` is the normal-user guarded repair launcher.
  It writes `artifacts\repair\start-repair-elevated-proof.json`, refuses to spawn
  another UAC prompt while `consent.exe` is already pending, and waits for the
  elevated repair proof artifact when launched.
- `scripts\verify-service-recovery-policy.ps1` is the non-admin installed-service
  persistence verifier. It checks Automatic start, at least three SCM restart
  actions, reset period `86400`, and non-crash failure recovery.
- `scripts\verify-apfs-boot-persistence.ps1` verifies the installed service and
  APFS USB mount state, including Automatic start mode, running service, visible
  mount, expected root entries, expected file SHA-256, and write-denied behavior.
  It can also arm an HKCU RunOnce verifier for next logon after reboot via
  `-ArmNextLogon`.
- `scripts\windows-vm\verify-installed-state.ps1` is the reusable VM lifecycle
  verifier. It proves installed binary hashes, saved fixture mount, file hash,
  read-only denial, service mode, registration, startup task, exactly one
  interactive tray process, and manager self-test with bounded child-process I/O.
- `scripts\verify-service-worker-restart.ps1` kills the service-owned
  `apfs_winfs_worker.exe` child, waits for the service supervisor to launch a new
  worker, then verifies the mounted root and expected file SHA-256.
- `scripts\verify-apfs-auto-discovery.ps1` backs up the current mount config,
  starts the service from an empty config, verifies APFS auto-discovery/remount,
  write-deny, and expected SHA-256, then restores the original config.
- `scripts\verify-service-live-sync.ps1` modifies `mounts.json` while the service
  is already running, verifies the service starts a new worker without restart,
  restores the config, and verifies the worker is removed.
- `scripts\verify-service-remove-mount.ps1` uses service CLI add/remove commands
  to prove safe unmount/removal of a temporary APFS image mapping while the
  service keeps running.
- `scripts\verify-service-drive-letter.ps1` uses service CLI add/set/remove
  commands to prove stable drive-letter preference changes while the service keeps
  running.
- `scripts\verify-service-policy.ps1` proves the persistent automount policy bit:
  disabling a mapping keeps it in `mounts.json`, stops its worker, and prevents
  live sync from remounting it until re-enabled.
- `scripts\verify-service-target-loss.ps1` proves availability-aware live sync:
  an unavailable APFS target is skipped, its failed worker/mount is removed while
  config stays saved, and the mount returns after the target returns.
- `scripts\verify-service-device-notifications.ps1` proves the installed service
  registered Windows disk-device notifications so USB disk arrival/removal events
  can trigger APFS resync immediately, with the five-second timer kept as fallback.
- `scripts\verify-current-apfs-state.ps1` is a non-admin preflight that captures
  UAC prompts, service state, installed-vs-build binary hashes, raw-writable
  mounts, stale proof entries, and whether USB normal-user RW proof may run.
- `scripts\verify-local-worker-rw-smoke.ps1` is a non-admin local proof for the
  current build: it generates an APFS image, mounts it through the worker,
  creates one root proof directory, writes/hashes/renames/deletes one direct
  child file, deletes the empty proof directory, unmounts, and probes the image
  afterward.
- `scripts\verify-local-worker-fileops.ps1` is a non-admin local Explorer-style
  proof: it mounts a generated APFS image, uses Robocopy to copy direct child
  files into one APFS root directory, verifies every copied hash, edits a direct
  child file, replaces an existing file through `MoveFileEx` rename, renames a
  file, recursively deletes the proof directory, unmounts, and probes the APFS
  image afterward. The current worker stages same-handle create and overwrite
  writes, committing truncate plus payload together on `Flush`/`Cleanup`.
- `scripts\verify-local-worker-robocopy-stress.ps1` is a non-admin local repeat
  proof: it mounts a generated APFS image at `T:`, runs the same Robocopy
  copy/hash/edit/`MoveFileEx` replace/recursive-delete sequence for 10 proof
  directories, unmounts, and probes the image afterward.
- `scripts\verify-local-worker-large-existing-fileops.ps1` is a non-admin local
  proof for the USB-failure class: it mounts a generated APFS image containing
  existing 16 MiB `large.bin`, creates one root proof directory, writes/renames/
  overwrites/deletes one direct child file, removes the proof directory,
  unmounts, and probes `large.bin` afterward to prove metadata mutations
  preserved existing file extents.
- `scripts\verify-local-worker-crash-recovery.ps1` is a non-admin deterministic
  image crash proof. Test-only worker options force exit code `197` immediately
  before or after atomic `ReplaceFileW` image promotion. Raw probe and read-only
  remount prove the before phase selects old file bytes and the after phase
  selects new bytes. Remount also removes the abandoned PID-owned pre-replace
  scratch image. Fault options reject raw targets and read-only mounts.
- `scripts\verify-service-control-ipc.ps1` is a non-admin proof for the current
  build's service-control path: service-side safe config request handling, local
  socket transport, safe read-only/read-write policy changes, raw-write denial,
  and manager command surface.
- `scripts\verify-sak-source-boundary.ps1` is the source-boundary proof. It
  checks the source checkout is clean, the recorded commit matches, and
  copied APFS files exist under `third_party\sak_apfs_core` without writing to
  upstream.
- `scripts\verify-installed-service-mode-policy.ps1` is the post-repair
  installed-service proof for image mount mode policy. It runs without admin or
  USB mutation, mounts a generated APFS image through the installed service,
  proves read-only write denial, flips the mapping to read/write, writes/deletes
  a file, flips back to read-only, and removes the mapping.
- `scripts\verify-usb-mounted-file-actions.ps1` is the direct mounted-drive USB
  file action proof. It runs without admin, never changes service policy,
  refuses a stale installed worker by default, supports `-PreflightOnly` for a
  zero-mutation readiness check, can remove stale `sak-user-rw-manual-proof-*`
  root proof directories, waits for final mount visibility, records
  initial/final mount policy, reports any stale entries still visible after
  cleanup, labels `-AllowStaleInstalledWorker` runs as
  `current_installed_mount_only`, and proves volume-root EA plus root
  proof-directory create and direct child-file write/hash/rename/overwrite/delete
  inside its own
  `sak-mounted-file-actions-proof-*` directory on the selected mount. Current
  certification wraps this proof in an explicit temporary writable policy
  window and restores that mount read-only afterward.
- `scripts\run-apfs-for-windows-certification.ps1` is the no-reboot certification
  orchestrator. It runs build, CTest, script parse, local RW smoke, local
  Explorer-style fileops, local Robocopy stress, local worker crash recovery,
  service-control IPC proof, installed-service mode preflight, current-state
  preflight, and USB RW preflight. Direct mounted-drive USB file actions only run with explicit
  `-RunUsbMountedFileActions`; full USB mutation proof only runs with explicit
  `-RunUsbWriteProof` after preflight is ready. Current full no-reboot run used
  `-SkipBuild` after the same Release build and CTest suite had passed, then
  completed from `2026-08-16T22:10:16Z` through
  `2026-08-16T22:13:07Z` with `ok=true`,
  `local_code_gates_ok=true`, `installed_persistence_ok=true`,
  `local_worker_metadata_links_ok=true`, `apple_vm_roundtrip_ok=true`,
  `mounted_usb_file_actions_ok=true`, `usb_preflight_ready=true`,
  `full_usb_rw_ok=true`, and `extended_usb_file_actions_ok=true`. It verified
  CTest, script parse, WinFsp,
  copied-core boundary, license/package gates, installed-state preflight,
  direct mounted-drive USB file actions, and serial-pinned USB normal-user RW
  proof through `verify-usb-normal-user-rw.ps1 -NoDiagnostics`. It used Disk 1
  Partition 1 at `V:` and passed all gates.
- `scripts\verify-usb-raw-rw.ps1` pins the 30 GB USB APFS test disk by disk
  number, serial, size, USB bus, partition number, and exact-target APFS
  signature before temporarily enabling
  raw writes, then proves create/write/hash/rename/delete through the selected mount.
- `scripts\verify-usb-normal-user-rw.ps1` now detects pending UAC prompts before
  spawning elevated setup/restore helpers, uses a bounded elevated-helper wait,
  keeps file actions in the non-admin parent process, and supports
  `-PreflightOnly` for a non-mutating, no-elevation readiness check. It also
  supports `-NoDiagnostics`, which keeps the same normal-user mutation path but
  skips large trace/log tails in the final JSON so the verifier cannot stall
  after successful USB operations.
- `apfs_core_selftest` now exercises the copied APFS core against
  temporary images without touching USB media. It formats a seeded APFS image,
  lists and reads it, then performs image-only COW root-file insert, replace,
  rename, delete, root-directory create/delete, direct directory-child
  write/rename, child move to root, nested directory create, and file-backed raw
  directory create/delete while preserving a 16 MiB existing file. Every result
  is verified with `PartitionApfsFileSystemReader`. Root-EA coverage creates,
  reads, preserves, and deletes an embedded xattr on APFS inode 2.
- `apfs_core_selftest` now also builds deterministic interrupted checkpoint
  images from actual pre-commit and committed bytes. The current insert changes
  18 blocks. Omitting checkpoint-map publication selects the old generation;
  omitting the checkpoint superblock still selects old; publishing that
  superblock selects new even before the block-zero mirror. All phases preserve
  the seed-file SHA-256 and report `old_or_new_only=true`.
- `apfs_winfs_worker --read-write` has a guarded mount-facing mutation path for
  APFS image and raw targets. WinFsp file and directory create, overwrite,
  write, truncate/resize, rename/move, and delete route arbitrary parent paths
  into copied APFS COW commits, then rebuild the mounted reader session after
  each commit.
- `apfs_winfs_worker` directory enumeration now sorts entries by name and resumes
  after a marker lexically even if the exact marker entry was already deleted.
  This fixes recursive delete clients that enumerate a directory while deleting
  children and then ask for entries after a stale marker.
- WinFsp handle lifetime now uses a mount-state-owned handle table. Open/Create
  callbacks allocate owned `FileContext` entries, Close moves them to a deferred
  quarantine and prunes old retired handles, preventing double-close/UAF risk and
  the previous unbounded raw allocation leak.
- Raw-device writes remain off by default. A raw target can only enter RW mode
  with both `--read-write` and `--allow-raw-writes`; the installed Disk 2 mapping
  does not set those flags.
- The copied APFS writer preserves existing directory trees during metadata
  commits by carrying directory parent ids through fs-tree rebuilds. The
  imported mutation API exposes arbitrary parent paths for file and directory
  operations used by the worker.
- The copied APFS writer now wraps the next contiguous checkpoint ephemeral set
  to checkpoint data-ring slot 0 when the live data tail is too close to the end.
  The stronger local Robocopy/delete proof hit the old
  `checkpoint data ring would wrap` failure while deleting `root.txt`; after this
  copied-core fix, the same proof deletes the whole tree and leaves only
  `large.bin` and `seed.txt` at root.
- The worker resolves file and directory parent paths and passes them into the
  imported writer for nested create/write/rename/move/delete operations.
- The copied APFS writer now preserves existing files during metadata-only
  commits by logical size plus recovered extents instead of allocating a
  `QByteArray` as large as each existing file. This addresses the worker crash
  seen when the 30 GB USB contained a large movie file and Explorer attempted to
  delete a stale empty root proof directory.
- The service is installed on this machine as `ApfsForWindowsMountService` with
  Automatic start. Current install state should be checked with
  `scripts\verify-current-apfs-state.ps1` before any USB RW proof; no reboot is
  required for repair or test.
- Service live sync now probes configured APFS targets before starting workers.
  Missing or non-APFS targets are logged, skipped, and removed from the active
  worker set without deleting the saved mount config.
- Service main now registers Windows disk-device notifications for disk interface
  arrival/removal/devnode changes and signals immediate APFS resync, while keeping
  the periodic sync loop as fallback.
- Verified:
  `cmake -S . -B build -G "Visual Studio 17 2022" -A x64 -DCMAKE_PREFIX_PATH=C:\Qt\6.10.3\msvc2022_64`;
  `cmake --build build --config Release --parallel`;
  `ctest --test-dir build -C Release --output-on-failure` passes 12/12;
  PowerShell installer/uninstaller/test-helper AST parse; service/worker/manager
  console smoke.
- Current source keeps generated-image RW enabled and now allows physical raw
  media mutations to reach the imported recertified APFS writer only when the
  mount is explicitly read/write and started with `--allow-raw-writes`.
- `apfs_service_control_self_test` verifies service-side control requests against
  a temporary ProgramData root: safe add-mount succeeds through service logic,
  set-enabled/remove works, image-safe read/write policy flips work, and raw
  physical read/write policy changes are denied from the IPC path so physical raw
  write enablement remains elevated/direct only.
- `apfs_service_ipc_self_test` verifies the actual local socket transport by
  starting a temporary control server, sending a safe add-mount request through
  the same client path used by CLI fallback, and proving the mount config was
  persisted under a temporary ProgramData root.
- `artifacts\service-control\service-control-ipc-proof.json` was generated by
  `scripts\verify-service-control-ipc.ps1`; it proves the control handler,
  socket transport, raw-write denial, and manager UI command surface in one
  non-admin/no-USB-mutation artifact.
- `scripts\verify-installed-service-mode-policy.ps1 -PreflightOnly` currently
  passes after repair: installed binaries match the build, service is running,
  and generated-image service policy proof can run from a non-admin shell.
- `scripts\start-repair-elevated.ps1` remains the preferred no-reboot repair
  entrypoint from a normal shell. The latest repair completed; no UAC prompt is
  pending, service is Automatic/running, manager tray is running single-instance,
  and current `V:` was restored read-only.
- `scripts\verify-usb-mounted-file-actions.ps1 -CleanupStaleProofEntries` is the
  no-admin file action path for the selected mounted USB volume (`V:` in the
  current media layout). It is
  intentionally separate from service policy repair, because normal file
  create/write/delete through a mounted drive should not need elevation. The
  latest orchestrated run temporarily enabled writable policy outside this
  verifier, proved root/file/named-directory EA create/read/update/delete plus
  write/hash/rename/overwrite/delete through the mounted drive, then restored
  `V:` read-only.
- `scripts\run-apfs-for-windows-certification.ps1` currently writes
  `artifacts\certification\apfs-for-windows-certification.json` with
  `local_code_gates_ok=true`, `release_package_ok=true`,
  `local_worker_crash_recovery_ok=true`,
  `installed_persistence_ok=true`, `mounted_usb_file_actions_ok=true`,
  `usb_preflight_ready=true`, and `full_usb_rw_ok=true` from the current
  `-RunUsbWriteProof -RunUsbMountedFileActions` run. The orchestrated direct
  mounted-file lane, serial-pinned USB RW lane, and deterministic image worker
  crash lane now pass. Broader public-claim lanes still need physical raw-media
  power-loss recovery, Apple/macOS validation, surprise-unplug, and wider
  metadata coverage.
- Current self-test proof is saved at
  `artifacts\core-selftest\apfs-core-selftest-large-raw-run.log`. It records
  successful XID
  advances for file insert (`2 -> 3`), replace (`4 -> 5`), rename (`5 -> 6`),
  delete (`6 -> 7`), directory create (`7 -> 8`), directory-child write
  (`8 -> 9`), directory-child rename (`9 -> 10`), child move to root
  (`10 -> 11`), directory delete (`11 -> 12`), nested directory create, and
  file-backed raw directory create/delete plus SHA-256 readback for each expected
  file payload.
- Mounted image RW smoke proof is saved under `artifacts\rw-mount\`:
  `rw-fixture-create.json` creates a persistent APFS test image from copied
  writer code; `rw-mounted-y-smoke.json` mounts that image at `Y:` read-write and
  proves create/read/rename/replace/delete through the WinFsp drive; and
  `rw-fixture-after-mount-probe.json` proves the final APFS image remains
  readable after unmount with the expected root directory state.
- Directory RW smoke proof is also saved under `artifacts\rw-mount\`:
  `rw-mounted-y-directory-smoke.json` mounts `rw-dir-fixture.apfs` at `Y:`,
  creates `ProofFolder`, writes `ProofFolder\child.txt`, renames it, moves it to
  `\moved-root.txt`, deletes the empty directory, and verifies the moved payload
  via normal PowerShell file I/O. `rw-dir-fixture-after-mount-probe.json` and
  `rw-dir-fixture-read-moved-root.json` prove the image remains APFS-readable
  after unmount and `/moved-root.txt` has SHA-256
  `ff3b6c481b2ae553b71a8ba309b56da6833050c9ed01ac989e56dafdbe30c34d`.
- Fresh worker local mount proof from `scripts\verify-local-worker-rw-smoke.ps1`
  is saved at
  `artifacts\local-mount-smoke\worker-rw-smoke-proof.json`. It generated a temp
  APFS image, mounted it read-write at `W:` without admin, created `SmokeDir`,
  wrote/hashed/renamed/deleted one direct child file, deleted the empty
  directory, stopped the worker, and proved the image still probes cleanly.
- Explorer-style local file-operation proof from
  `scripts\verify-local-worker-fileops.ps1` is saved at
  `artifacts\local-fileops\worker-fileops-proof.json`. It generated a temp APFS
  image, mounted it read-write at `V:` without admin, Robocopied direct child
  files into one APFS root directory, verified all hashes, edited a child file,
  replaced an existing file through `MoveFileEx` rename, renamed a file, deleted
  the proof directory recursively, stopped the worker, and proved the image still
  probes with only `large.bin` and `seed.txt` at root.
- Repeat Robocopy stress proof from
  `scripts\verify-local-worker-robocopy-stress.ps1` is saved at
  `artifacts\local-robocopy-stress\worker-robocopy-stress-proof.json`. It
  mounted a generated APFS image read-write at `T:` without admin, ran 10
  Explorer-style proof directories through direct-child Robocopy copy, all-file
  hash verification, child edit, `MoveFileEx` replace-existing rename, and
  recursive delete, then proved the image still probes with only `large.bin` and
  `seed.txt` at root.
- Large-existing-file local proof from
  `scripts\verify-local-worker-large-existing-fileops.ps1` is saved at
  `artifacts\local-large-fileops\worker-large-existing-fileops-proof.json`. It
  generated an APFS image containing existing 16 MiB `large.bin`, mounted it
  read-write at `U:` without admin, created one root proof directory,
  wrote/renamed/overwrote/deleted one direct child file, removed the proof
  directory, stopped the worker, and proved `large.bin` still reads back with
  SHA-256 `35D355B6F8D7D459B5FC1E66B6C459238F330BCFAE7B291583DA5C528BE0ED5D`.
- Handle lifetime stress proof is saved at
  `artifacts\handle-lifetime\handle-lifetime-stress.json`. It mounts a generated
  APFS image at `Y:`, runs 250 repeated directory/read/hash iterations, observes
  4,011 opens and 4,010 closes in the worker trace, and verifies the worker did
  not exit during the test.
- Elevated installer upgrade proof is saved at
  `artifacts\install-upgrade\install-upgrade.log`. The installed service was
  stopped, current binaries were copied to `C:\Program Files\APFS for Windows`,
  the service stayed Automatic, and it restarted successfully.
- Worker supervision proof is saved at
  `artifacts\service-supervision\worker-restart-proof.json`. It killed worker PID
  `37240`, observed replacement worker PID `139028` under service PID `119520`,
  and verified `Z:` returned with `clone.bin`, `link.bin`, `src.bin`, plus
  matching `src.bin` SHA-256
  `5DE304A213068C0F526D99253D0D4A18A4652E95D010A0E96D43CB5ED758A32B`.
- Auto-discovery proof is saved at
  `artifacts\auto-discovery\service-auto-discovery-proof.json`. It stopped the
  APFS service, emptied `mounts.json`, started the service, proved discovery of
  both GPT APFS `\\?\GLOBALROOT\Device\Harddisk1\Partition2` and whole-device
  APFS `\\.\PhysicalDrive2`, mounted them read-only at free drive letters, read
  `src.bin` with SHA-256
  `5DE304A213068C0F526D99253D0D4A18A4652E95D010A0E96D43CB5ED758A32B`, denied a
  write probe, restored the original config, and did not reboot the PC.
- Live config/device sync proof is saved at
  `artifacts\live-sync\service-live-sync-proof.json`. It added a temporary
  read-only APFS image mapping for
  `artifacts\rw-mount\rw-dir-fixture.apfs` at `X:` while service PID `115752`
  was already running, observed worker PID `91164`, read `moved-root.txt` with
  SHA-256 `ff3b6c481b2ae553b71a8ba309b56da6833050c9ed01ac989e56dafdbe30c34d`,
  restored the original config, verified `X:`/worker removal, and proved the
  service PID did not change.
- Remove-mount proof is saved at
  `artifacts\remove-mount\service-remove-mount-proof.json`. It used
  `apfs_mount_service --add-mount` to add the APFS image at `X:`, observed worker
  PID `123984`, verified `moved-root.txt` SHA-256
  `ff3b6c481b2ae553b71a8ba309b56da6833050c9ed01ac989e56dafdbe30c34d`, used
  `apfs_mount_service --remove-mount --target ...`, verified `X:` and the worker
  disappeared, restored original config, and proved service PID `51940` stayed
  unchanged.
- Drive-letter preference proof is saved at
  `artifacts\drive-letter\service-drive-letter-proof.json`. It used
  `apfs_mount_service --add-mount` to add the APFS image at `X:`, verified
  `moved-root.txt`, used `apfs_mount_service --set-mount --target ... --mount W:`,
  observed remount at `W:` with SHA-256
  `ff3b6c481b2ae553b71a8ba309b56da6833050c9ed01ac989e56dafdbe30c34d`, verified
  `X:` disappeared, removed the mapping, restored config, and proved service PID
  `87860` stayed unchanged.
- Automount policy proof is saved at
  `artifacts\policy\service-policy-proof.json`. It used
  `apfs_mount_service --set-enabled --target ... --enabled false`, verified the
  mapping stayed in config with `enabled=false`, verified worker removal, used
  `--enabled true`, verified remount and SHA-256, removed the test mapping,
  restored config, and proved service PID `65528` stayed unchanged.
- Target-loss cleanup proof is saved at
  `artifacts\target-loss\service-target-loss-proof.json`. It mounted a temporary
  APFS image at `X:`, verified `moved-root.txt` SHA-256
  `ff3b6c481b2ae553b71a8ba309b56da6833050c9ed01ac989e56dafdbe30c34d`, killed
  the worker, moved the target aside, observed the mount and worker disappear,
  held the target missing for 8 seconds with no worker/mount recreation, verified
  the config entry stayed saved, restored the target, observed remount, removed
  the test mapping, and proved service PID `54192` stayed unchanged.
- Device-notification registration proof is saved at
  `artifacts\device-notifications\service-device-notifications-proof.json`. It
  proves service PID `54192` registered disk device notifications at
  `2026-06-30T06:20:36.8810000Z`, had zero registration failures after service
  start, stayed Automatic/running, and kept `Z:` plus `Y:` mounted read-only.
- Installed manager proof is saved at
  `artifacts\manager\installed-manager-status.json` and
  `artifacts\manager\installed-manager-self-test.json`. The installed
  `apfs_mount_manager.exe` loads the deployed Qt Widgets runtime, reads service
  health from `C:\Program Files\APFS for Windows\apfs_mount_service.exe`, sees two
  mount rows, exposes an accessible table named `APFS mount table`, and exposes
  refresh/discover/open/change-letter/enable-disable/unmount/copy controls.
- Elevated raw-device probe against Disk 2 succeeded without bringing the disk
  online:
  `\\.\PhysicalDrive2` detected as APFS whole-device container `SAKA7RAW`,
  total bytes `100663296`, free bytes `66318336`, files `clone.bin`, `link.bin`,
  `src.bin`.
- Elevated raw-device `apfs_probe --read-file` proved all three files read
  correctly with SHA-256
  `5DE304A213068C0F526D99253D0D4A18A4652E95D010A0E96D43CB5ED758A32B`.
- Elevated direct worker mount proved read-only WinFsp callbacks. Service-launched
  worker then proved normal shell/Explorer namespace visibility:
  `cmd /c dir Z:\` lists `clone.bin`, `link.bin`, `src.bin`; normal `Get-FileHash`
  and `Get-Content` read all three files; write attempt to
  `Z:\normal-write-deny-test.txt` returns access denied.
- After the directory-RW image worker upgrade, the installed `Z:` USB mapping still
  mounts read-only and `Z:\normal-write-deny-after-dir-upgrade.txt` returns access
  denied.
- After the handle-table worker upgrade, `service-mounted-z-handle-stress.json`
  proves 200 repeated normal-user `Z:\src.bin` reads with stable SHA-256
  `5DE304A213068C0F526D99253D0D4A18A4652E95D010A0E96D43CB5ED758A32B` and the
  service still running.
- Earlier persistence health proof is saved at
  `artifacts\boot-persistence\service-health-installed.json` and
  `artifacts\boot-persistence\current-persistence-verification.json`. These were
  captured before the normal-user RW diagnostic and prove the installed service
  reports `start_type=automatic`, `status=running`, maps
  `\\.\PhysicalDrive2` to `Z:` read-only, maps
  `\\?\GLOBALROOT\Device\Harddisk1\Partition2` to `Y:` read-only, sees
  `clone.bin`, `link.bin`, and `src.bin`, verifies `src.bin` SHA-256
  `5DE304A213068C0F526D99253D0D4A18A4652E95D010A0E96D43CB5ED758A32B`, and denies
  a write probe. Current post-repair state separately confirms `Y:` is read-only
  with raw writes disabled.
- Current no-reboot `Y:` persistence proof is saved at
  `artifacts\boot-persistence\apfs-persistence-y-verification.json`. It uses
  `scripts\verify-apfs-boot-persistence.ps1 -VerifyNow -Mount Y: -ReadProbeOnly`
  against the existing movie file, proves service Automatic/running, root entries
  visible, 4096 bytes readable from
  `Predator Badlands 2025 1080p WEB-DL HEVC x265 5.1 BONE.mkv`, and read-only
  write denial on `Y:`.
- Earlier USB raw RW proof is saved at
  `artifacts\usb-rw\usb-raw-rw-proof.json`. Current USB verifiers pin Disk 1
  `USB DISK 3.0` serial `067D19C65080`, APFS GPT partition 2, target
  `\\?\GLOBALROOT\Device\Harddisk1\Partition2`, temporarily remount `Y:` with
  `--read-write --allow-raw-writes`, mutate one root proof directory plus one
  direct child file, restore read-only config, avoid service restart, and do not
  reboot.
- Serial-pinned normal-user USB RW proof is current. On
  `2026-07-10T06:51:00Z`, `scripts\verify-usb-normal-user-rw.ps1 -NoDiagnostics`
  passed against Disk 1 partition 2 at `Y:` as `MINI-DT\Randy` without reboot:
  proof directory create passed, child file write hash matched
  `84430AC23FB71E125BF33F1D9A1DE3E30676F8EE776CB4B790BCDCD4905F2FC1`, rename
  passed, file delete passed, directory delete passed, service PID stayed
  `128168`, and `Y:` was restored read-only with raw writes disabled. Artifact:
  `artifacts\usb-rw\usb-normal-user-rw-proof.json`.
- Current-state preflight proof is saved at
  `artifacts\state\current-apfs-state.json`. It reports
  `ready_for_usb_normal_user_rw_test=true`: no UAC prompt is pending, installed
  binaries match the current build, stale proof entries are gone, service is
  Automatic/running, and `V:` is currently restored read-only with
  `allow_raw_writes=false`.
- Non-mutating USB file-action preflight is saved at
  `artifacts\usb-rw\usb-normal-user-rw-preflight.json`. It exits quickly with
  no elevation and no USB writes, reports readiness blockers, and leaves `V:`
  unchanged.

## Blockers

- Source checkout remains off-limits for edits; APFS core changes for this
  project are made only in the copied tree under `third_party\sak_apfs_core`.
- Serial/signature-pinned physical USB RW passes as normal user on the current
  hybrid MBR Partition 1 APFS target at `V:`. Real APFS timestamp/BSD-flag/POSIX
  security metadata writes, read-only enforcement, Windows symbolic-link
  creation/follow/delete, supported regular-file/named-directory/volume-root EA
  create/read/update/delete, and reversible volume-root basic-info now pass on
  that raw target. Physical root security was intentionally not changed; its
  implementation is covered by local remount and native macOS lanes. Remaining
  work before public RW default: hard-link creation; zero-length, non-ASCII-name,
  and large stream-backed xattr mutation;
  physical raw-media crash/power-loss recovery proof; and real surprise-unplug
  behavior. Apple-created xattr/symlink/hardlink preservation and supported EA
  mutation pass a native macOS round trip. Deterministic image worker crash
  recovery also passes.
  `\\.\PhysicalDrive2` remains read-only.
- Current local state is safe to pause: no UAC prompt is pending, no USB verifier
  process remains, service is Automatic/running, installed binaries match the
  current build, one tray manager is running, and `V:` is read-only with raw
  writes disabled.
- Normal Explorer-style file actions remain a non-admin requirement, but service
  policy restore/install is admin-gated on this machine: a non-admin
  `--add-mount ... --read-only` restore attempt failed with
  `Unable to write C:/ProgramData/APFS for Windows/mounts.json`.
- Current build adds service-owned config IPC for safe post-install policy
  changes, and the installed service/worker/probe now match the current build.
- Software PnP disable could not simulate surprise removal because Windows reports
  the pinned USB device is pending a system reboot and does not support that
  command on this OS product. Host restart remains prohibited. The failed attempt
  performed no file mutation, left the service process alive, and restored `V:`
  read-only with raw writes disabled. Real physical unplug/replug and raw-media
  power-loss recovery remain unproven.
- Installed WinFsp 2.1 and the current upstream WinFsp header both mark volume
  and file-info hard-link fields `unimplemented; set to 0`; the protocol exposes
  no create-hard-link transaction to a user-mode filesystem. Existing APFS hard
  links are preserved, and deletion of one name is certified, but Explorer
  hard-link creation needs a WinFsp protocol/kernel fork or a different kernel
  filesystem transport. Upstream header:
  `https://raw.githubusercontent.com/winfsp/winfsp/master/inc/winfsp/fsctl.h`.
- `scripts\repair-apfs-for-windows-install.ps1` now packages that admin recovery
  as one auditable command, reaps lingering installed worker processes before
  copying binaries, and proves the result in
  `artifacts\repair\install-repair-proof.json`.
- Installed binaries match the current build for service, worker, manager, and
  probe. Installed-service image policy proof and normal-user USB RW proof have
  current passing artifacts.
- The handle table is bounded by a deferred-retirement quarantine. Local
  handle-lifetime proof plus 10- and 100-iteration Robocopy stress runs pass with
  matching hashes, edits, replacements, recursive cleanup, and no leaked mount.
- Service-start APFS whole-device/GPT/MBR signature discovery, live config/device resync,
  drive-letter changes, remove-mount, automount enable/disable policy, and
  deterministic target-loss cleanup are proven without reboot. The service now
  registers disk-device notifications for immediate resync, but M5 still needs
  real physical surprise-unplug proof.
- Host PC has not been rebooted because it must not be restarted. A clean Windows
  11 VM now proves Automatic service startup, saved `R:` mount restoration, exact
  file hash, and read-only enforcement across a VM reboot. Host evidence still
  uses current-state/no-reboot lanes only.
- The previous USB read blocker was classified and removed. `apfs_probe
  --debug-file icons8-jester.svg` showed no decmpfs/resource-fork data and an
  impossible extent physical block `1753640960` outside the 30 GB container.
  `artifacts\usb-rw\delete-corrupt-icons8-svg-ready-wait.json` proves the
  corrupt entry was deleted through the mounted `Y:` drive after the live
  writable worker was ready, and `Y:` was restored read-only without reboot.

## 2026-07-09 Current Implementation Update

- Re-imported APFS core from source commit
  `2f1d9844fabb3e6e8190f906e5cf4906e5e5f281` into
  `third_party\sak_apfs_core`; source checkout was not edited.
- Vendored Apple LZFSE/LZVN reference code under `third_party\lzfse` and linked
  it through `sak_lzfse` so the newer compression paths build locally.
- Removed copied source license tags and source-app licensing notices from code
  and docs. Kept third-party notices for Qt, WinFsp, and Apple LZFSE.
- Added local copied-core deltas needed by APFS for Windows: parent-path image
  file write/delete/rename, parent-aware directory delete, and image/raw
  directory rename/move wrappers.
- Updated `apfs_winfs_worker` so file write/delete/rename/move use arbitrary APFS
  parent paths instead of old one-directory child APIs.
- Added file-backed staging for large same-handle raw writes. Explorer-style
  large raw copies now stage to a temp host file and stream through the raw APFS
  writer on flush. Image mounts still use the 64 MiB buffered guard.
- Added persistent Qt tray icon with generated stacked `AP` over `FS` icon,
  right-click `Open` and `Exit`, and `QuitOnLastWindowClosed=false`.
- `apfs_core_selftest` now proves nested image file write/rename/delete, nested
  directory rename/delete, raw nested directory create/rename/delete, raw
  streaming file write, raw file rename/move/delete, and preservation of an
  existing 16 MiB file.
- The physical 30 GB USB APFS mounted-drive proof has since passed against the
  installed build. No reboot was required or performed.

## 2026-07-10 Current Implementation Update

- Patched only copied code under `third_party\sak_apfs_core`; upstream
  `C:\Users\Randy\Coding\S.A.K.-Utility` was not edited.
- Copied APFS writer now detects Apple/foreign non-overflow internal-pool
  layouts where live CIB0 rotation remains near the old low blocks but live
  chunk bitmaps and the IP bitmap live in the reported spaceman IP pool.
- Foreign IP used-set building now releases/marks only blocks inside the real
  IP pool, skips zero/non-pool `chunk1BitmapBlock`, and avoids the generated
  spill planner when the real IP bitmap path is active.
- `scripts\verify-usb-normal-user-rw.ps1` gained `-NoDiagnostics` compact proof
  mode and no longer performs a post-restore stale-root enumeration unless stale
  cleanup failed.
- `scripts\verify-local-worker-rw-smoke.ps1` now auto-selects a free smoke-test
  drive letter when its default is already in use, while still honoring an
  explicit `-Mount` conflict as a hard failure.
- Local file-op, large-existing-file, and installed-service mode-policy
  verifiers now apply the same free-letter fallback. This keeps certification
  valid while real APFS volumes occupy former fixture defaults such as `U:` and
  `V:`; explicit conflicting `-Mount` values still fail.
- `scripts\verify-usb-normal-user-rw.ps1 -PreflightOnly` now treats the safe
  read-only/raw-disabled USB mount as the required baseline before destructive
  proof, instead of requiring the mount to already be writable.
- `scripts\verify-apfs-boot-persistence.ps1` gained `-ReadProbeOnly` and
  `-ReadProbeBytes` so no-reboot persistence checks can prove an existing large
  file is readable without hashing gigabytes through the mounted filesystem.
- `scripts\run-apfs-for-windows-certification.ps1 -RunUsbWriteProof` now uses
  compact USB proof mode and completed full no-reboot certification with
  `ok=true`, `local_code_gates_ok=true`, `installed_persistence_ok=true`,
  `mounted_usb_file_actions_ok=true`, `usb_preflight_ready=true`, and
  `full_usb_rw_ok=true`.
- `apfs_probe --debug-file` now exposes copied-reader inode/xattr/extent
  diagnostics for one APFS path, which was used to classify the stale USB
  `icons8-jester.svg` entry as corrupt metadata rather than a compression or
  resource-fork reader gap.
- Historical note: `SetBasicInfo` and `SetSecurity` originally returned success as
  compatibility no-ops. The current worker supersedes that behavior with real APFS
  metadata commits. `SetSecurity` persists POSIX mode/owner/group; `GetSecurity`
  intentionally returns a permissive mount compatibility ACL so Explorer access
  does not depend on mapping Apple numeric identities to local Windows accounts.
- `scripts\verify-usb-normal-user-rw.ps1` now waits for live mounted root
  ACL/attribute mode to match the requested read-only/read-write policy instead
  of trusting config health before the service has restarted the worker.
- `artifacts\usb-rw\delete-corrupt-icons8-svg-ready-wait.json` proves the
  corrupt USB SVG entry was removed through the mounted drive and `Y:` returned
  to read-only/raw-disabled state. The active USB root no longer contains that
  stale read blocker.
- Verification run:
  `cmake --build build --config Release --parallel`,
  `ctest --test-dir build -C Release --output-on-failure` (10/10),
  `scripts\start-repair-elevated.ps1` (no reboot, service Automatic/running,
  installed hashes match build), `scripts\verify-usb-normal-user-rw.ps1
  -NoDiagnostics` (normal-user USB RW/delete pass),
  `scripts\verify-current-apfs-state.ps1` (ready=true, `Y:` read-only), and
  `scripts\run-apfs-for-windows-certification.ps1 -RunUsbWriteProof`
  (`ok=true`).

## 2026-08-16 Current Implementation Update

- Current SAK recertification media changed from the earlier GPT Partition 2
  layout to a hybrid Windows MBR Partition 1 view. Disk 1 remains pinned by USB
  bus, non-boot/system status, serial `067D19C65080`, and 31,042,043,904-byte
  physical size; exact target `\\?\GLOBALROOT\Device\Harddisk1\Partition1`
  probes as a 536,870,912-byte APFS `RawSignature` container and mounts at `V:`.
- Service discovery now parses MBR primary partitions in addition to GPT and
  whole-device APFS. `apfs_service_partition_parser` adds synthetic regular and
  zero-offset hybrid MBR coverage; CTest passes 12/12.
- Raw-write policy no longer trusts only a discovery target-name match. Service
  opens and APFS-probes the exact requested raw target before enabling writes,
  which safely supports equivalent whole-device/Partition 1 hybrid aliases.
- USB verifiers retain disk-number/serial/size/bus/non-system pinning and now
  require exact-target APFS signature proof instead of rejecting valid APFS
  solely because Windows labels the hybrid partition `FAT16`.
- Current normal-user physical proof completed `2026-08-16T17:22:33Z` on `V:`:
  create/write/hash/rename/delete all passed, service PID stayed `24356`, proof
  directory was removed, and read-only/raw-disabled policy was restored. No
  reboot occurred. Artifact: `artifacts\usb-rw\usb-normal-user-rw-proof.json`.
- Repair is no longer hardcoded to `Y:/Partition2`; default mode verifies
  automatic discovery, optional `-UsbTarget/-UsbMount` pins one read-only mount,
  and guarded normal-user repair relaunches manager tray after deployment.
- Installer/repair add machine-wide manager `--tray` logon startup. Manager is
  single-instance and retains right-click `Open`/`Exit` with stacked `AP` over
  `FS` icon. Uninstaller removes startup registration and stops manager.
- Whole-device and Partition 1 targets are now reduced to a raw-region identity.
  `\\.\PhysicalDrive1` and
  `\\?\GLOBALROOT\Device\Harddisk1\Partition1` both resolve to
  `disk:1:offset:0`; canonicalization keeps only exact Partition 1 at `V:` and
  prevents concurrent workers over the same APFS bytes. Evidence:
  `artifacts\service-aliases\raw-alias-deduplication-session-proof.json`.
- Copied-core uncompressed range reads now read requested extents directly, and
  each worker keeps one reader session per mounted APFS generation. Mutations
  destroy the old session before closing its device and create a fresh session
  after commit. Session range behavior is covered by `apfs_core_selftest`.
- `artifacts\usb-rw\usb-native-extended-unicode-proof.json` passed nested
  Unicode names, a 394-character path, Robocopy with a 1 MiB payload, four
  concurrent readers, matching hashes, recursive cleanup, and read-only/
  raw-disabled restoration. It completed in 34.3 seconds versus 71.8 seconds
  before persistent reader sessions. No service restart or reboot occurred.
- Service and worker logs rotate at 8 MiB. Service startup prunes legacy
  oversized logs; the live repair removed prior 990 MB worker and 519 MB service
  logs. `apfs_service_log_rotation` verifies pruning in a temporary ProgramData
  root, and CTest now passes 12/12.
- No host reboot was performed; explicit instruction not to restart this PC
  remains in force. Windows VM reboot/logon proof is tracked separately.
- `scripts\verify-usb-pnp-loss-recovery.ps1` pins the USB device by disk, serial,
  size, bus, and PnP instance before attempting a software disable/enable cycle.
  Windows blocked the current attempt because the device has a pending reboot
  operation and this OS product does not support the requested `pnputil` action.
  No media mutation occurred; service PID remained stable and `V:` recovered
  read-only/raw-disabled. Physical surprise unplug and power-loss proof remain
  open without restarting the host.
- Copied reader/writer now preserves fixed Apple inode metadata during tree-wide
  copy-on-write rebuilds: create/modify/change/access times, write generation,
  BSD flags, owner/group, exact inode mode, file payload, and directory payload.
- Tree collection now includes Apple-created symbolic links. Symlink xattrs accept
  Apple flag combinations, keep `com.apple.fs.symlink` filesystem-owned, preserve
  exact `0120755` type/mode, and emit no regular-file data stream or extent.
- `apfs_core_selftest` creates a symbolic link and proves it survives a later COW
  mutation. `apfs_probe --debug-file` now reports fixed inode metadata used by the
  cross-platform preservation assertion.
- Copied writer metadata updates now atomically create, replace, or delete
  embedded regular-file, named-directory, and volume-root xattrs while preserving
  unrelated embedded xattrs. Directory state, including root inode 2, is
  batch-recovered in one fs-tree walk and preserved across unrelated COW
  mutations; directory stream-backed xattrs fail
  closed instead of being dropped. WinFsp `GetEa`/`SetEa` exposes printable ASCII
  names from 1 through 127 bytes and values up to the APFS embedded limit of
  3,804 bytes. Protected
  `com.apple.decmpfs`, `com.apple.ResourceFork`, and `com.apple.fs.symlink`
  attributes fail closed. Non-ASCII-name and large stream-backed xattr mutation
  remain outside current scope.
- Local WinFsp proof passed file, named-directory, and volume-root EA create/read,
  restart persistence, update, and delete. Physical `V:` proof passed file,
  directory, and volume-root operations using `user.apfswin_usb`,
  `user.apfswin_usb_directory`, and `user.apfswin_usb_root`, then removed its
  proof tree and restored read-only/raw-disabled policy.
  `apfs_core_selftest` also verifies copied-core directory-EA preservation across
  child-file writes plus set/read/delete and protected-name rejection.
- `scripts\verify-apple-vm-roundtrip.ps1` is a credential-free tracked harness:
  host, user, and ignored password file are runtime inputs; credential material is
  never copied into source or proof JSON. Parameterized shell helpers live under
  `scripts\apple-vm`.
- Automated Windows -> macOS -> Windows -> macOS proof passed on 2026-08-16 in
  33.216 seconds. Windows created file, directory, and volume-root EAs; macOS read
  and updated all three, created file, directory, and volume-root xattrs, a hard
  link, and a symbolic link; Windows read the macOS xattrs, updated one
  file/directory/root set, deleted the other set, and replaced its original EAs;
  final macOS verified every expected value and deletion. Windows also removed
  one hard-link name while preserving the
  surviving inode metadata exactly. Native `fsck_apfs -n` passed before and
  after both macOS mounts. Final image SHA-256 was
  `81EA59A4101F4B024E9CF495DBF3CB2E5B9E07746C5FC86B6FA656FAA9D03068`.
  Sanitized evidence:
  `docs\evidence\apple-vm-roundtrip-2026-08-16.json`.
- Integrated no-host-reboot certification passed 28 steps with `-SkipBuild` from
  `2026-08-16T23:37:22Z` through `2026-08-16T23:41:21Z` after the same Release
  build and 12-test CTest suite had already passed. All required local,
  installed-service, native Apple, direct mounted-drive, alias-deduplication,
  serial-pinned USB RW, Unicode, 394-character path, Robocopy, concurrent-read,
  metadata/ACL/symbolic-link/EA, cleanup, and read-only restoration gates passed.
  Repair was intentionally a separate passing elevated step before certification.
  Sanitized evidence: `docs\evidence\no-reboot-certification-2026-08-16.json`.
- Exact release ZIP Windows 11 VM lifecycle passed from
  `2026-08-16T23:54:21Z` through `2026-08-16T23:56:38Z`. Archive
  `9153DBFD2032487FD0A37508701B089D2F0947C89FFBAE05AD0C5A8F77A8435E`
  installed using package-local Qt, restored saved `R:` automatically after VM
  reboot, matched the expected file hash, denied writes in read-only mode, ran
  one interactive tray with `Open` and `Exit`, and matched installed binary
  hashes. Packaged uninstall then removed service, mount, manager, startup task,
  Run fallback, Start Menu, Apps & Features registration, and install root while
  preserving WinFsp and the APFS fixture. Sanitized evidence:
  `docs\evidence\windows-vm-install-lifecycle-2026-08-16.json`.
- Current copied-core build also passed a separate 100/100-iteration Robocopy
  soak after integrated certification, with zero failed iterations, recursive
  cleanup each time, and only `large.bin` plus `seed.txt` present after unmount.
  Artifact:
  `artifacts\local-robocopy-stress\worker-robocopy-stress-100-directory-ea-proof.json`.
- `scripts\verify-windows-vm-package-lifecycle.ps1` and
  `scripts\windows-vm\run-package-lifecycle-phase.ps1` replace the earlier
  ignored one-off VM commands with a credential-free reusable harness. Host,
  user, and ignored password file remain runtime inputs; the harness restarts
  only the named VM and cleans its remote validation directory after uninstall.

## 2026-08-17 Current Implementation Update

- Copied reader session `debugFile("/")` now resolves APFS root inode 2 directly.
  WinFsp root resolution uses its real times, generation, BSD flags, owner/group,
  and mode instead of synthetic `0755` metadata. Root `SetBasicInfo`,
  `SetSecurity`, and `SetEa` now share the copied writer's inode-metadata
  transaction; upstream `S.A.K.-Utility` was not modified.
- `apfs_core_selftest` writes exact root create/modify/change/access times, mode,
  BSD flags, owner/group, and preserves an existing root xattr. Release build and
  CTest pass 12/12.
- Local non-admin WinFsp proof sets root times, Hidden/Archive flags, and a
  compatibility ACL, verifies raw inode mode `040777`, owner/group `544:544`,
  BSD flags `0x18000`, root xattr coexistence, and identical state after remount.
- Native Windows -> macOS -> Windows -> macOS round trip passed in 35.809 seconds.
  Apple validated Windows root birth time, flags, mode, and xattrs; macOS changed
  root mtime, flags, and mode; Windows read and replaced them; final Apple mount
  validated Windows replacement plus four clean `fsck_apfs -n` runs. Raw APFS
  owner/group remained `544:544`; macOS presented `501:20` because image
  ownership was disabled. Final image SHA-256:
  `AE08EFBEA34A951F6E74F2C6ED9993C305DB0C9D0D8C299F1402578974C74D31`.
- Serial-pinned physical USB proof transiently set volume-root
  create/access/write times and Hidden/Archive flags, then restored original
  Windows-visible values and flags. Windows `FILETIME` resolution is 100 ns, so
  sub-100 ns APFS timestamp tails, change time, and write generation are not
  claimed bit-identical. Physical root security was intentionally not changed.
  Root/file/directory EAs and proof tree were removed; `V:` finished read-only
  with raw writes disabled.
- Integrated no-host-reboot certification passed 28 steps from
  `2026-08-17T00:23:33Z` through `2026-08-17T00:26:53Z`: local gates, installed
  Automatic service, native Apple round trip, raw-alias deduplication, mounted
  USB metadata/EA/symbolic-link actions, serial-pinned USB RW, Unicode,
  394-character path, 1 MiB Robocopy, concurrent readers, cleanup, and final
  read-only restoration all passed. No host reboot occurred.
- Fresh release ZIP
  `C703700C79FD477207D9D99911D253F38B617924D2E5348990A04D4432C6C521`
  passed exact-archive Windows 11 VM lifecycle from `2026-08-17T00:32:16Z`
  through `2026-08-17T00:34:38Z`: clean install, Automatic service, saved `R:`
  APFS mount restoration after VM reboot, expected file hash, read-only denial,
  one interactive tray with `Open`/`Exit`, and installed binary hashes all
  passed. Packaged uninstall removed all product residue and remote artifacts.
  Host PC was not rebooted. Sanitized evidence:
  `docs\evidence\windows-vm-install-lifecycle-2026-08-17.json`.
