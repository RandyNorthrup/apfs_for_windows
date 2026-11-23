# Security Policy

## Supported versions

Security fixes target the current `main` branch until the project publishes a
stable release series.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use the repository's
private GitHub Security Advisory reporting flow and include:

- affected version or commit;
- reproduction steps and required privileges;
- expected and observed behavior;
- impact on APFS media, Windows host integrity, or privilege boundaries;
- any proof files with secrets and personal data removed.

Reports involving raw-device writes, service IPC, installer elevation, path
containment, parser memory safety, or crafted APFS metadata receive priority.

## Release boundary

Application binaries and the MSI installer are Authenticode-signed by
`CN=Randy Northrup` through Azure Artifact Signing under `RELEASE_POLICY.json`.
Verify the signature before installing; a missing or different publisher means
the file did not come from this project. Signing confirms the publisher, not
Smart App Control reputation. SHA-256 manifests remain as integrity evidence.
The owner distribution uses a WDK test-signed kernel driver and persistent Windows
Test Signing. Production driver signing needs an EV certificate and Partner
Center attestation, which the project does not have, so this configuration must
never be represented as production-ready. `configure-test-signing.ps1` may only
set or clear BCDEdit's `testsigning` element; it never changes Secure Boot,
BitLocker, Memory Integrity/HVCI, kernel debugging, or `nointegritychecks` and never
restarts Windows. Physical surprise-unplug and power-loss recovery are explicitly
untested owner-accepted risks and must never be represented as tested. Exact-package
evidence remains mandatory.
