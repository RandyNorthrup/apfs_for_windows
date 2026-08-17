# Architecture

## Repository map

| Path | Ownership | Purpose |
|---|---|---|
| `src/service` | Project | Automatic service, discovery, policy, worker supervision |
| `src/worker` | Project | WinFsp callbacks and APFS mount lifecycle |
| `src/manager` | Project | Accessible tray and mount-management UI |
| `src/tools` | Project | APFS probe and diagnostics |
| `src/tests` | Project | Copied-core image/raw self-tests |
| `third_party/sak_apfs_core` | Local copy | Imported Randy-authored APFS reader/writer |
| `third_party/lzfse` | Third party | Apple LZFSE/LZVN codec implementation |
| `third_party/winfsp` | Pinned submodule | Dedicated native Windows filesystem transport |
| `scripts` | Project | Install, package, privacy, verification, and certification automation |
| `docs` | Project | User, developer, architecture, release, and claim-boundary documentation |

Build output belongs under ignored `build*`. Runtime and certification output
belongs under ignored `artifacts`. Credentials, machine evidence, and temporary
dependency checkouts belong outside tracked source and must never become build
provenance for a release package.

## Runtime model

`apfs_mount_service` runs automatically and owns persistent mount policy. It
discovers APFS targets, validates raw-write policy, and starts one
`apfs_winfs_worker` per canonical APFS region. Worker processes translate
WinFsp requests into copied-core reader/writer operations. `apfs_mount_manager`
is a per-user tray process and talks to service IPC; it does not own filesystem
state.

Newly discovered supported APFS media defaults to writable mount policy with
raw-write permission so plug-in devices are immediately usable in Explorer.
Saved explicit policy is preserved, including read-only mounts. Service APFS
signature validation and worker volume-policy validation form separate trust
boundaries; sealed, encrypted, unknown-policy, and non-APFS writable targets
fail closed.

## Dependency boundary

WinFsp provides Windows filesystem transport. Native hard-link creation needs
the reviewed `winfsp-apfs` protocol/kernel extension; a header-only or mixed
header/library build is not valid release evidence. Qt provides service IPC and
manager UI runtime. APFS codec notices remain in `THIRD_PARTY_LICENSES.md`.

`third_party/sak_apfs_core/IMPORT_MANIFEST.json` is the canonical APFS import
inventory. It records source commit, source Git blob, source SHA-256, vendored
SHA-256, and local-copy status for every imported file. No second APFS core copy
is allowed.

## Release flow

1. Pass repository privacy, hygiene, source-boundary, license, build, and CTest gates.
2. Build from an explicit coherent WinFsp root and emit build metadata.
3. Build the dedicated WDK test-signed kernel driver. Project application/package
   binaries remain unsigned, and owner distribution requires persistent Windows
   Test Signing. Production signing is not planned.
4. Build deterministic package, generate hashes, embed release policy, remove
   absolute dependency paths, and verify package-local payloads and privacy.
5. Run exact-package lifecycle and destructive-media certification in isolated
   test systems.
6. Publish a GitHub prerelease only when owner-readiness has no blockers. Physical
   fault recovery remains an explicit untested risk; no public `production-ready`
   claim is made.
