# Releasing

## Release Model

Releases are public GitHub releases with a signed MSI installer as the primary
install path. The application binaries and the MSI are Authenticode-signed by
`CN=Randy Northrup` through Azure Artifact Signing. The filesystem driver stays
WDK test-signed, so releases require persistent Windows Test Signing and must
never be labeled production-ready. `RELEASE_POLICY.json` (schema 3) records
this model, and `scripts/verify-release-policy.ps1` enforces it.

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

`build-release-package.ps1 -Sign` signs the staged executables and
`winfsp-x64.dll`, and any Qt DLL or plugin that is not already signed, before any
hash or manifest is computed. Official Qt binaries arrive signed by The Qt
Company and keep that signature. `verify-release-package.ps1 -RequireSigned`
requires `CN=Randy Northrup` on the project binaries and accepts either
publisher on Qt files, always with a valid timestamp. The release manifest then
records `application_signing` and `package_signing` as
`azure_artifact_signing`. Unsigned development builds record
`unsigned_development_build` and are never owner release candidates.

### GitHub OIDC Setup

CI signs without stored credentials, through GitHub OIDC workload identity
federation:

- The `release` GitHub environment holds the secrets `AZURE_CLIENT_ID`,
  `AZURE_TENANT_ID`, and `AZURE_SUBSCRIPTION_ID`. Its deployment rules allow
  tags matching `apfs-for-windows-v*` and the `main` branch.
- The Entra app registration has a federated credential with subject
  `repo:RandyNorthrup/apfs_for_windows:environment:release`, and the app holds
  the certificate profile signer role on the Artifact Signing account.
- The release job declares `environment: release` and `id-token: write`.

## Automated GitHub Build

`.github/workflows/release.yml` builds on `windows-2022` in the `release`
environment and:

1. checks out sanitized `main` with submodules;
2. runs repository privacy, hygiene, policy, and governance gates;
3. installs the pinned Qt toolchain;
4. builds the dedicated WinFsp driver/runtime and exports its test certificate;
5. builds APFS for Windows in deterministic production-build mode;
6. runs CTest;
7. installs WiX Toolset 5.0.2 and its Util and UI extensions;
8. signs in to Azure with OIDC (`azure/login`, pinned to a commit SHA);
9. builds the signed test-signed package with `-Sign` and verifies it under
   PowerShell 7 and 5.1 with `-RequireSigned`;
10. scans the staged package for private machine data;
11. builds the MSI with `scripts/build-msi.ps1 -DriverSigningMode Test`, signs
    it with `scripts/sign-files.ps1`, and checks its signature;
12. writes `SHA256SUMS.txt` for the MSI and ZIP;
13. uploads the MSI, ZIP, checksums, and proofs as workflow artifacts;
14. creates the latest public release when the workflow runs from the matching
    version tag.

`.github/workflows/repository-gates.yml` runs on every push and pull request.
It builds nothing and needs no signing secrets.

## Local Signed Build

On a workstation with the Windows SDK, WiX 5.0.2, and an Azure CLI session that
holds the signer role:

```powershell
az login
.\scripts\build-release-package.ps1 -DriverSigningMode Test -AllowTestSignedDriver -Sign
.\scripts\verify-release-package.ps1 -DriverSigningMode Test -AllowTestSignedDriver -RequireSigned
.\scripts\build-msi.ps1 -DriverSigningMode Test
.\scripts\sign-files.ps1 -Path artifacts\package\APFS-for-Windows-<version>-test-signed.msi
```

Without `-Sign`, the same steps produce an unsigned development build for
testing. `verify-release-package.ps1` accepts it without `-RequireSigned`.

## Version and Tag

`VERSION` is the single package version source. Release tag must be:

```text
apfs-for-windows-v<VERSION>
```

For version `0.2.0`, use tag `apfs-for-windows-v0.2.0`. The workflow rejects
mismatched or product-ambiguous tags and requires `docs/releases/<VERSION>.md`.

## Release Checklist

1. Confirm `main` is clean and the only branch.
2. Confirm repository privacy gate passes.
3. Confirm required GitHub checks pass on `main`.
4. Update `VERSION` and `docs/releases/<version>.md` when needed.
5. Run the release workflow manually once and inspect its artifact. Confirm the
   MSI and binaries show a valid `CN=Randy Northrup` signature.
6. Create and push the matching annotated tag.
7. Verify GitHub release is published and marked Latest.
8. Download the published MSI and ZIP, compare SHA-256, check the MSI signature,
   and run package verification with `-RequireSigned`.

## Assets

The public release publishes:

- `APFS-for-Windows-<version>-test-signed.msi`: the signed installer;
- `APFS-for-Windows-<version>-test-signed.zip`: the signed package stage, with
  the Test Signing helper, script installers, and exact source/runtime
  manifests;
- `SHA256SUMS.txt`: SHA-256 values for the MSI and ZIP.

Detailed package proof remains available in the GitHub Actions workflow artifact
for release auditing; it is not a public release asset.

Build metadata contains logical dependency names, not developer filesystem
paths.

## Prohibited Release Content

Never publish credentials, VM connection data, local user-profile paths, LAN
addresses, device serials, raw hardware evidence, private email addresses, or
unsigned kernel binaries.
