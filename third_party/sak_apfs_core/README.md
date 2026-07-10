# APFS Core Local Fork

This directory contains the APFS reader/writer core copied into APFS for Windows.
It is a local fork inside this repository, not a place to edit the source
checkout directly.

Source boundary:

- Source checkout: `C:\Users\Randy\Coding\S.A.K.-Utility`
- Source checkout stays read-only for this project.
- Edits for APFS for Windows happen only in this copied tree or other files in
  this repository.
- Current source commit recorded for provenance:
  `2f1d9844fabb3e6e8190f906e5cf4906e5e5f281`

Local APFS for Windows deltas after import:

- Added parent-path routing to image-only file write/delete/rename wrappers.
- Added directory rename/move commit wrappers for image and raw targets.
- Added parent-aware directory delete routing.
- Removed copied source license tags and source-app branding from code comments
  and messages per project-owner direction.
- Kept the copied API namespace and include paths stable for build compatibility.

Imported source groups:

- `include/sak/apfs_*.h`
- `include/sak/partition_*.h`
- `src/core/apfs_*.cpp`
- `src/core/partition_*.cpp`

Diff policy:

- Re-import deliberately from a known source commit when needed.
- Keep APFS for Windows changes in this repository only.
- Run `scripts\verify-sak-source-boundary.ps1` before release/certification.
