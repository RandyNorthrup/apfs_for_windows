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
| Repository source isolation | Imported manifest and vendored hashes intact; this repository never writes the upstream S.A.K. checkout |
| Repository hygiene | No duplicate code files, forbidden tracked roots, conflict markers, or tracked secrets |
| Production compiler mode | Pinned coherent WinFsp input, native hard-link ABI, `/W4 /WX`, CTest 13/13 |
| Reproducible release build | Production mode enables `/Brepro`, deterministic compilation, and source path mapping; current verifier compares tested binaries, metadata, and complete stored-entry packages across detached source paths and PowerShell 5.1/7 |
| Clean candidate build | Source `7ddcb7a1d0151a7d2221d68f5564c3288f9c97f7`; production mode, clean metadata, CI green, local WinFsp and macOS stream proofs passed |
| Current-build physical APFS proof | Matching installed/build worker; non-admin namespace, metadata, EA, ACL, symlink, cleanup, and 9,001/12,017-byte regular-file/directory/root stream EA operations |
| Native Windows hard-link transport | Exact dedicated driver/DLL/worker pairing; root and nested create, link-count lifecycle, alias mutation, stock-driver coexistence |
| Dedicated runtime source | Pinned commit approved after kernel/ABI review, clean build, and isolated VM transport proof |
| Dedicated driver build | Clean VS2022/WDK 10.0.26100 x64 SYS and DLL build from pinned public commit |
| Development package lifecycle | Current 31-file test-signed candidate `C2B9...6F6`; clean install, VM reboot persistence, tray Open/Exit, exact hashes, clean uninstall |
| Package structure | Bundled SxS driver/runtime, build metadata, provenance, payload manifest, and SHA-256 list |
| Synthetic raw interruption | Exact test package completed 16 MiB raw-VHD write and remount; worker kill after 328 changed blocks selected complete old generation with invariant preserved |
| Repository protection baseline | Public `main`; admin enforcement; strict `repository-gates`; linear history; force-push and deletion disabled |

Current hard-link/runtime/package evidence is summarized in
`docs/evidence/winfsp-hardlink-package-2026-08-17.json`. The test package SHA-256
is `8A179018DFB17415A176697B8C91FE6BC809A966EF906CF7335DDEAF4573BFB7`.
It is explicitly test-signed and is not a production artifact.
Source approval details are in
`docs/evidence/winfsp-runtime-source-approval-2026-08-17.json`; approval does not
waive production driver signing or exact-package release gates.

Live upstream verification passed at `2026-08-17T07:32:49Z`. Concurrent owner
work then briefly modified imported `src/core/apfs_keybag.cpp`, making one strict
run red, before making that path clean. The latest check at
`2026-08-17T07:53:07Z` passes with only unrelated HFS/test/catalog work dirty.
No upstream file was changed by this project.

Source commit `0c51b376d1890004ea41aff67555fef6a3aebd04` passed the
two-clean-worktree reproducibility verifier. Both detached paths passed CTest
13/13; Windows PowerShell 5.1 and PowerShell 7 package verification passed; all
four shipped executables, build metadata, and the full 31,709,496-byte
test-signed ZIP were byte-identical. ZIP SHA-256 was
`FB484D4FD07C235248E92EB51A083309027F4C8EC9217143367B710FF182AC86`. See
`docs/evidence/reproducible-build-2026-08-17.json`.

Clean source commit `7ddcb7a` produced two retained test candidates. Package
SHA-256 `50EECCD5ECDD4A3393FD26C8DF932E3C13858D35476574DF226681EC8B432FA5`
passed local WinFsp and macOS interoperability. Package SHA-256
`55A7CEAA0FE3FC975AD9D2B1D282F0CA3AF26080E4EF888CAAE9DB5DA2D677DA`
passed package verification plus Windows VM install, reboot persistence, tray
Open/Exit, exact installed hashes, clean uninstall, and remote cleanup. Both are
test-signed and not production artifacts. See
`docs/evidence/clean-candidate-2026-08-17.json`.

Reproducibility proof for source `0c51b376d1890004ea41aff67555fef6a3aebd04`
passed two detached source paths, two CTest 13/13 runs, two package verifications,
matching hashes for every shipped project executable and metadata, and matching
full test-package SHA-256
`FB484D4FD07C235248E92EB51A083309027F4C8EC9217143367B710FF182AC86`
across Windows PowerShell 5.1 and PowerShell 7. See
`docs/evidence/reproducible-build-2026-08-17.json`.

## Open production blockers

| Blocker | Required closure |
|---|---|
| Driver trust | Microsoft-compatible production signing; no Test Mode or integrity bypass |
| Application trust | Authenticode-sign project executables and release installer/package flow |
| Production package lifecycle | Repeat clean install, startup, mount, Explorer mutation, reboot, tray Exit, and uninstall with the production-signed package SHA-256 |
| Production physical USB package | Repeat Explorer read/write/delete and stream-xattr proof with exact production-signed package binaries |
| Reproducible kernel/runtime CI | Move the pinned WinFsp VS2022/WDK build into retained CI with kernel tests and provenance |
| Fault recovery | Real surprise-unplug and interrupted-write/power-loss recovery on disposable physical APFS media |
| Remaining APFS policy | Sealed/FileVault/per-file-key and filesystem-owned mutation policy beyond current fail-closed behavior |
| Release governance | Admin-enforced branch protection now exists; add required reviews, reviewed signed release tag, production provenance, and retained release evidence |

Physical USB create/read/rename/overwrite/delete, Unicode/394-character paths,
Robocopy, concurrent reads, metadata, EA, symlink, ACL, and durable cleanup were
revalidated on installed worker SHA-256
`E94F3E1E642F0C6908F2D730CD6BEA05C1BB476D1591D9D3CF0C07062D6BFCA8`.
Regular-file, directory, and volume-root stream EA create/read at 9,001 bytes,
replacement at 12,017 bytes, and delete passed. Host was not rebooted. Final
independent audit found service Automatic/running, `V:` read-only, raw writes
disabled, and mount root empty. Installed worker does not match exact test
package worker `F04E290A...BD25`; proof is current-installed-runtime only, not
exact-package physical certification. See
`docs/evidence/physical-usb-current-installed-revalidation-2026-08-17.json`.

Earlier matching-build stream, case-collision, remount, macOS replacement, and
three-pass `fsck_apfs -n` evidence remains in
`docs/evidence/directory-root-stream-xattrs-2026-08-17.json`.

Clean source commit `7ddcb7a1d0151a7d2221d68f5564c3288f9c97f7` produced worker
SHA-256 `C1682B13E0E1D1451C482B9280D5DCBB601447EE685E4F8C6B86704113BF5E7D`.
That exact worker passed CTest 13/13, local two-mount WinFsp coverage, and the
macOS root/directory stream round trip with three `fsck_apfs -n` passes. The
installed physical-USB worker remains the earlier feature build because its
Program Files replacement needs administrator approval; no ACL, signing, or
boot-policy bypass was attempted. Exact clean-candidate USB proof therefore
remains open.

Use `scripts/deploy-current-worker-for-certification.ps1` without arguments for
non-admin preflight. Run the same command with `-Apply` from Administrator
PowerShell for the bounded worker-only replacement; it verifies source/install
hashes, service recovery, and unchanged driver identity before USB proof.

Exact-package worker mode additionally requires package ZIP and worker SHA-256
pins. Current non-admin preflight passed: ZIP `C2B9...6F6`, ZIP worker,
staged worker, and expected worker `F04E290...BD25` all match; production build,
clean source metadata, native hard-link transport, Automatic service, and
existing driver inventory also pass. Wrong ZIP hash and non-admin `-Apply`
negative tests fail closed without changing service PID or installed worker.

For full exact-package replacement, guarded repair now forwards `-RepairScript`,
`-BuildDir`, and `-AllowTestSignedDriver` through its encoded elevated command.
Exact package payload validation and argument round-trip pass. Host deployment
was correctly not started while unrelated UAC prompts were already pending.
Because that path also replaces WinFsp driver, current host physical proof will
use rollback-capable worker-only package mode; full package requires a
production-signed driver or an isolated test-driver-enabled VM. One interactive
administrator approval remains required for worker replacement.

The clean VM-lifecycle package used worker SHA-256
`81F8B65AA60C33C57E98DFDFCE81D8E5D2EC0B6D5FF6B8F9B238BC670D38078F`.
Only the Windows VM rebooted; the host did not. This closes the clean development
package lifecycle lane, not production signing or exact physical USB proof.

Historical source `d5e68ccef376ba115d4fbcf98391c56d8f1b2977` produced worker
SHA-256 `F04E290A6F1FB39402A948D5831BC3FCAF4BBBA6E8F762C51322C84589E3BD25`
and deterministic test-package SHA-256
`B2944BB636EED3003DC827A169550E3DB813A0C2BF39ACCC5DECA7CF873EDCBD`.
CTest passed 13/13 and package verification passed under Windows PowerShell 5.1
and PowerShell 7. Exact Windows VM install, Automatic/running service before and
after VM reboot, restored `R:`, one interactive tray with `Open`/`Exit`, exact
installed hashes, uninstall, and independent residue cleanup passed. The host
did not reboot. See
`docs/evidence/windows-vm-install-lifecycle-d5e68cc-2026-08-17.json`.

Current candidate source `7d23245ee487ab0db833c114d521558442d8208a`
produced the same worker SHA-256 and deterministic 31-file test ZIP SHA-256
`C2B9A2950AE62EA114BBB3E2F880048D777B87682B673F6CFF7C60B9ABF536F6`.
Production build and CTest 13/13 passed. Two detached source paths produced
byte-identical project binaries, metadata, and complete ZIP; both CTest and
package-verification runs passed with zero cleanup errors. Exact ZIP install,
Automatic service, dedicated driver/runtime, VM reboot and restored `R:`, one
interactive stacked tray with `Open`/`Exit`, exact installed hashes, uninstall,
and independent residue cleanup passed. Host did not reboot. See
`docs/evidence/current-candidate-7d23245-2026-08-17.json`.

Repository protection evidence is retained in
`docs/evidence/repository-governance-2026-08-17.json`. This closes baseline
branch protection, not final production release governance.

The Windows VM raw-interruption harness now installs an exact package and uses
a disposable fixed VHD through `\\.\PhysicalDriveN`. Its completed-write control
requires an exact 16 MiB payload after probe and read-only remount before any
worker-termination timing is accepted. Passing this synthetic lane reduces raw
commit risk but does not close the physical surprise-unplug/power-loss blocker.
Package source `ee161b74e0ab9971c5955a3e256dce7e13414612`, worker SHA-256
`F04E290A6F1FB39402A948D5831BC3FCAF4BBBA6E8F762C51322C84589E3BD25`,
and the sanitized result are retained in
`docs/evidence/windows-vm-raw-interruption-final-2026-08-17.json`.
The selected interrupted image also passed two native macOS `fsck_apfs -n`
runs and a kernel read-only mount with exact invariant and complete old-generation
hashes. See `docs/evidence/apple-vm-raw-interruption-final-2026-08-17.json`.

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
