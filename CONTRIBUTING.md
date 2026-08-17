# Contributing

## Source boundaries

- Make all project changes inside this repository.
- Keep one owned-repository branch: `main`. External pull requests must not add
  branches to owned repositories.
- Never edit an external S.A.K. checkout from this project.
- Import APFS core changes through
  `scripts/update-sak-import-manifest.ps1`, then review the local-copy diff.
- Do not commit `build*`, `artifacts`, `temp`, credentials, keys, certificates,
  binaries, VM state, or physical-media captures.

## Required checks

Run from PowerShell 5.1 or newer:

```powershell
.\scripts\verify-repository-hygiene.ps1
.\scripts\verify-repository-privacy.ps1
.\scripts\verify-sak-source-boundary.ps1 -RequireUpstream:$false
.\scripts\verify-winfsp-runtime-boundary.ps1
.\scripts\verify-license-notices.ps1
.\scripts\verify-release-policy.ps1
.\scripts\verify-release-governance.ps1
cmake --build build --config Release --parallel
ctest --test-dir build -C Release --output-on-failure
.\scripts\verify-apfs-protected-volume-policy.ps1
```

Filesystem behavior changes require focused image tests. Raw-media behavior
changes require serial-pinned removable-media evidence and restoration to
read-only state. VM or host reboot tests are never implied by normal checks.

## Change quality

- Keep commits focused and reviewable.
- Add tests for new behavior and failure paths.
- Preserve third-party license notices.
- Keep user instructions in `README.md`, installation details in
  `docs/INSTALLATION.md`, maintainer procedures in `docs/DEVELOPMENT.md` and
  `docs/TESTING.md`, and claim boundaries in `docs/PRODUCTION_READINESS.md`.
- Never commit local paths, personal email metadata, private network details,
  credentials, device identifiers, or raw machine evidence.
- Do not describe a build as production-ready. Current owner policy disables that
  public claim, intentionally omits app/package signing, and accepts physical fault
  testing as an unverified residual risk. Never imply kernel-driver trust is waived.
