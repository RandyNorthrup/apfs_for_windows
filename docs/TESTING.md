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

`verify-winfsp-runtime-boundary.ps1` validates `dependencies/winfsp.json` (the
pinned official WinFsp release) and confirms no fork submodule remains. CTest
runs against a build configured with the staged official WinFsp SDK (see
[Development](DEVELOPMENT.md#stage-the-winfsp-sdk)); it puts the SDK `bin`
directory on `PATH` for tests that start the worker, so WinFsp does not need to
be installed for CTest.

## Package Gates

```powershell
.\scripts\build-release-package.ps1 -BuildDir build\Release `
  -QtBin C:\Qt\6.10.3\msvc2022_64\bin
.\scripts\verify-release-package.ps1
.\scripts\verify-reproducible-build.ps1
```

Package verification checks clean-source identity, deterministic stage layout,
manifests, SHA-256 values, required runtime files, the absence of WinFsp files
and retired install scripts, build metadata (including the WinFsp version),
signatures when `-RequireSigned` is given, privacy, and PowerShell
compatibility. The reproducibility gate builds twice from separate source paths
and compares binaries, metadata, and the deterministic stage ZIP byte for byte.
The ZIP exists only for that comparison; it is not a release asset.

## Functional Matrix

Automated and hardware-assisted lanes cover:

- APFS core format, read, write, rename, move, delete, and remount;
- nested directories and large existing files;
- WinFsp file, directory, metadata, security, link, xattr, and stream callbacks
  (opening existing hard links; creating new hard links is unsupported with
  official WinFsp and is expected to fail);
- Automatic service discovery, read-only default for new devices, policy
  changes, supervision, and log rotation;
- tray single-instance, Open/Exit, startup, and uninstall behavior;
- read-only denial and protected-volume fail-closed behavior;
- deterministic worker interruption with old-or-new generation acceptance;
- native macOS mutation and `fsck_apfs` interoperability;
- removable APFS media create/read/write/rename/delete and cleanup;
- Windows VM MSI install, restart persistence, tray behavior, and clean
  uninstall.

Local worker and USB lanes need the official WinFsp installed on the test
machine, because the worker loads the WinFsp DLL from the WinFsp installation
directory.

## Windows VM Lanes

`verify-windows-vm-package-lifecycle.ps1` and
`verify-windows-vm-disposable-raw-interruption.ps1` take the exact MSI through
`-PackagePath` (`artifacts\package\APFS-for-Windows-<version>.msi`) and require
the official WinFsp already installed on the VM. They install with `msiexec`,
exercise the product, and uninstall it; system WinFsp must remain installed
afterward. The former native hard-link transport check was removed with the
dedicated fork.

`repair-apfs-for-windows-install.ps1`, `uninstall-apfs-for-windows.ps1`, and
`start-repair-elevated.ps1` remain only as developer and certification deploy
tools. They are not shipped in the package and require the system WinFsp.

## External Systems

VM hosts, users, device serials, passwords, and target identifiers are runtime
inputs. Never commit them or generated raw evidence. Store credentials outside
the repository and pass only an ignored local path to a verification script.

Physical destructive tests must pin the intended removable device at runtime,
verify APFS identity, confirm it is not a boot/system disk, and restore policy
after the test.

## Claim Boundary

Passing local and VM tests does not make the package production-ready.
Physical fault limitations are documented in
[Production Readiness](PRODUCTION_READINESS.md).
