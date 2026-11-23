# Releasing

## Release Model

Releases are public GitHub releases with a signed `Setup.exe` as the primary
install path and a signed MSI for enterprise deployment. The application
binaries and both installers are Authenticode-signed by `CN=Randy Northrup`
through Azure Artifact Signing. The filesystem driver is the official WinFsp
driver, installed system-wide and signed by Microsoft Windows Hardware
Compatibility Publisher, so releases need no Windows Test Mode. Releases must
still never be labeled production-ready while physical fault recovery is
untested. `RELEASE_POLICY.json` (schema 4) records this model, and
`scripts/verify-release-policy.ps1` enforces it.

## WinFsp Dependency

`dependencies/winfsp.json` pins the official WinFsp release:

| Field | Value |
|---|---|
| Version | 2.2.26323 (tag `v2.2`) |
| MSI | `https://github.com/winfsp/winfsp/releases/download/v2.2/winfsp-2.2.26323.msi` |
| MSI SHA-256 | `36CE01F9EEDBBE6842B7FB4BEDC79D7D4F71983E8ACEB6877B46A07B331C7E19` |
| MSI and DLL signer | NAVIMATICS LLC |
| Driver signer | Microsoft Windows Hardware Compatibility Publisher |
| License | GPLv3 with FLOSS exception |

`scripts/lib/winfsp-sdk.ps1` (`Get-ApfsWinFspSdk`) downloads that MSI, checks
the hash and both signatures, and stages the build SDK (see
[Development](DEVELOPMENT.md#stage-the-winfsp-sdk)). The same verified MSI is
chained into `Setup.exe`. `scripts/verify-winfsp-runtime-boundary.ps1` checks
the dependency manifest and that no fork submodule remains. To move to a newer
WinFsp release, update `dependencies/winfsp.json` after verifying the new hash
and signatures yourself.

## Signing

| Setting | Value |
|---|---|
| Service | Azure Artifact Signing (formerly Trusted Signing) |
| Endpoint | `https://wus.codesigning.azure.net/` |
| Account | `scnetsolutions` |
| Certificate profile | `SAKUtility` |
| Publisher | `CN=Randy Northrup` |
| Timestamp | `http://timestamp.acs.microsoft.com` |

`scripts/sign-files.ps1` signs with `signtool` from the Windows SDK and a pinned,
hash-checked `Microsoft.ArtifactSigning.Client` dlib. It authenticates through
the Azure CLI session: `az login` on a workstation, or `azure/login` in CI. It
skips files that already carry another publisher's valid signature, such as the
Microsoft-signed Visual C++ runtime. It refuses `*.sys` files, because Artifact
Signing certificates are not trusted for kernel-mode code. After signing, it
checks each file for a valid, timestamped signature from the expected publisher.

`build-release-package.ps1 -Sign` signs the staged executables, and any Qt DLL
or plugin that is not already signed, before any hash or manifest is computed.
The stage contains no WinFsp files. Official Qt binaries arrive signed by The Qt
Company and keep that signature. `verify-release-package.ps1 -RequireSigned`
requires `CN=Randy Northrup` on the project binaries and accepts either
publisher on Qt files, always with a valid timestamp. The release manifest then
records `application_signing` and `package_signing` as
`azure_artifact_signing`. Unsigned development builds record
`unsigned_development_build` and are never owner release candidates.

`build-msi.ps1 -Sign` signs the MSI and the `Setup.exe` bundle. The chained
WinFsp MSI keeps its NAVIMATICS LLC signature.

### GitHub OIDC Setup

CI signs without stored credentials, through GitHub OIDC workload identity
federation:

- The `release` GitHub environment holds the secrets `AZURE_CLIENT_ID`,
  `AZURE_TENANT_ID`, and `AZURE_SUBSCRIPTION_ID`. Its deployment rules allow
  tags matching `apfs-for-windows-v*` and the `main` branch.
- The Entra app registration `APFS-for-Windows-GitHub-Signing` has a
  federated credential for the subject GitHub actually presents, which carries
  immutable owner and repository IDs:
  `repo:RandyNorthrup@122551425/apfs_for_windows@1336201140:environment:release`
  (a second credential keeps the legacy
  `repo:RandyNorthrup/apfs_for_windows:environment:release` form). The app
  holds the Artifact Signing Certificate Profile Signer role on the
  `SAKUtility` certificate profile only. If a login fails with AADSTS700213,
  compare the subject in the error with these credentials.
- The release job declares `environment: release` and `id-token: write`.

## Automated GitHub Build

`.github/workflows/release.yml` builds on `windows-2022` in the `release`
environment and:

1. checks out sanitized `main`;
2. runs repository privacy, hygiene, WinFsp dependency, license, policy, and
   governance gates;
3. installs the pinned Qt toolchain;
4. stages the official WinFsp SDK with `scripts/lib/winfsp-sdk.ps1`, which
   verifies the pinned MSI hash, the NAVIMATICS LLC signature, and the
   Microsoft-signed driver;
5. builds APFS for Windows in deterministic production-build mode with
   `-DWinFsp_ROOT=<staged SDK>`;
6. runs CTest with the staged SDK `bin` on `PATH`;
7. installs WiX Toolset 5.0.2 and its extensions;
8. signs in to Azure with OIDC (`azure/login`, pinned to a commit SHA);
9. builds the signed package stage with `-Sign` and verifies it under
   PowerShell 7 and 5.1 with `-RequireSigned`;
10. scans the staged package for private machine data;
11. builds and signs the MSI and `Setup.exe` with
    `scripts/build-msi.ps1 -Sign -WinFspMsi <pinned WinFsp MSI>`;
12. writes `SHA256SUMS.txt` for `Setup.exe` and the MSI;
13. uploads the installers, checksums, and proofs as workflow artifacts;
14. creates the latest public release when the workflow runs from the matching
    version tag.

`.github/workflows/repository-gates.yml` runs on every push and pull request.
It builds nothing and needs no signing secrets. The former
`winfsp-runtime-build.yml` workflow, which built the dedicated driver, has been
removed.

## Local Signed Build

On a workstation with the Windows SDK, WiX 5.0.2, and an Azure CLI session that
holds the signer role:

```powershell
az login
. .\scripts\lib\winfsp-sdk.ps1
$sdk = Get-ApfsWinFspSdk
cmake -S . -B build -G "Visual Studio 17 2022" -A x64 `
  -DCMAKE_PREFIX_PATH="C:\Qt\6.10.3\msvc2022_64" `
  -DWinFsp_ROOT="$($sdk.SdkRoot)" -DAPFS_PRODUCTION_BUILD=ON
cmake --build build --config Release --parallel
ctest --test-dir build -C Release --output-on-failure
.\scripts\build-release-package.ps1 -BuildDir build\Release `
  -QtBin C:\Qt\6.10.3\msvc2022_64\bin -Sign
.\scripts\verify-release-package.ps1 -RequireSigned
.\scripts\build-msi.ps1 -Sign -WinFspMsi $sdk.MsiPath
```

Outputs land in `artifacts\package`: the stage `APFS-for-Windows-<version>`,
`APFS-for-Windows-<version>.msi`, and `APFS-for-Windows-<version>-Setup.exe`.
The stage name no longer has a `-test-signed` suffix. The
`-DriverSigningMode`, `-AllowTestSignedDriver`, and `-WinFspArtifactRoot`
parameters were removed.

Without `-Sign`, the same steps produce an unsigned development build for
testing. `verify-release-package.ps1` accepts it without `-RequireSigned`.

## Version and Tag

`VERSION` is the single package version source. Release tag must be:

```text
apfs-for-windows-v<VERSION>
```

For version `0.2.1`, use tag `apfs-for-windows-v0.2.1`. The workflow rejects
mismatched or product-ambiguous tags and requires `docs/releases/<VERSION>.md`.

## Release Checklist

1. Confirm `main` is clean and the only branch.
2. Confirm repository privacy gate passes.
3. Confirm required GitHub checks pass on `main`.
4. Update `VERSION` and `docs/releases/<version>.md` when needed.
5. Run the release workflow manually once and inspect its artifact. Confirm
   `Setup.exe`, the MSI, and the binaries show a valid `CN=Randy Northrup`
   signature.
6. Create and push the matching annotated tag.
7. Verify GitHub release is published and marked Latest.
8. Download the published `Setup.exe` and MSI, compare SHA-256 with
   `SHA256SUMS.txt`, and check both signatures.

## Assets

The public release publishes:

- `APFS-for-Windows-<version>-Setup.exe`: the signed setup bundle, which
  installs official WinFsp when it is missing and then the MSI;
- `APFS-for-Windows-<version>.msi`: the signed MSI for enterprise deployment
  (deploy the official WinFsp MSI first);
- `SHA256SUMS.txt`: SHA-256 values for `Setup.exe` and the MSI.

There is no ZIP release asset and no script-based install in the shipped
package. A deterministic ZIP of the package stage is still built so the
reproducibility gate can compare two builds byte for byte. Detailed package
proof remains available in the GitHub Actions workflow artifact for release
auditing; it is not a public release asset.

Build metadata contains logical dependency names, not developer filesystem
paths.

## Prohibited Release Content

Never publish credentials, VM connection data, local user-profile paths, LAN
addresses, device serials, raw hardware evidence, private email addresses, or
kernel binaries of any kind. WinFsp reaches users only through its unmodified,
officially signed MSI.
