# Releasing

## Release Model

Releases are public GitHub prereleases containing an unsigned application
package and WDK test-signed filesystem driver. They require persistent Windows
Test Signing and must never be labeled production-ready.

## Automated GitHub Build

`.github/workflows/release.yml` builds on `windows-2022` and:

1. checks out sanitized `main` with submodules;
2. runs repository privacy and governance gates;
3. installs the pinned Qt toolchain;
4. builds the dedicated WinFsp driver/runtime and exports its test certificate;
5. builds APFS for Windows in deterministic production-build mode;
6. runs CTest;
7. builds and verifies the test-signed ZIP;
8. scans the staged package for private machine data;
9. uploads the verified package and proof as workflow artifacts;
10. creates a prerelease when the workflow runs from the matching version tag.

## Version and Tag

`VERSION` is the single package version source. Release tag must be:

```text
v<VERSION>
```

For version `0.1.0`, use tag `v0.1.0`. The workflow rejects mismatched tags.

## Pre-Release Checklist

1. Confirm `main` is clean and the only branch.
2. Confirm repository privacy gate passes.
3. Confirm required GitHub checks pass on `main`.
4. Update `VERSION` and `docs/releases/<version>.md` when needed.
5. Run the release workflow manually once and inspect its artifact.
6. Create and push the matching annotated tag.
7. Verify GitHub release is marked prerelease.
8. Download the published ZIP, compare SHA-256, and run package verification.

## Assets

The public release publishes:

- `APFS-for-Windows-<version>-test-signed.zip`;
- `SHA256SUMS.txt`.

Detailed package proof remains available in the GitHub Actions workflow artifact
for release auditing; it is not a public release asset.

The ZIP contains install, repair, uninstall, and Test Signing helpers plus exact
source/runtime manifests. Build metadata contains logical dependency names, not
developer filesystem paths.

## Prohibited Release Content

Never publish credentials, VM connection data, local user-profile paths, LAN
addresses, device serials, raw hardware evidence, private email addresses, or
unsigned kernel binaries.
