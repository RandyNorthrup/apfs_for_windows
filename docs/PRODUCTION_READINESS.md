# Production Readiness

Status date: 2026-11-22

Current classification: **owner-controlled signed release; not production-ready**.

Application binaries (service, worker, manager, and probe), the MSI, and the
`Setup.exe` bundle are Authenticode-signed by `CN=Randy Northrup` with Azure
Artifact Signing and an RFC 3161 timestamp. Bundled Qt and Visual C++ runtime
files keep their original Qt Company and Microsoft signatures. Release CI
refuses to publish unless every project binary has a valid, timestamped
signature from that publisher, and every Qt file a valid, timestamped signature
from either publisher. Payload manifests and SHA-256 hashes remain as integrity evidence.
Signing establishes publisher identity; it does not guarantee Smart App Control
or SmartScreen reputation.

Kernel driver trust is closed by using the official WinFsp release installed
system-wide (pinned in `dependencies/winfsp.json`: WinFsp 2.2.26323). Its driver
is signed by Microsoft Windows Hardware Compatibility Publisher and its MSI and
DLL by NAVIMATICS LLC. Windows Test Mode is not required and Secure Boot stays
compatible. The product does not automate Secure Boot, BitLocker, Memory
Integrity/HVCI, kernel debugging, or integrity-bypass changes. The trade-off is
that creating new hard links from Windows is unsupported with official WinFsp
(`native_hard_link_creation: unsupported_with_official_winfsp`); existing APFS
hard links still open.

Physical surprise-unplug and power-loss recovery are not part of the verified
release evidence. They remain explicit owner-accepted, untested residual risks.
Synthetic worker-termination and raw-VHD interruption tests reduce risk but are not
represented as physical proof. `RELEASE_POLICY.json` (schema 4) records these
boundaries.

Known functional limits: write throughput is low for many small files, and
directories with 1000 or more entries are not writable from Windows. Both remain
until the planned new write engine lands.

## Current Candidate

Canonical generated identity is in the packaged `release-manifest.json` and
`artifacts/package/package-proof.json`. Documentation intentionally avoids copying
mutable candidate hashes.

Rows marked *needs fresh evidence* were last proven on the 0.2.0 test-signed
package and must be rerun against the exact 0.2.1 MSI before an owner release.

| Gate | Current result |
|---|---|
| Source isolation | Imported APFS manifest is pinned; S.A.K. checkout remains read-only |
| WinFsp dependency | Official WinFsp 2.2.26323 pinned by version, MSI URL, SHA-256, and signers; no fork submodule |
| Local build | Clean production-mode configuration against the staged official SDK, deterministic compiler settings, `/W4 /WX` |
| Tests | CTest with the staged SDK `bin` on `PATH` |
| Package | Deterministic signed stage without WinFsp files; PowerShell 5.1 and 7 verification |
| Reproducibility | Two detached source paths, two CTest passes, byte-identical binaries, metadata, and stage ZIP |
| Physical APFS USB | *Needs fresh evidence.* 0.2.0 package worker passed normal-user create/read/rename/write/delete, Unicode, long path, Robocopy, concurrent reads, metadata, ACL, symlink, file/directory/root EA, and cleanup |
| Windows 11 lifecycle | *Needs fresh evidence.* `verify-windows-vm-package-lifecycle.ps1` now installs the exact MSI on a VM with official WinFsp preinstalled; readiness requires its proof to match the MSI SHA-256 |
| Uninstall residue | *Needs fresh evidence.* Service, mount, manager, startup entry, registry, Start menu, install root, ProgramData, and the legacy `WinFsp+apfs-main` driver absent; system WinFsp retained |
| Protected APFS policy | Writable sealed, FileVault, per-file-key, unknown-policy, filesystem-owned-xattr, and content-critical-xattr paths fail closed |
| Plug-in policy | Newly discovered supported APFS media receives a free drive letter and read-only policy; users switch read/write per volume; explicit saved policy is preserved |
| Repository governance | Sanitized `main` only; privacy and repository gates; admin enforcement; linear history; force-push and deletion disabled |
| App/package signing | Azure Artifact Signing (`CN=Randy Northrup`), timestamped; enforced by `verify-release-package.ps1 -RequireSigned` and `verify-production-readiness.ps1` |
| Installer | Signed WiX v5 MSI built from the verified stage, plus a signed Burn `Setup.exe` that chains the official WinFsp MSI; removes the legacy test-signed driver on upgrade |
| Driver signing | Official WinFsp driver, Microsoft-signed; no Test Mode |
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
| Physical fault residual risk | No closure planned with current hardware; keep claim explicitly untested and owner-accepted |

The former Windows driver trust blocker (WDK test signature plus persistent
Test Signing) is closed by the move to official WinFsp. Application and
installer signing is done. The physical-fault residual is an accepted
owner-release constraint. It prevents a production-ready claim but does not
block the owner-controlled release.

## Strict Check

Run from clean `main`:

```powershell
.\scripts\verify-production-readiness.ps1
```

It reports strict production status and nested owner status. Strict status
remains red while physical-fault proof is missing. Owner status
(`owner_release_ready_with_accepted_physical_fault_risk`) accepts the documented
physical-fault risk when the exact package passes every other gate, including
lifecycle evidence that matches the MSI SHA-256. Both statuses require the staged
product executables to carry a valid, timestamped `CN=Randy Northrup` signature,
so evaluate a package built with `-Sign`. The former `-DriverSigningMode` and
`-AllowTestSignedDriver` parameters are gone.

Readiness verification performs no install, elevation, VM action, or reboot.

## Evidence Policy

Generated logs and raw verification evidence remain in ignored `artifacts/` or a
private evidence store. They must not enter Git history or release assets. See
`docs/PRIVACY.md`.
