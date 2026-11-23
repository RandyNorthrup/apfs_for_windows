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
| `dependencies/winfsp.json` | Project | Pin for the official WinFsp release (version, MSI URL, SHA-256, signers) |
| `installer` | Project | WiX v5 MSI and Burn `Setup.exe` bundle that chains official WinFsp |
| `scripts` | Project | SDK staging, package, privacy, verification, and certification automation |
| `docs` | Project | User, developer, architecture, release, and claim-boundary documentation |

Build output belongs under ignored `build*`. Runtime and certification output
belongs under ignored `artifacts`, including the staged WinFsp SDK in
`artifacts\winfsp-sdk`. Credentials, machine evidence, and temporary dependency
checkouts belong outside tracked source and must never become build provenance
for a release package.

## Runtime model

`apfs_mount_service` runs automatically and owns persistent mount policy. It
discovers APFS targets, validates raw-write policy, and starts one
`apfs_winfs_worker` per canonical APFS region. Worker processes translate
WinFsp requests into copied-core reader/writer operations. `apfs_mount_manager`
is a per-user tray process and talks to service IPC; it does not own filesystem
state.

Newly discovered supported APFS media defaults to read-only mount policy. A user
switches a volume to read/write per volume from the tray, and the service saves
that choice. Saved explicit policy is preserved on later connections. Service
APFS signature validation and worker volume-policy validation form separate
trust boundaries; sealed, encrypted, unknown-policy, and non-APFS writable
targets fail closed.

Writes are flushed in order around metadata commits (write-ordering flush
barriers), so data reaches the device before the metadata that refers to it.

## Dependency boundary

WinFsp provides the Windows filesystem transport. The product depends on the
official, production-signed WinFsp installed system-wide, pinned in
`dependencies/winfsp.json` (WinFsp 2.2.26323, tag `v2.2`). Its kernel driver is
signed by Microsoft Windows Hardware Compatibility Publisher, and its MSI and
DLL by NAVIMATICS LLC, so no Windows Test Mode is needed. No WinFsp file is
shipped in the APFS for Windows MSI; `Setup.exe` chains the official WinFsp MSI
and installs it when it is missing.

A bundled side-by-side copy of stock WinFsp is not possible: its driver claims
the unsuffixed `\Device\WinFsp.Disk` name and fails to load next to an existing
WinFsp install. That is why the product uses the single system-wide install.

The worker links against the WinFsp import library with
`/DELAYLOAD:winfsp-x64.dll` and calls `FspLoad` at startup, which loads the DLL
from the WinFsp installation directory recorded in the registry. Builds compile
against a staged copy of the official SDK headers and import library (see
[Development](DEVELOPMENT.md)).

Native hard-link creation needs a WinFsp protocol and kernel extension that the
official driver does not have, so creating new hard links from Windows is
unsupported (`native_hard_link_creation: unsupported_with_official_winfsp`).
Existing APFS hard links still open. The worker's
`APFS_WINFSP_NATIVE_HARDLINKS=0` build path is the production path. The earlier
dedicated fork, `https://github.com/RandyNorthrup/winfsp-apfs`, is no longer a
submodule or shipped. It stays public for a future upstream hard-link
contribution to WinFsp.

Qt provides service IPC and manager UI runtime. APFS codec and WinFsp notices
remain in `THIRD_PARTY_LICENSES.md`.

`third_party/sak_apfs_core/IMPORT_MANIFEST.json` is the canonical APFS import
inventory. It records source commit, source Git blob, source SHA-256, vendored
SHA-256, and local-copy status for every imported file. No second APFS core copy
is allowed.

## Release flow

1. Pass repository privacy, hygiene, source-boundary, WinFsp dependency,
   license, build, and CTest gates.
2. Stage the official WinFsp SDK from the pinned MSI: verify its SHA-256 and the
   NAVIMATICS LLC signature, admin-extract it, and verify the Microsoft-signed
   driver.
3. Build in production mode against that staged SDK and emit build metadata,
   which records the WinFsp version.
4. Stage the package and Authenticode-sign the product executables with Azure
   Artifact Signing (`CN=Randy Northrup`, GitHub OIDC in CI). Qt and Visual C++
   runtime files keep their upstream signatures. Signing happens before any
   hash is computed. The stage contains no WinFsp files.
5. Generate hashes, embed release policy, remove absolute dependency paths, and
   verify package-local payloads, signatures (`-RequireSigned`), and privacy.
   A deterministic ZIP of the stage is built only for the reproducibility gate.
6. Build the WiX v5 MSI from the verified stage and the Burn `Setup.exe` that
   chains the pinned WinFsp MSI, and sign both. The MSI registers the service
   through `apfs_mount_service.exe` and removes the legacy 0.2.0 test-signed
   `WinFsp+apfs-main` driver on upgrade. It never changes boot settings.
7. Run exact-package lifecycle and destructive-media certification in isolated
   test systems.
8. Publish a GitHub release (`Setup.exe`, MSI, and `SHA256SUMS.txt`) only when
   owner-readiness has no blockers. Physical fault recovery remains an explicit
   untested risk; no public `production-ready` claim is made.
