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

Development builds are not production releases. A production release must pass
`scripts/verify-production-readiness.ps1`, use signed binaries and driver
components, and carry evidence tied to the exact package hash.
