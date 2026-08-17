# Testing

## Local Gates

Run from repository root:

```powershell
.\scripts\verify-repository-privacy.ps1
.\scripts\verify-repository-hygiene.ps1
.\scripts\verify-sak-source-boundary.ps1 -RequireUpstream:$false
.\scripts\verify-winfsp-runtime-boundary.ps1
.\scripts\verify-license-notices.ps1
.\scripts\verify-release-policy.ps1
.\scripts\verify-release-governance.ps1
ctest --test-dir build -C Release --output-on-failure
```

## Package Gates

```powershell
.\scripts\build-release-package.ps1 `
  -DriverSigningMode Test -AllowTestSignedDriver
.\scripts\verify-release-package.ps1 `
  -DriverSigningMode Test -AllowTestSignedDriver
.\scripts\verify-reproducible-build.ps1
```

Package verification checks clean-source identity, deterministic archive
layout, manifests, SHA-256 values, required runtime files, payload validation,
test-driver signature classification, privacy, and PowerShell compatibility.

## Functional Matrix

Automated and hardware-assisted lanes cover:

- APFS core format, read, write, rename, move, delete, and remount;
- nested directories and large existing files;
- WinFsp file, directory, metadata, security, link, xattr, and stream callbacks;
- Automatic service discovery, policy changes, supervision, and log rotation;
- tray single-instance, Open/Exit, startup, and uninstall behavior;
- read-only denial and protected-volume fail-closed behavior;
- deterministic worker interruption with old-or-new generation acceptance;
- native macOS mutation and `fsck_apfs` interoperability;
- removable APFS media create/read/write/rename/delete and cleanup;
- Windows VM install, restart persistence, tray behavior, and clean uninstall.

## External Systems

VM hosts, users, device serials, passwords, and target identifiers are runtime
inputs. Never commit them or generated raw evidence. Store credentials outside
the repository and pass only an ignored local path to a verification script.

Physical destructive tests must pin the intended removable device at runtime,
verify APFS identity, confirm it is not a boot/system disk, and restore policy
after the test.

## Claim Boundary

Passing local and VM tests does not make the package production-ready. Current
driver trust and physical fault limitations are documented in
[Production Readiness](PRODUCTION_READINESS.md).
