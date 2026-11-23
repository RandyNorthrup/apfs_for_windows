# APFS Write Engine Plan

Status: approved by the owner on 2026-11-22. The engine is built in S.A.K.
Utility (owner decision, 2026-11-22) and imported into this repository when it
is ready, as the current core was. This document records the requirements and
acceptance gates APFS for Windows needs from it; the stages below describe the
work wherever it happens.

## Why a new engine

The current writer (imported from S.A.K.) serializes the whole volume on every
operation:

- every commit walks the entire filesystem, re-reads every file's records
  several times (O(F²) block reads for F files), and rebuilds the FS tree,
  object maps, and extent-reference tree from scratch;
- each Windows operation is its own checkpoint, and creating a file costs two;
- it refuses directories with 1,000 or more entries, nesting deeper than 16,
  case-sensitive volumes, and every volume except the first in a container.

That design suits occasional offline edits. It cannot serve a live drive in
Explorer. Tuning it cannot change its complexity, so it is replaced, not
optimized. The reader, the on-disk encoders, the checksum code, and the
checkpoint writer are reused.

## Targets

| Measure | Target |
|---|---|
| Small-file create (Explorer copy of 10,000 files) | ≥ 200 files/s on SSD, ≥ 50 files/s on USB HDD |
| Sequential write | ≥ 80 % of the device's raw sequential write speed |
| Metadata operation cost | O(log n) block touches; independent of volume size |
| Directory size | no limit below APFS's own |
| Volumes | all non-sealed, non-encrypted volumes in a container; case-sensitive and case-insensitive |
| Durability | every acknowledged flush (`FlushFileBuffers`, eject, unmount, service stop) is on disk; power loss at any instant leaves the last complete checkpoint |
| Correctness | Apple `fsck_apfs` clean and macOS mounts read/write after every test workload |

## Architecture

1. **Container session.** One long-lived session per mounted container: open
   device handle, geometry, newest valid checkpoint, and an LRU block cache
   with dirty tracking. Replaces opening and re-reading the device per call.
2. **Object maps.** Container and volume omap lookups by `(oid, xid)` through
   the B-tree engine, with copy-on-write updates and snapshot-aware versions.
3. **B-tree engine.** Generic APFS B-tree: fixed and variable keys/values,
   table of contents, free-space management, insert/delete/update along one
   leaf-to-root path, split and merge, and physical versus virtual node
   addressing. Key comparators for FS-tree records (inode, drec hashed and
   unhashed, xattr, dstream, file extent, sibling link/map; existing hard links
   must stay consistent even though Windows cannot create new ones with the
   official WinFsp driver), omap keys, and
   extent-reference keys.
4. **Space manager.** In-memory free-extent index built from the chunk
   bitmaps; allocation with locality; incremental bitmap, cib/cab, and
   free-queue maintenance; reuse delayed by the rollback window.
5. **Transaction and checkpoint.** All operations mutate an in-memory
   transaction (dirty nodes, allocations, frees, counters). One checkpoint
   publishes many operations: on a timer (about 5 s), on memory pressure, and
   on every flush, eject, unmount, or shutdown. Write order: all new blocks,
   flush barrier, checkpoint map and superblock, flush barrier.
6. **Filesystem layer.** Inode create/delete, directory entries with correct
   hashing and normalization for both case modes, rename (including replace
   and directory moves), hard-link sibling records, xattrs (inline and
   stream), timestamps, ownership and mode, valence and link counts, volume
   counters.
7. **Data path.** Write-back buffering with delayed allocation, extent merging,
   sparse files, truncate and extend, extent-reference counting for clones, and
   compressed files (read always; rewrite to uncompressed on modify).
8. **Worker integration.** The worker keeps one session per mount, maps WinFsp
   callbacks to filesystem-layer calls with no per-operation reload, and maps
   `Flush`, `Cleanup` of a modified file, eject, and stop to checkpoint
   barriers.

## Stages and gates

| Stage | Scope | Acceptance gate |
|---|---|---|
| 0. Test foundation | Corpus of macOS-created images (sizes, case modes, snapshots, clones, compressed files, many-entry directories, deep trees, multiple volumes) generated on the Mac VMs; `fsck_apfs` and macOS kernel-mount harness; Windows-side workload runner; fault-injection device (drop or tear any write) | Harness runs the current writer's workloads and reports results |
| 1. Session and cache | Container session, block cache, omap lookups through B-tree search | Read results identical to the current reader on the whole corpus; no full-tree reads |
| 2. B-tree engine | Insert/delete/update/split/merge for all tree kinds | Property tests against a reference model (millions of random operations); every resulting tree passes structural validation |
| 3. Space manager and checkpoint | Allocator, bitmaps, free queues, transactional checkpoint with barriers | `fsck_apfs` clean after random allocate/free sequences; fault injection at every write leaves the previous checkpoint mountable |
| 4. Metadata operations | Create, delete, rename, mkdir, rmdir, hard links, xattrs, attributes, both case modes | Differential tests against macOS (same operation sequence on Mac and Windows, then compare trees); `fsck_apfs` clean |
| 5. Data path | Write-back data, extents, sparse, truncate, clones, compressed-file rewrite | Byte-exact content checks; throughput targets met on SSD and USB HDD |
| 6. Worker integration | New engine behind a setting, then default | Explorer workloads (10k-file copy, Office save, zip extract, large video copy) pass; old writer removed |
| 7. Durability campaign | Fault injection at every write of long workloads; physical unplug and power-cut runs on the test PCs | Zero unmountable or `fsck_apfs`-dirty results across the campaign |
| 8. Snapshots and multi-volume | Writes on volumes with Time Machine local snapshots; all volumes in a container | Snapshots remain intact and mountable on macOS |
| 9. Encrypted volumes | FileVault unlock (password or recovery key) and encrypted read/write | Unlock UX in the tray; encrypted round-trip verified on macOS |

Stages 1 to 3 can overlap once stage 0 exists. Nothing reaches users until
stage 6's gate passes; until then the current writer remains, with new devices
mounting read-only by default.

## Risks

- B-tree split and merge with variable-size keys and values.
- Consistency of omap, extent-reference counts (clones), sibling records,
  valence, and volume counters.
- Space-manager accounting across checkpoints, including cib/cab growth.
- Snapshot-aware copy-on-write.
- Write ordering on devices that ignore flushes (USB bridges); mitigated by
  barriers, verified by the physical durability campaign.

## Ownership

The engine lives in this repository. The imported S.A.K. core is a starting
point only; this project's copy diverges and is no longer kept in sync with
S.A.K.
