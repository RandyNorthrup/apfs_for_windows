# Production Readiness

Status date: 2026-08-17

Current classification: **development-certified, not production-ready**.

## Closed gates

| Gate | Current evidence |
|---|---|
| APFS copied-core import | 20-file manifest pinned to source commit `5587736df4d27e0eb5ca6e9f60f3c69614023b13` |
| Core/image/raw tests | Release build and CTest 13/13, including stream-backed regular-file xattr transactions |
| Native macOS compatibility | Hard-link artifact mounted by macOS and passed three `fsck_apfs` runs |
| Physical APFS USB operations | Read/write/delete, Unicode, long path, Robocopy, concurrent reads, cleanup |
| Default mount policy | Newly discovered media is read-only; the owner-pinned `V:` test mapping is explicitly writable |
| Persistence model | Automatic service plus per-user tray startup and explicit tray Exit |
| Repository source boundary | Upstream S.A.K. APFS paths verified read-only and unchanged since import |
| Repository hygiene | No duplicate code files, forbidden tracked roots, conflict markers, or tracked secrets |
| Production compiler mode | Pinned coherent WinFsp input, native hard-link ABI, `/W4 /WX`, CTest 13/13 |
| Current-build physical APFS proof | Matching installed/build worker; non-admin namespace, metadata, EA, ACL, symlink, cleanup, and 9,001/12,017-byte stream EA operations |
| Native Windows hard-link transport | Exact fork driver/DLL/worker pairing; root and nested create, link-count lifecycle, alias mutation, stock-driver coexistence |
| Fork driver build | Clean VS2022/WDK 10.0.26100 x64 SYS and DLL build from pinned public commit |
| Development package lifecycle | 31-file test-signed candidate; clean install, VM reboot persistence, tray Open/Exit, exact hashes, clean uninstall |
| Package structure | Bundled SxS driver/runtime, build metadata, provenance, payload manifest, and SHA-256 list |

Current hard-link/runtime/package evidence is summarized in
`docs/evidence/winfsp-hardlink-package-2026-08-17.json`. The test package SHA-256
is `170E6EA93F6F54293BA449E71058A7C4424B7D1C8076DBD768E88D660F67EABC`.
It is explicitly test-signed and is not a production artifact.

## Open production blockers

| Blocker | Required closure |
|---|---|
| Driver trust | Microsoft-compatible production signing; no Test Mode or integrity bypass |
| Application trust | Authenticode-sign project executables and release installer/package flow |
| Production package lifecycle | Repeat clean install, startup, mount, Explorer mutation, reboot, tray Exit, and uninstall with the production-signed package SHA-256 |
| Reproducible build | Move the proven clean VS2022/WDK build into retained CI with kernel tests and provenance |
| Fault recovery | Real surprise-unplug and interrupted-write/power-loss recovery on disposable physical APFS media |
| Remaining APFS policy | Directory/root stream-backed xattrs, case-colliding names, and sealed/FileVault/filesystem-owned policy beyond fail-closed behavior |
| Release governance | Protected branch, required CI checks, reviewed release tag, provenance, and retained evidence |

Physical USB create/read/rename/overwrite/delete, metadata, EA, symlink, ACL,
and cleanup passed on worker SHA-256 `9F01F88C...125B2`, which exactly matched
the current build. Regular-file stream EA create/read at 9,001 bytes, replacement
at 12,017 bytes, and delete also passed. The host was not rebooted. The pinned
test mapping remains explicitly writable by owner direction; newly discovered
media still defaults read-only. See
`docs/evidence/stream-xattr-usb-2026-08-17.json`.

## Strict check

Run:

```powershell
.\scripts\verify-production-readiness.ps1
```

This check is intentionally red until every package, signature, dependency,
and destructive-test requirement is tied to the same release candidate.
