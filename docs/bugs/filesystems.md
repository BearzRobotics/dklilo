# Filesystem reader bugs (`deps/fsread`)

The loaders are built `ReleaseSmall`, so safety checks are off (see BLD-01). A "panic" in the Debug reproductions is undefined behaviour or memory corruption in a shipped loader.

## FS-01: ext4 sparse files are read wrongly, with no error
**Severity:** Critical · **Status:** Fixed (reproduced first)

`ext4.zig:459-481`. When a leaf has no later extent, the hole is taken to last "forever". The next extent may be in the next leaf, so the rest of the read is filled with zeros.

**Reproduction:** `poc-extent-leaf-hole`, a 600-extent sparse file made by `mkfs.ext4 -b 1024`. `e2fsck` is clean and `debugfs` matches the source. dklilo returned the full length, wrong from byte 254976. That is logical block 249, exactly where `debugfs dump_extents` shows the second leaf starting.

**Fix (applied):** `mapExtents` carries the upper bound from the parent index entries (the next sibling's first block) down the tree and ends the hole there. A block at or past 2^32 is now `error.Corrupt`. The text above describes release 0.0.4.

**Regression tests:** `ext4: holes at the end of an extent-tree leaf don't hide later data` (new `ext4-holes.img` fixture, depth-2 tree, read whole and in pieces) and `ext4: a block past the 32-bit extent range is corrupt, not an endless hole`. On the old reader the first was wrong from byte 254976 and the second looped forever.

## FS-02: btrfs decompression cache returns another file's data
**Severity:** Critical · **Status:** Fixed (reproduced first)

`btrfs.zig:778-786,871-916`. Inline extents decompress into `ram_buf` without clearing `cache_extent`. A later read of the cached extent gets the inline file's bytes.

**Reproduction:** `poc-btrfs-cache` on a `mkfs.btrfs --compress zstd` image: read big file, read small inline file, read big file again; the third read returned the small file's text. Because BIOS loading interleaves reads of several files, kernel or initramfs data could be corrupted.

**Fix (applied):** `decompress` itself invalidates the cache before writing into `ram_buf`. The text above describes release 0.0.4.

**Regression test:** `btrfs: reading an inline file doesn't disturb the cached extent` (zlib, LZO and zstd fixtures). It failed before the fix. It is skipped, like the other btrfs tests, where `mkfs.btrfs` is missing.

## FS-03: ext4 descriptor size overflows a 64-byte stack buffer
**Severity:** Critical · **Status:** Fixed (reproduced first)

`ext4.zig:317-318,373-374`. `s_desc_size` may be anything from 64 up to the block size, but `readGroupDesc` reads that many bytes into `[64]u8`. In a shipped loader, disk-controlled bytes overwrite the stack: a route to code execution from any filesystem the loader probes. A crafted image can leave `metadata_csum` off.

**Reproduction:** `poc-ext4-descsize`: `index out of bounds: index 128, len 64`.

**Fix (applied):** only the first 64 bytes of a descriptor are kept; the rest is read in pieces for the checksum. The text above describes release 0.0.4.

**Also found while fixing:** this was not limited to damaged volumes. A valid filesystem made by `mke2fs -E desc_size=128` crashed the old reader the same way.

**Regression tests:** `ext4: 128-byte group descriptors are read, and checksummed whole` (new `ext4-desc128.img`, several block groups, `metadata_csum`) and `ext4: a descriptor size larger than the descriptor doesn't overflow`. Both panicked on the old reader.

## FS-04: Unchecked arithmetic on on-disk values (64-bit)
**Severity:** High · **Status:** Fixed (reproduced first, including the items first found by review)

- FAT BPB: `fat.zig:84`, `nfats * fat_size` overflows `u32` (`poc-fat-bpb-overflow`). FAT is the last probe for any unrecognised volume.
- ext4 inode table: `ext4.zig:393`, `table * block_size` (`poc-ext4-table-overflow`).

Code review only: leaf extent physical blocks are not checked against `blocks_count` (`ext4.zig:476,575`); `dir.size + bs - 1` (638); btrfs `c.logical + c.length` and `s.offset + ...` (410,417), and `file_off + num_bytes`, `disk_bytenr + ext_off + within` (807,820).

**Fix (applied):** all the items above now return `error.Corrupt` (`error.BadMagic` for the FAT boot sector). ext4 rejects a block count whose byte size overflows, checks the inode table block and the whole of each leaf extent against `blocks_count` (and refuses block 0), and refuses a directory bigger than the filesystem. btrfs uses subtraction or checked addition for chunk, stripe and extent values. The line numbers above describe release 0.0.4.

**Regression tests:** in `src/common/tests.zig`: the ext4 tests for the inode table, block count, extent range and directory size; the btrfs tests for extent length, extent address, compressed-extent offset and chunk addresses; and `fat: a boot sector whose sizes overflow is rejected`. On the old readers they panicked or returned something other than the error. The old reader returned data from outside the filesystem, with no error, when an extent pointed past its end.

**Limit:** these checks cover the values listed. They are not a proof that no other on-disk value can overflow; BLD-01 (no safety checks in shipped loaders) is still open.

## FS-05: Bounds checks wrap on the 32-bit BIOS build
**Severity:** High · **Status:** Fixed (reproduced first, in a 32-bit test build)

`usize` is 32 bits in stage 2.
- `btrfs.zig:477,489,519,532`: `base + nritems * 25` (or 33) can wrap and pass.
- `btrfs.zig:482-483,525-526`: `start + it.size` can wrap and pass.
- `btrfs.zig:823-825`: `@intCast(ext_off + within)` and `rel + n` can wrap.
- `volumes.zig:296`: a file of 4 GiB or more is cast to `usize` unchecked.

These permit out-of-bounds access from disk values (tree blocks need only a valid CRC). Tests run only 64-bit.

**Fix (applied):** item counts are checked by division, item ranges in 64 bits, compressed-extent offsets in 64 bits before narrowing, and a file too big for `usize` is `error.OutOfMemory`. The line numbers above describe release 0.0.4.

**Also found while fixing:** the length of an ext4 inline-data attribute wrapped in the same way. Fixed.

**Regression tests:** `zig build test` on an x86_64 Linux host now also builds and runs the reader tests as 32-bit x86. On the old code, `btrfs: item data outside its leaf`, `btrfs: an impossible item count`, `ext4: an inline-data length that overflows` and `a file too big for the address space` crashed only (or, for the last, ran only) in that build. The compressed-extent test crashed in both. The ISO 9660 reader was reviewed for the same problem and none was found.

**Limit:** the 32-bit tests are a Linux Debug build, not the freestanding `ReleaseSmall` stage 2.

## FS-06: FAT directory cycle hangs the loader
**Severity:** High · **Status:** Fixed (reproduced first)

`fat.zig:207-221` follows chains with no cycle or length limit. A looping chain with no `0x00` terminator never ends. `poc-fat-cycle` was still running after 20 s. This breaks the SPEC 8 rule: error, never hang.

**Fix (applied):** a directory chain that continues past 2 MiB (65536 entries, the most a FAT directory holds) is `error.Corrupt`, which also ends a loop. The line numbers above describe release 0.0.4.

**Regression test:** `fat: a directory whose cluster chain loops is corrupt, not a hang` (FAT16 and FAT32). On the old reader it was still running when stopped after 240 s. The existing 3000-entry directory tests still pass.

## FS-07: FAT first cluster 1 underflows
**Severity:** High · **Status:** Fixed (reproduced first)

`fat.zig:179,219`. A directory entry's first cluster is not validated; `c - 2` underflows (`poc-fat-cluster1`). A FAT32 root cluster of 1 reaches the same code.

**Fix (applied):** every directory cluster, including the first one from a directory entry or the FAT32 boot sector, must be in range. The line numbers above describe release 0.0.4.

**Regression tests:** `fat: an out-of-range first cluster is corrupt` and `fat32: an out-of-range root cluster is corrupt`. Both panicked on the old reader.

## FS-08: Other hangs from corrupt metadata
**Severity:** Medium · **Status:** Fixed (partly reproduced)

- btrfs: child level is not required to be parent level minus one (`btrfs.zig:467-499`). A self-referencing node is bounded only in depth, so a wide walk is exponential.
- ISO 9660: any number of `CE` entries per area, recursion depth 4 (`iso9660.zig:183-192`): exponential reads.
- ext4: a huge directory `i_size` full of holes loops block by block (`ext4.zig:637-642`).

A related hang, a file read at block 2^32, was fixed with FS-01. The three items above are open. The FS-04 fix narrows the third: a directory can now be no bigger than the filesystem's block count, which is itself a value from the disk.

**Fix (applied):** a btrfs child must be exactly one level below its parent, begin with the key its parent names, and be named only once (keys rise strictly). One ISO directory record may chain at most 32 continuation areas. A hole in an ext4 directory is `error.Corrupt`. The line numbers above describe release 0.0.4.

**Reproduced:** the ISO case (the old reader worked through about 390,000 areas for one record and then reported success) and the ext4 directory hole (stepped over, reporting `NotFound`).

**Not reproduced:** the btrfs wide walk. A node that is its own child already hit the old depth limit at once; a crafted tree that is wide without being deep was not built. That test passes on both and only guards the new checks.

## FS-09: btrfs accepts stale or foreign tree blocks
**Severity:** Medium · **Status:** Fixed (reproduced first)

`readNode` (`btrfs.zig:430-455`) checks address and CRC but not header `fsid`, the parent's `generation`, or the expected level. A lagging mirror or old block passes.

**Fix (applied):** a tree block must carry this filesystem's metadata id and the level and generation its parent (or the superblock, or the subvolume's root item) names. A copy that fails gives way to its mirror. The line numbers above describe release 0.0.4.

**Regression tests:** `btrfs: a tree block of another age or filesystem is not accepted`, and the guard `a stale copy of a tree block gives way to the good one`. All files in every btrfs test image still read back. A filesystem with a changed metadata UUID was not tested.

## FS-10: btrfs data has no mirror fallback
**Severity:** Medium · **Status:** Partly fixed (reproduced first)

`readLogical` (`btrfs.zig:852-868`) reads only `phys[0]`, even after an I/O error. Data checksums are never verified. SPEC 5.4 promises fallback; SPEC 9a and the module header admit data is unverified.

**Fixed:** data that can't be read is taken from another copy. Test: `btrfs: unreadable data is taken from the other copy`.

**Open:** data checksums are not verified, so a copy that reads without error but is wrong is still used.

## FS-11: Unknown or unreplayed on-disk state is read silently
**Severity:** Medium · **Status:** Fixed (reproduced first)

- ext4 rejects only three `incompat` bits (`ext4.zig:309`); `encrypt` and unknown bits are accepted.
- btrfs ignores `incompat_flags` entirely.
- ext4 `needs_recovery` is set but never read by any caller, so stale metadata after a crash is used without warning.
- btrfs `log_root` is ignored, so recently fsynced files may be missing or old.

**Fix (applied):** ext4 and btrfs refuse incompatible features outside a list of those the readers handle. An ext4 volume with the `encrypt` feature is still read; encrypted files and directories are `error.Unsupported`. When a journal or log is pending, both loaders warn before booting, and `check --device` warns. The line numbers above describe release 0.0.4.

**Regression tests:** two unit tests in `tests.zig` and the unclean-filesystem case in `l6-check.sh`. The loaders' own warnings have no test.

**Limit:** journals and btrfs logs are still not replayed, as the manual now says. A volume with a feature added by a future kernel is now refused, as the kernel's own rule requires.

## FS-12: ext4 checksum verification can be skipped
**Severity:** Medium · **Status:** Partly fixed (reproduced first)

The header and manual say mismatches are never ignored, but `verifyDirBlock` returns success when the tail marker is damaged (`ext4.zig:657`); htree interior blocks are unchecked; extent `entries` is not limited to `max`, so entries outside the checksummed area are used (455,496).

**Fixed:** with `metadata_csum`, a directory block without its checksum tail is a mismatch unless it is an index block of a hashed directory; and an extent node may not hold more entries than its declared room, which is what the checksum covers.

**Regression tests:** `ext4: a directory block without its checksum tail is not trusted` and `ext4: more extents than a node has room for is corrupt`.

**Open:** the separate checksum of hashed-directory index blocks is not verified. Those blocks supply only `.` and `..` to this reader (from the first one).

## FS-13: A failed read leaves a poisoned cache
**Severity:** Low · **Status:** Fixed (reproduced first)

`ext4.zig:509-512` and `fat.zig:171-173` read into the cache buffer and keep the old tag on failure.

**Fix (applied):** the cache is marked empty before its buffer is read into. The line numbers above describe release 0.0.4.

**Regression tests:** one for ext2 indirect blocks and one for the FAT, using a disk that scribbles on the buffer when a read fails.

## FS-14: Compatibility bugs
**Severity:** Medium · **Status:** Fixed (reproduced first)

- ISO: one multi-extent file aborts the whole directory walk (`iso9660.zig:122`), hiding later entries.
- ISO: the `SL` component CONTINUE flag is ignored, inserting a false `/` (199-222).
- ISO: case-insensitive match can win over a later exact match (256-261).
- ISO: extended attribute record length and interleave are ignored.
- FAT: a legal long name over 256 UTF-8 bytes aborts the directory walk with `NameTooLong` (`fat.zig:281`).
- FAT: the label comes only from the boot sector, not the root-directory volume label.
- btrfs: `..` stops at a subvolume root, so relative symlinks across it resolve wrongly (`btrfs.zig:662-668`).
- btrfs: a short or missing inline extent zero-fills the whole remaining request (788-793).
- ext4: fast symlinks are detected by `i_blocks == 0`, which fails with an external xattr block.
- Detection: a FAT volume smaller than about 68 KiB fails the btrfs probe with `OutOfRange` and is never tried as FAT (`fs.zig:37-49`).
- LZO header says a missing end marker is accepted; the code returns `InputOverrun`.

**Fix (applied):** each item above. Multi-extent and interleaved ISO files are now listed and refused only when read; `..` crosses a btrfs subvolume boundary but not above the subvolume a path started in; and the LZO comment was corrected to match the code. The line numbers above describe release 0.0.4.

**Regression tests:** unit tests in `tests.zig` for each item, and one in `deps/fsread/src/iso9660.zig` for the split symlink component (run with `zig build test` in `deps/fsread`; not run on the old code). Interleaved ISO files have no test.
