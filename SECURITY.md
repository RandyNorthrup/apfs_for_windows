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

Application and package binaries intentionally remain unsigned under
`RELEASE_POLICY.json`; SHA-256 manifests and deterministic archives provide
integrity evidence, not publisher identity or Smart App Control reputation.
The owner distribution uses a WDK test-signed kernel driver and persistent Windows
Test Signing. Production driver signing is not planned, so this configuration must
never be represented as production-ready. `configure-test-signing.ps1` may only
set or clear BCDEdit's `testsigning` element; it never changes Secure Boot,
BitLocker, Memory Integrity/HVCI, kernel debugging, or `nointegritychecks` and never
restarts Windows. Physical surprise-unplug and power-loss recovery are explicitly
untested owner-accepted risks and must never be represented as tested. Exact-package
evidence remains mandatory.
