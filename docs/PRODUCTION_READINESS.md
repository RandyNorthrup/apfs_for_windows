# Production Readiness

Status date: 2026-08-16

Current classification: **development-certified, not production-ready**.

## Closed gates

| Gate | Current evidence |
|---|---|
| APFS copied-core import | 20-file manifest pinned to source commit `5587736df4d27e0eb5ca6e9f60f3c69614023b13` |
| Core/image/raw tests | Release build and CTest 12/12 |
| Native macOS compatibility | Hard-link artifact mounted by macOS and passed three `fsck_apfs` runs |
| Physical APFS USB operations | Read/write/delete, Unicode, long path, Robocopy, concurrent reads, cleanup |
| Default media state | Physical target restored read-only with raw writes disabled |
| Persistence model | Automatic service plus per-user tray startup and explicit tray Exit |
| Repository source boundary | Upstream S.A.K. APFS paths verified read-only and unchanged since import |
| Repository hygiene | No duplicate code files, forbidden tracked roots, conflict markers, or tracked secrets |
| Production compiler mode | Pinned coherent WinFsp input, native hard-link ABI, `/W4 /WX`, CTest 12/12 |
| Package structure | 25-file candidate with build metadata, provenance, payload manifest, and SHA-256 list |

Latest no-host-reboot certification artifact:
`artifacts/certification/core-sync-hardlink-certification.json`. It executed 27
gates with zero failures. Artifact output is intentionally ignored; sanitized
proof summaries belong under `docs/evidence`.

## Open production blockers

| Blocker | Required closure |
|---|---|
| Native Windows hard-link transport | Fork is published and pinned; prove exact kernel/DLL/APFS worker ABI and runtime pairing |
| Driver build | Reproducible WDK build in clean CI with kernel tests |
| Driver trust | Microsoft-compatible production signing; no Test Mode or integrity bypass |
| Application trust | Authenticode-sign project executables and release installer/package flow |
| Exact-package lifecycle | Clean Windows install, startup, mount, Explorer mutation, reboot, tray Exit, uninstall tied to current package SHA-256 |
| Fault recovery | Real surprise-unplug and interrupted-write/power-loss recovery on disposable physical APFS media |
| Remaining APFS policy | Large stream-backed xattr mutation and filesystem-owned xattr policy |
| Release governance | Protected branch, required CI checks, reviewed release tag, provenance, and retained evidence |

Older VM lifecycle evidence remains historical. It proves package hash
`D2F1D99DE9DCA8308673FAEE5CA716DBB6E1F19F0E94A5637BF971A72D25E49B`,
not a current package. Current package identity is recorded in
`artifacts/package-production-check/package-proof.json` after a clean build.
No VM action is required or authorized by repository quality gates.

## Strict check

Run:

```powershell
.\scripts\verify-production-readiness.ps1
```

This check is intentionally red until every package, signature, dependency,
and destructive-test requirement is tied to the same release candidate.
