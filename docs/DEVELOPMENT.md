# Development

## Prerequisites

- Windows 11 x64
- Visual Studio 2022 with C++ desktop and WDK components
- CMake
- Git with submodule support
- Qt 6.10.3 MSVC 2022 x64
- PowerShell 5.1 and PowerShell 7 for cross-runtime package checks

Clone with submodules:

```powershell
git clone --recurse-submodules https://github.com/RandyNorthrup/apfs_for_windows.git
Set-Location apfs_for_windows
```

## Configure and Build

```powershell
cmake -S . -B build -G "Visual Studio 17 2022" -A x64 `
  -DCMAKE_PREFIX_PATH="<qt-root>\6.10.3\msvc2022_64" `
  -DWinFsp_ROOT="<repository-root>\third_party\winfsp" `
  -DAPFS_PRODUCTION_BUILD=ON
cmake --build build --config Release --parallel
ctest --test-dir build -C Release --output-on-failure
```

Production-mode builds require a clean checkout, the pinned dedicated WinFsp
submodule, native hard-link ABI, warnings as errors, deterministic compilation,
and stable source path mapping.

## Imported APFS Source Boundary

The APFS reader/writer is copied into `third_party/sak_apfs_core`. Never edit an
external S.A.K. checkout from this repository. Make project-specific changes only
to the copied files.

Import verification resolves the source checkout in this order:

1. explicit `-UpstreamRoot` argument;
2. `SAK_SOURCE_ROOT` environment variable;
3. sibling `..\S.A.K.-Utility` checkout.

Verify without requiring an external checkout:

```powershell
.\scripts\verify-sak-source-boundary.ps1 -RequireUpstream:$false
```

## Repository Rules

- `main` is the only branch retained in this repository.
- Generated `build*`, `artifacts`, `temp`, credentials, keys, and editor state
  are never committed.
- Repository privacy verification blocks user-profile paths, private network
  addresses, personal email metadata, private keys, and machine-specific proof.
- Changes must keep documentation and tests aligned with behavior.

See [Testing](TESTING.md), [Releasing](RELEASING.md), [Privacy](PRIVACY.md), and
[Contributing](../CONTRIBUTING.md).
