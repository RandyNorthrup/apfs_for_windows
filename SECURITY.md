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

Vulnerabilities in WinFsp itself (its kernel driver, DLL, launcher, or
installer) belong to the upstream project. Report them to
[winfsp/winfsp](https://github.com/winfsp/winfsp) following its security
policy. If you are unsure which project is affected, report here privately and
it will be forwarded.

## Release boundary

`Setup.exe`, the MSI installer, and the application binaries are
Authenticode-signed by `CN=Randy Northrup` through Azure Artifact Signing under
`RELEASE_POLICY.json`. Verify the signature before installing; a missing or
different publisher means the file did not come from this project. Signing
confirms the publisher, not Smart App Control reputation. SHA-256 manifests
remain as integrity evidence.

The kernel driver is the official WinFsp driver, installed system-wide from the
pinned WinFsp release in `dependencies/winfsp.json`. Its driver is signed by
Microsoft Windows Hardware Compatibility Publisher and its MSI and DLL by
NAVIMATICS LLC. The release process verifies the pinned MSI hash and both
signatures. No part of the product requires or automates Windows Test Mode, and
no installer or script changes Secure Boot, BitLocker, Memory Integrity/HVCI,
kernel debugging, or `nointegritychecks`, or restarts Windows.

Physical surprise-unplug and power-loss recovery are explicitly untested
owner-accepted risks and must never be represented as tested. The project must
not be represented as production-ready. Exact-package evidence remains
mandatory.
