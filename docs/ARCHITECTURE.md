# Architecture

## Repository map

| Path | Ownership | Purpose |
|---|---|---|
| `src/service` | Project | Automatic service, discovery, policy, worker supervision |
| `src/worker` | Project | WinFsp callbacks and APFS mount lifecycle |
| `src/manager` | Project | Accessible tray and mount-management UI |
| `src/tools` | Project | APFS probe and diagnostics |
| `src/tests` | Project | Copied-core image/raw self-tests |
| `third_party/sak_apfs_core` | Local fork | Imported Randy-authored APFS reader/writer |
| `third_party/lzfse` | Third party | Apple LZFSE/LZVN codec implementation |
| `third_party/winfsp` | Pinned submodule | Native Windows filesystem transport fork |
| `scripts` | Project | Install, package, verification, and certification automation |
| `docs/evidence` | Sanitized evidence | Durable proof summaries without credentials or raw media |

Build output belongs under ignored `build*`. Runtime and certification output
belongs under ignored `artifacts`. Credentials and temporary dependency
checkouts belong under ignored `temp` and must never become build provenance for
a production package.

## Runtime model

`apfs_mount_service` runs automatically and owns persistent mount policy. It
discovers APFS targets, validates raw-write policy, and starts one
`apfs_winfs_worker` per canonical APFS region. Worker processes translate
WinFsp requests into copied-core reader/writer operations. `apfs_mount_manager`
is a per-user tray process and talks to service IPC; it does not own filesystem
state.

Read-only is default. Writable physical media requires both writable mount
policy and explicit raw-write permission. Service target validation and worker
target validation form separate trust boundaries.

## Dependency boundary

WinFsp provides Windows filesystem transport. Native hard-link creation needs
the reviewed `winfsp-apfs` protocol/kernel extension; a header-only or mixed
header/library build is not valid release evidence. Qt provides service IPC and
manager UI runtime. APFS codec notices remain in `THIRD_PARTY_LICENSES.md`.

`third_party/sak_apfs_core/IMPORT_MANIFEST.json` is the canonical APFS import
inventory. It records source commit, source Git blob, source SHA-256, vendored
SHA-256, and local-fork status for every imported file. No second APFS core copy
is allowed.

## Release flow

1. Pass repository, source-boundary, license, build, and CTest gates.
2. Build from an explicit coherent WinFsp root and emit build metadata.
3. Sign project binaries and required driver/runtime components.
4. Build package, generate hashes, and verify package-local payloads.
5. Run exact-package lifecycle and destructive-media certification in isolated
   test systems.
6. Publish only when strict production-readiness gate has no blockers.
