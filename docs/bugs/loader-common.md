# Shared loader code bugs (`src/common`)

## CMN-01: A failed boot can trap the user forever
**Severity:** High · **Status:** Reproduced (BIOS, QEMU)

`menu.zig:136-138`, `stage2.zig:271-279`, `uefi/main.zig:426-434`. With `timeout = 0`, or one entry with a timeout and no `prompt`, `run` boots without showing the menu. After a failure the loaders call `run` again, which boots again. Pressing Esc or `e` at "Press a key" only repeats the cycle. There is no menu, editor or manual prompt, contrary to SPEC 5.3 ("a broken config never leaves the machine unbootable"). Even with a visible menu there is no way to type a different kernel path.

**Fix:** after a failure force the menu, and offer the manual prompt (subject to the password).

## CMN-02: Whole-disk FAT volumes are invisible
**Severity:** High · **Status:** Reproduced

`part.zig:114-127`, `volumes.zig:145-164`. A FAT boot sector ends in `0x55AA`, so it is parsed as an MBR. With an empty table, `addDisk` adds no volume; the whole-disk fallback only runs on a parse error. Superfloppy FAT, which the code says it supports, never works. `poc-fat-superfloppy` found 0 volumes on a fresh `mkfs.fat` image. Boot code in those bytes could instead yield bogus partitions. See also INST-05.

**Fix:** recognise a filesystem boot sector (BPB) before treating sector 0 as an MBR.

## CMN-03: Password protection fails open
**Severity:** High · **Status:** Partly reproduced (`check` accepts both configs)

- `restricted` without `password` protects nothing (`menu.zig:178`), with no error or warning.
- `password` without `restricted` protects nothing. In LILO, a password without `restricted` guards booting the image, so a ported config silently loses protection.
- A 64-character non-hex password is accepted (`config.zig:167-169`) and can never match.
- A broken or unreadable config leads to the unrestricted manual prompt.

**Fix:** have the parser and `check` reject or loudly warn on these. Changing LILO semantics or the manual prompt is a design decision to record.

## CMN-04: Weak password handling
**Severity:** Medium · **Status:** Code review

Unsalted single SHA-256 in a readable file permits fast offline guessing. The "Access denied" delay is `getKey(1500)`, which any key skips (`menu.zig:187`). Input is silently cut at 64 characters, so longer passwords never work. Buffers are not cleared.

## CMN-05: `LABEL=` and `UUID=` take the first match on any disk
**Severity:** Medium · **Status:** Code review

`volumes.zig:170-204`. No preference for the config's disk and no duplicate detection. A cloned disk or inserted USB stick can supply the kernel. On UEFI, `findConfig(null)` fallback can also take a config from any disk. All-zero ISO UUIDs and zero-padded FAT serials can match `UUID=`, contrary to the manual.

## CMN-06: Volume probe errors are hidden and permanent
**Severity:** Medium · **Status:** Code review

`volumes.zig:54-61` turns every error (transient I/O, out of memory, checksum, unsupported) into "no filesystem" for good. The user sees only a missing config. Each opened btrfs volume uses several hundred KiB of the 8 MiB BIOS heap.

## CMN-07: Partition values overflow
**Severity:** Medium · **Status:** Reproduced (GPT)

`part.zig:224`: `last - first + 1` overflows (`poc-gpt-overflow`). Code review: `start_lba * sector_size` (37-38) and `entries_lba * sector_size` (212) are unchecked; partitions and GPT `my_lba` are not validated against the disk. Sector size is only asserted, while `read` indexes bytes 510-511 (UEFI block size is unvalidated).

## CMN-08: Config parser leaks on error
**Severity:** Low · **Status:** Reproduced

`config.zig:111-117`: before `toOwnedSlice`, `cfg.entries` is empty, so the `errdefer` never frees completed entries' `initrds` (`poc-config-leak`).

## CMN-09: Config parser accepts mistakes
**Severity:** Low · **Status:** Code review

`prompt = no` and `restricted = false` both enable the option. Repeated keys silently overwrite. `"a" "b"` is accepted with inner quotes. Extra `serial` fields are ignored. A UTF-8 BOM gives `UnknownKey`. Empty `iso =` reports `MisplacedKey`.

## CMN-10: Menu does not scroll and truncates silently
**Severity:** Medium · **Status:** Code review

`menu.zig:107-117,176` places rows by entry count; around 20 entries the countdown and editor leave a 25-row screen. `buildCmdline` truncates silently. A huge `timeout` overflows `(remaining + 9)` (126). Unmapped keys do not stop the countdown although "any key" is documented; stray serial bytes that map to keys do.

## CMN-11: Old setup headers are over-copied
**Severity:** Low · **Status:** Code review

`bootparams.zig:103-124` copies through `0x26C` regardless of the header length byte at `0x201`, despite its comment; protocol 2.10-2.14 images get unrelated bytes in newer fields. `pm_size` is an unchecked `u32` cast (112); `e820.addr + size` is unchecked (160).

## CMN-12: `openFile` accepts non-regular files
**Severity:** Low · **Status:** Code review

`volumes.zig:279-285` rejects only directories. Device nodes, FIFOs and sockets are accepted, including by `check`. The ISO mount cache key omits the base volume (253-256), and the error and OOM paths in `isoVolume`/`addDisk` have leak or double-free hazards (131-134, 258-270).
