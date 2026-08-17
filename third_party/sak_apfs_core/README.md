# APFS Core Local Fork

This directory contains the APFS reader/writer core copied into APFS for Windows.
It is a local fork inside this repository, not a place to edit the source
checkout directly.

Source boundary:

- Source checkout: `C:\Users\Randy\Coding\S.A.K.-Utility`
- Source checkout stays read-only for this project.
- Edits for APFS for Windows happen only in this copied tree or other files in
  this repository.
- Imported source commit recorded for provenance:
  `5587736df4d27e0eb5ca6e9f60f3c69614023b13`

Local APFS for Windows deltas after import:

- Preserved parent-path routing for image and raw file/directory operations.
- Added arbitrary-depth hard-link source/destination routing, collision rejection,
  and third-or-later sibling preservation.
- Added copied-reader debug metadata output for one APFS path so APFS for
  Windows can inspect inode, xattr, decmpfs, resource-fork, and extent state
  without modifying the source checkout.
- Merged the source commit's APFS authentication, allocation, resize, snapshot,
  sparse-file, resource-fork, special-inode, and containment fixes.
- Removed copied source license tags and source-app branding from code comments
  and messages per project-owner direction.
- Kept the copied API namespace and include paths stable for build compatibility.

Imported source groups:

- `include/sak/apfs_*.h`
- `include/sak/partition_*.h`
- `src/core/apfs_*.cpp`
- `src/core/partition_*.cpp`

The import currently contains 20 source files, including
`include/sak/partition_export_containment.h` added by the recorded source commit.

Diff policy:

- Re-import deliberately from a known source commit when needed.
- Keep APFS for Windows changes in this repository only.
- Run `scripts\verify-sak-source-boundary.ps1` before release/certification.
