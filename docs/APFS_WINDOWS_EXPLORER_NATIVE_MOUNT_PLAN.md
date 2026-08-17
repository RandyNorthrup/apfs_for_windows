# APFS Windows Explorer Native Mount Plan

## Objective

Provide persistent native-style APFS access in Windows Explorer. Supported media
must mount automatically with a drive letter and support normal read, write,
create, rename, move, and delete workflows without requiring users to launch a
developer tool.

This repository is standalone. APFS source imported from S.A.K. is copied into
`third_party/sak_apfs_core` before project-specific changes. External S.A.K.
source remains outside this repository and is never modified by this project.

## Release Boundary

Current release class is an owner-controlled, test-signed public beta:

- application and package binaries are unsigned;
- the dedicated filesystem driver is WDK test-signed;
- persistent Windows Test Signing is required;
- production signing is not planned;
- physical surprise-unplug and power-loss recovery are unverified;
- no production-ready claim is permitted.

See `RELEASE_POLICY.json` and `docs/PRODUCTION_READINESS.md`.

## Architecture

```text
Windows Plug and Play / service startup
                 |
                 v
      ApfsForWindowsMountService
      - device discovery
      - safety and mount policy
      - drive-letter allocation
      - worker supervision
      - local control IPC
                 |
                 v
          apfs_winfs_worker
          - WinFsp callbacks
          - APFS reader/writer session
          - metadata translation
          - mutation and recovery policy
                 |
                 v
       copied APFS core + LZFSE/LZVN
                 |
                 v
         APFS image or raw region

Per-user apfs_mount_manager
- persistent tray icon
- accessible mount table
- health and policy controls
- Open and Exit tray actions
```

WinFsp transport comes from the pinned `winfsp-apfs` submodule. The dedicated
runtime carries the native hard-link protocol extension and remains side by side
with any stock WinFsp installation.

## Implemented Capabilities

| Area | Current state |
|---|---|
| Discovery | APFS whole devices plus GPT/MBR partitions detected by on-disk signature |
| Automatic mounting | Supported new media receives a free drive letter and writable policy |
| Persistence | Automatic service restores explicit policy and available mounts after Windows starts |
| File operations | Create, read, write, overwrite, rename, move, truncate, and delete |
| Directories | Nested create, enumerate, rename, move, empty delete, and recursive Explorer cleanup |
| Large writes | Raw targets use staged streaming commits; image targets retain bounded buffering |
| Metadata | APFS timestamps, Windows attributes, POSIX-compatible owner/group/mode, and link counts |
| Links | Existing and newly created symbolic links and hard links |
| Extended attributes | File, directory, and volume-root EAs, including encoded UTF-8 names and stream-backed values |
| Alternate data streams | Transported through protected APFS xattr/data-stream storage |
| Recovery | Copy-on-write checkpoint selection and deterministic old-or-new interruption behavior |
| Service | Live configuration sync, target-loss handling, worker restart, device notifications, and bounded logs |
| Manager | Accessible Qt UI, persistent stacked `AP`/`FS` tray, single instance, Open/Exit actions |
| Installation | Test Signing helper, installer, repair, uninstall, Start menu, Apps & Features, and startup registration |
| Privacy | Local paths, private email metadata, networks, credentials, and machine evidence blocked from source and packages |
| Release | Deterministic test-signed ZIP built and verified by GitHub Actions |

## Safety Policy

Writable mounting requires all of these conditions:

- exact APFS signature and canonical raw-region identity;
- supported unencrypted and unsealed volume policy;
- explicit read/write policy;
- raw-write permission for a physical target;
- no competing worker for the same canonical bytes;
- no protected content-critical or filesystem-owned metadata mutation.

Writable requests fail closed for:

- sealed system volumes;
- FileVault or per-file-key encrypted content;
- unknown or malformed volume policy;
- non-APFS targets;
- ambiguous duplicate raw aliases;
- unsupported external symbolic-link targets;
- protected APFS metadata.

Read-only mode remains available as an explicit saved policy.

## User Workflow

1. Install the test-signed package and restart manually when Test Signing needs it.
2. Plug in supported APFS media.
3. Wait for a drive letter to appear in Explorer.
4. Use files normally or open the tray manager to inspect/change policy.
5. Unmount or eject writable media before disconnecting it.
6. Uninstall from the retained release package when no longer needed.

See `docs/INSTALLATION.md` and `docs/USER_GUIDE.md`.

## Verification Model

### Repository Gates

- privacy scan of files and Git metadata;
- repository layout and main-only governance;
- APFS import manifest verification;
- pinned WinFsp source/runtime verification;
- license and release-policy verification;
- PowerShell parse and conflict-marker checks.

### Local Functional Gates

- production-mode build with warnings as errors;
- CTest APFS core, service, policy, IPC, parser, and log tests;
- generated-image WinFsp file-operation tests;
- Robocopy, large-file, metadata, link, EA, and stream tests;
- service policy, live sync, supervision, and failure tests;
- deterministic interruption and remount tests.

### External Interoperability Gates

- macOS native mount, mutation, and `fsck_apfs` validation;
- Windows VM exact-package install, restart persistence, tray, and uninstall;
- removable APFS media normal-user namespace and metadata operations.

External hosts, users, credentials, serials, device targets, and raw results are
runtime-only inputs. Generated evidence remains ignored and private.

### Package Gates

- clean source and exact commit identity;
- logical dependency metadata with no developer paths;
- deterministic ZIP layout and file hashes;
- PowerShell 5.1 and PowerShell 7 verification;
- required Qt and dedicated WinFsp payloads;
- test-driver certificate classification;
- install, repair, and uninstall payload validation;
- package privacy scan before upload.

See `docs/TESTING.md` and `docs/RELEASING.md`.

## Completion Criteria

The owner-controlled public beta is complete when:

- supported devices automount and remain usable in Explorer;
- user namespace and metadata operations pass current tests;
- service, tray, restart persistence, repair, and uninstall pass;
- package is deterministic and tied to sanitized `main`;
- privacy and repository gates pass;
- GitHub release assets match generated SHA-256 proof;
- release is clearly labeled test-signed and not production-ready;
- documented unsupported policies continue to fail closed.

## Open Boundaries

These are accepted release limitations, not completed production claims:

- production kernel-driver signing and Test Mode removal;
- physical surprise-unplug recovery;
- physical power-loss recovery;
- encrypted and sealed writable volume support.

Any future closure requires new code, focused regression tests, package rebuild,
external interoperability proof, documentation updates, and a new release.
