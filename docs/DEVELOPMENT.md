# Development

## Prerequisites

- Windows 11 x64
- Visual Studio 2022 with C++ desktop components
- CMake
- Git
- Qt 6.10.3 MSVC 2022 x64
- PowerShell 5.1 and PowerShell 7 for cross-runtime package checks
- Official WinFsp 2.2 installed system-wide, to run the worker or mount volumes
  locally (not needed just to build)

Clone the repository:

```powershell
git clone https://github.com/RandyNorthrup/apfs_for_windows.git
Set-Location apfs_for_windows
```

The repository has no submodules. The dedicated WinFsp fork used by 0.2.0
(`https://github.com/RandyNorthrup/winfsp-apfs`) is no longer part of the build;
it stays on GitHub for a future upstream hard-link contribution to WinFsp.

## Stage the WinFsp SDK

Builds compile against the official WinFsp SDK pinned in
`dependencies/winfsp.json` (WinFsp 2.2.26323, tag `v2.2`). Stage it with:

```powershell
. .\scripts\lib\winfsp-sdk.ps1
$sdk = Get-ApfsWinFspSdk
```

`Get-ApfsWinFspSdk` works under PowerShell 5.1 and 7, and running it again is
safe. It uses the cache `artifacts\winfsp-sdk` by default (`-CacheRoot` changes
it) and:

1. downloads the pinned `winfsp-2.2.26323.msi` when it is not cached;
2. verifies its SHA-256 and a valid Authenticode signature from NAVIMATICS LLC;
3. admin-extracts the MSI without installing it;
4. stages `artifacts\winfsp-sdk\2.2.26323\inc`, `lib`, and `bin`, plus
   `winfsp-sdk.json` with the version and MSI SHA-256;
5. verifies that `bin\winfsp-x64.sys` carries a valid signature from Microsoft
   Windows Hardware Compatibility Publisher.

It returns an object with `SdkRoot`, `MsiPath`, `Version`, `MsiSha256`,
`IncludeDir`, `LibDir`, and `BinDir`.

## Configure and Build

```powershell
cmake -S . -B build -G "Visual Studio 17 2022" -A x64 `
  -DCMAKE_PREFIX_PATH="C:\Qt\6.10.3\msvc2022_64" `
  -DWinFsp_ROOT="$($sdk.SdkRoot)" `
  -DAPFS_PRODUCTION_BUILD=ON
cmake --build build --config Release --parallel
ctest --test-dir build -C Release --output-on-failure
```

Production-mode builds require a clean checkout, `WinFsp_ROOT` pointing at a
staged SDK whose `winfsp-sdk.json` version equals the version in
`dependencies/winfsp.json`, warnings as errors, deterministic compilation, and
stable source path mapping. The generated `apfs-build-metadata.json` records the
WinFsp version the build used.

`APFS_REQUIRE_NATIVE_HARDLINKS` remains an option but defaults to `OFF`, and
production builds do not turn it on. The official WinFsp headers have no
hard-link creation callback, so the worker builds with
`APFS_WINFSP_NATIVE_HARDLINKS=0`.

The worker links the WinFsp import library with `/DELAYLOAD:winfsp-x64.dll` and
calls `FspLoad` at startup. At run time that loads `winfsp-x64.dll` from the
WinFsp installation directory, so running the worker against a real volume
needs the official WinFsp installed. CTest puts the staged SDK `bin` directory
on `PATH` for tests that start the worker, so CTest does not need WinFsp
installed.

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
  are never committed. The staged WinFsp SDK lives under ignored `artifacts`.
- Repository privacy verification blocks user-profile paths, private network
  addresses, personal email metadata, private keys, and machine-specific proof.
- Changes must keep documentation and tests aligned with behavior.

See [Testing](TESTING.md), [Releasing](RELEASING.md), [Privacy](PRIVACY.md), and
[Contributing](../CONTRIBUTING.md).
