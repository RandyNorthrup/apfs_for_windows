# Contributing

## Source boundaries

- Make all project changes inside this repository.
- Keep one owned-repository branch: `main`. Use forks for external pull requests.
- Never edit `C:\Users\Randy\Coding\S.A.K.-Utility` from this project.
- Import APFS core changes through
  `scripts/update-sak-import-manifest.ps1`, then review the local fork diff.
- Do not commit `build*`, `artifacts`, `temp`, credentials, keys, certificates,
  binaries, VM state, or physical-media captures.

## Required checks

Run from PowerShell 5.1 or newer:

```powershell
.\scripts\verify-repository-hygiene.ps1
.\scripts\verify-sak-source-boundary.ps1
.\scripts\verify-license-notices.ps1
cmake --build build --config Release --parallel
ctest --test-dir build -C Release --output-on-failure
```

Filesystem behavior changes require focused image tests. Raw-media behavior
changes require serial-pinned removable-media evidence and restoration to
read-only state. VM or host reboot tests are never implied by normal checks.

## Change quality

- Keep commits focused and reviewable.
- Add tests for new behavior and failure paths.
- Preserve third-party license notices.
- Update `README.md`, architecture, and production-readiness docs when behavior,
  dependencies, or certification status changes.
- Do not describe a build as production-ready while any strict readiness gate
  remains open.
