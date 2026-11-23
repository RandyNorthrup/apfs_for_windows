# Production Readiness

Status date: 2026-11-22

Current classification: **owner-controlled signed Test Mode release; not production-ready**.

Application binaries (service, worker, manager, probe, and WinFsp runtime DLL)
and the MSI installer are Authenticode-signed by `CN=Randy Northrup` with Azure
Artifact Signing and an RFC 3161 timestamp. Bundled Qt and Visual C++ runtime
files keep their original Qt Company and Microsoft signatures. Release CI
refuses to publish unless every project binary has a valid, timestamped
signature from that publisher, and every Qt file a valid, timestamped signature
from either publisher. Payload manifests and SHA-256 hashes remain as integrity evidence.
Signing establishes publisher identity; it does not guarantee Smart App Control
or SmartScreen reputation.

The dedicated filesystem driver is WDK test-signed. Artifact Signing
certificates are not trusted for kernel-mode code, and production kernel signing
(Microsoft attestation signing) needs an EV code-signing certificate and a
Partner Center hardware account, which the owner does not have. Persistent
Windows Test Signing is therefore an explicit owner-accepted distribution
requirement, and the package cannot make a production-ready claim.
It does not automate Secure Boot, BitLocker, Memory Integrity/HVCI, kernel
debugging, or integrity-bypass changes.

Physical surprise-unplug and power-loss recovery are not part of the verified
release evidence. They remain explicit owner-accepted, untested residual risks.
Synthetic worker-termination and raw-VHD interruption tests reduce risk but are not
represented as physical proof. `RELEASE_POLICY.json` records both boundaries.

## Current Candidate

Canonical generated identity is in the packaged `release-manifest.json` and
`artifacts/package/package-proof.json`. Documentation intentionally avoids copying
mutable candidate hashes.

| Gate | Current result |
|---|---|
| Source isolation | Imported APFS manifest is pinned; S.A.K. checkout remains read-only |
| Local build | Clean production-mode configuration, deterministic compiler settings, native hard-link ABI, `/W4 /WX` |
| Tests | CTest 13/13 |
| Package | Deterministic test-signed candidate; PowerShell 5.1 and 7 verification pass |
| Reproducibility | Two detached source paths, two CTest passes, byte-identical binaries, metadata, and ZIP |
| Physical APFS USB | Exact package worker passed normal-user create/read/rename/write/delete, Unicode, long path, Robocopy, concurrent reads, metadata, ACL, symlink, file/directory/root EA, and cleanup |
| Installed runtime | Exact package service/worker; service Automatic/running; dedicated SxS driver retained |
| Windows 11 lifecycle | Exact ZIP install, Automatic service, read-only APFS mount, tray Open/Exit, VM reboot persistence, exact hashes, clean uninstall |
| Uninstall residue | Service, dedicated driver, mount, manager, startup entry, registry, Start menu, install root, and ProgramData absent |
| Protected APFS policy | Writable sealed, FileVault, per-file-key, unknown-policy, filesystem-owned-xattr, and content-critical-xattr paths fail closed |
| Plug-in policy | Newly discovered supported APFS media receives a free drive letter and writable/raw-write policy; explicit saved policy is preserved |
| Repository governance | Sanitized `main` only; privacy and repository gates; admin enforcement; linear history; force-push and deletion disabled |
| Retained runtime CI | Windows Server 2022 builds and hashes x64 SYS, DLL, import library, and kernel test executable without install, Test Mode, or reboot |
| App/package signing | Azure Artifact Signing (`CN=Randy Northrup`), timestamped; enforced by `verify-release-package.ps1 -RequireSigned` and `verify-production-readiness.ps1` |
| Installer | WiX v5 MSI built from the verified package stage and signed; blocks legacy script installs and inactive Test Signing |
| Driver signing | **Owner accepted: WDK test signature plus persistent Windows Test Signing** |
| Physical unplug/power loss | **Accepted untested residual risk** |

Retained local evidence:

- `artifacts/reproducible-build/proof.json`
- `artifacts/usb-rw/current-package-normal-user-rw-proof.json`
- `artifacts/usb-rw/current-package-mounted-file-actions-proof.json`
- `artifacts/deployment/current-worker-certification.json`
- `artifacts/windows-vm/current-lifecycle-proof.json`
- `artifacts/production/production-readiness.json`

These generated files may contain machine-specific paths and are intentionally not
tracked or published. Public documentation contains capability summaries only.

## Strict Production Blockers

| Boundary | Required closure |
|---|---|
| Windows driver trust | Obtain an EV code-signing certificate and a Microsoft Partner Center hardware account, attestation-sign the dedicated driver, build a production package, and prove the exact package loads with Test Mode disabled |
| Physical fault residual risk | No closure planned with current hardware; keep claim explicitly untested and owner-accepted |

Application and installer signing is done and is no longer a blocker.
Persistent Test Signing and the physical-fault residual are accepted
owner-release constraints. They prevent a production-ready claim but do not
block the owner-controlled Test Mode release.

## Strict Check

Run from clean `main`:

```powershell
.\scripts\verify-production-readiness.ps1
```

Default `Auto` mode selects exact-source production package when available,
otherwise exact-source test package. It reports strict production status and nested
owner status. Strict status remains red for test driver and physical-fault proof.
Owner status accepts documented persistent Test Mode and physical-fault risk when
the exact test package passes every other gate. Both statuses require the staged
product executables to carry a valid, timestamped `CN=Randy Northrup` signature,
so evaluate a package built with `-Sign`.

Explicit test-candidate evaluation requires:

```powershell
.\scripts\verify-production-readiness.ps1 `
  -DriverSigningMode Test -AllowTestSignedDriver
```

Explicit production evaluation uses:

```powershell
.\scripts\verify-production-readiness.ps1 -DriverSigningMode Production
```

Readiness verification performs no install, elevation, VM action, or reboot.

## Evidence Policy

Generated logs and raw verification evidence remain in ignored `artifacts/` or a
private evidence store. They must not enter Git history or release assets. See
`docs/PRIVACY.md`.
