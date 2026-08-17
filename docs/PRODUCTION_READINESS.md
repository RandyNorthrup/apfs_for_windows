# Production Readiness

Status date: 2026-08-17

Current classification: **development-certified, not production-ready**.

## Closed gates

| Gate | Current evidence |
|---|---|
| APFS copied-core import | 20-file manifest pinned to source commit `5587736df4d27e0eb5ca6e9f60f3c69614023b13` |
| Core/image/raw tests | Release build and CTest 13/13, including regular-file/directory/root stream-backed xattrs and directory-stream delete reclamation |
| Native macOS compatibility | Hard-link artifact plus root/directory stream-xattr artifact mounted by macOS; stream artifact passed three `fsck_apfs` runs |
| Physical APFS USB operations | Read/write/delete, Unicode, long path, Robocopy, concurrent reads, regular-file/directory/root stream xattrs, cleanup |
| Default mount policy | Newly discovered media is read-only; the owner-pinned `V:` test mapping is explicitly writable |
| Persistence model | Automatic service plus per-user tray startup and explicit tray Exit |
| Repository source boundary | Upstream S.A.K. APFS paths verified read-only and unchanged since import |
| Repository hygiene | No duplicate code files, forbidden tracked roots, conflict markers, or tracked secrets |
| Production compiler mode | Pinned coherent WinFsp input, native hard-link ABI, `/W4 /WX`, CTest 13/13 |
| Clean candidate build | Source `7ddcb7a1d0151a7d2221d68f5564c3288f9c97f7`; production mode, clean metadata, CI green, local WinFsp and macOS stream proofs passed |
| Current-build physical APFS proof | Matching installed/build worker; non-admin namespace, metadata, EA, ACL, symlink, cleanup, and 9,001/12,017-byte regular-file/directory/root stream EA operations |
| Native Windows hard-link transport | Exact dedicated driver/DLL/worker pairing; root and nested create, link-count lifecycle, alias mutation, stock-driver coexistence |
| Dedicated runtime source | Pinned commit approved after kernel/ABI review, clean build, and isolated VM transport proof |
| Dedicated driver build | Clean VS2022/WDK 10.0.26100 x64 SYS and DLL build from pinned public commit |
| Development package lifecycle | 31-file test-signed candidate; clean install, VM reboot persistence, tray Open/Exit, exact hashes, clean uninstall |
| Package structure | Bundled SxS driver/runtime, build metadata, provenance, payload manifest, and SHA-256 list |

Current hard-link/runtime/package evidence is summarized in
`docs/evidence/winfsp-hardlink-package-2026-08-17.json`. The test package SHA-256
is `8A179018DFB17415A176697B8C91FE6BC809A966EF906CF7335DDEAF4573BFB7`.
It is explicitly test-signed and is not a production artifact.
Source approval details are in
`docs/evidence/winfsp-runtime-source-approval-2026-08-17.json`; approval does not
waive production driver signing or exact-package release gates.

Latest clean-source test package is
`APFS-for-Windows-0.1.0-test-signed.zip`, SHA-256
`50EECCD5ECDD4A3393FD26C8DF932E3C13858D35476574DF226681EC8B432FA5`.
Its 31-file manifest and payload checks pass, but it has not replaced the older
VM-lifecycle candidate and is not production signed. Clean-candidate evidence is
tracked in `docs/evidence/clean-candidate-2026-08-17.json`.

## Open production blockers

| Blocker | Required closure |
|---|---|
| Driver trust | Microsoft-compatible production signing; no Test Mode or integrity bypass |
| Application trust | Authenticode-sign project executables and release installer/package flow |
| Production package lifecycle | Repeat clean install, startup, mount, Explorer mutation, reboot, tray Exit, and uninstall with the production-signed package SHA-256 |
| Production physical USB package | Repeat Explorer read/write/delete and stream-xattr proof with exact production-signed package binaries |
| Reproducible build | Move the proven clean VS2022/WDK build into retained CI with kernel tests and provenance |
| Fault recovery | Real surprise-unplug and interrupted-write/power-loss recovery on disposable physical APFS media |
| Remaining APFS policy | Sealed/FileVault/per-file-key and filesystem-owned mutation policy beyond current fail-closed behavior |
| Release governance | Protected branch, required CI checks, reviewed release tag, provenance, and retained evidence |

Physical USB create/read/rename/overwrite/delete, metadata, EA, symlink, ACL,
and cleanup passed on worker SHA-256
`E94F3E1E642F0C6908F2D730CD6BEA05C1BB476D1591D9D3CF0C07062D6BFCA8`,
which exactly matched the current build. Regular-file, directory, and volume-root
stream EA create/read at 9,001 bytes, replacement at 12,017 bytes, and delete
passed. Local case-collision aliases remained distinct, ambiguous direct writes
failed closed, and remount persistence passed. macOS replaced both root and
directory streams and passed three `fsck_apfs -n` runs. The host was not
rebooted. The pinned test mapping remains explicitly writable by owner direction;
newly discovered media still defaults read-only. See
`docs/evidence/directory-root-stream-xattrs-2026-08-17.json`.

Clean source commit `7ddcb7a1d0151a7d2221d68f5564c3288f9c97f7` produced worker
SHA-256 `C1682B13E0E1D1451C482B9280D5DCBB601447EE685E4F8C6B86704113BF5E7D`.
That exact worker passed CTest 13/13, local two-mount WinFsp coverage, and the
macOS root/directory stream round trip with three `fsck_apfs -n` passes. The
installed physical-USB worker remains the earlier feature build because its
Program Files replacement needs administrator approval; no ACL, signing, or
boot-policy bypass was attempted. Exact clean-candidate USB proof therefore
remains open.

## Strict check

Run:

```powershell
.\scripts\verify-production-readiness.ps1
```

This check is intentionally red until every package, signature, dependency,
and destructive-test requirement is tied to the same release candidate. Expected
failing child gates are captured in the JSON report instead of aborting the
readiness aggregator; test-signed development packages do not satisfy production
package or signing gates.
