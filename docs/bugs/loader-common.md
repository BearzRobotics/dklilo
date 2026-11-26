# Shared loader code bugs (`src/common`)

## CMN-01: A failed boot can trap the user forever
**Severity:** High · **Status:** Fixed (reproduced first)

`menu.zig:136-138`, `stage2.zig:271-279`, `uefi/main.zig:426-434`. With `timeout = 0`, or one entry with a timeout and no `prompt`, `run` boots without showing the menu. After a failure the loaders call `run` again, which boots again. Pressing Esc or `e` at "Press a key" only repeats the cycle. There is no menu, editor or manual prompt, contrary to SPEC 5.3 ("a broken config never leaves the machine unbootable"). Even with a visible menu there is no way to type a different kernel path.

**Fix (applied):** once a boot fails or returns, the menu is always shown and waits for a key, with no countdown. A new menu key, `m`, opens the prompt for booting by hand; if a password is configured it must be given first. The line numbers above describe release 0.0.4.

**Regression tests:** `tests/qemu/l3-bios-retry.sh` (its three cases failed on the old loader) and unit tests in `menu.zig`.

**Behaviour to know about:** an unattended machine whose boot fails now waits at the menu after the "Press a key" answer instead of retrying the same entry.

## CMN-02: Whole-disk FAT volumes are invisible
**Severity:** High · **Status:** Fixed (reproduced first)

`part.zig:114-127`, `volumes.zig:145-164`. A FAT boot sector ends in `0x55AA`, so it is parsed as an MBR. With an empty table, `addDisk` adds no volume; the whole-disk fallback only runs on a parse error. Superfloppy FAT, which the code says it supports, never works. `poc-fat-superfloppy` found 0 volumes on a fresh `mkfs.fat` image. Boot code in those bytes could instead yield bogus partitions. See also INST-05.

**Fix (applied):** a sector that starts like a FAT, NTFS or exFAT boot sector, with no believable partition entries, is not treated as a partition table; a disk left with no volume is one whole-disk volume. Real partition entries still win over leftover boot-sector bytes. The line numbers above describe release 0.0.4.

**Regression tests:** `a FAT filesystem on a whole disk is one volume`, `a disk with an empty partition table can still hold a filesystem`, and the guard `partitions win over a boot sector left from an old FAT filesystem`.

## CMN-03: Password protection fails open
**Severity:** High · **Status:** Fixed (the reportable cases; the rest decided)

- `restricted` without `password` protects nothing (`menu.zig:178`), with no error or warning.
- `password` without `restricted` protects nothing. In LILO, a password without `restricted` guards booting the image, so a ported config silently loses protection.
- A 64-character non-hex password is accepted (`config.zig:167-169`) and can never match.
- A broken or unreadable config leads to the unrestricted manual prompt.

**Fixed:** `dklilo check` fails on a password hash that nothing could match, and warns about `restricted` without `password` and `password` without `restricted`. A password also guards the boot-by-hand menu key. The loader's parser still accepts an unusable hash on purpose: rejecting the file would lead to the unrestricted prompt, while a hash nobody can match keeps guarded actions locked.

**Regression test:** `tests/qemu/l6-check.sh`; the three cases first added failed on the old tool.

**Decided by the maintainer (2026-11-25):** a broken configuration may bring up the prompt without a password (the same code covers an unreadable or missing one); and `password` without `restricted` keeps not guarding booting, unlike LILO, so that machines can boot unattended. The manual says both, and `check` warns about the second.

## CMN-04: Weak password handling
**Severity:** Medium · **Status:** Fixed

Unsalted single SHA-256 in a readable file permits fast offline guessing. The "Access denied" delay is `getKey(1500)`, which any key skips (`menu.zig:187`). Input is silently cut at 64 characters, so longer passwords never work. Buffers are not cleared.

**Fix (applied):** typing can no longer cut short the pause after a wrong password (keys pressed during it are discarded), passwords of up to 256 characters work, and the typed password is cleared from memory. The hash may now be PBKDF2-HMAC-SHA-256 with a random salt and an iteration count, made by the new `dklilo password` command (300,000 iterations by default). The unsalted form is still accepted, with a warning from `check`.

**Tests:** unit tests (one compares the output with a value computed by Python's `hashlib`), `l6-check.sh`, which also checks the command's output against `hashlib`, and salted passwords in both loaders (`l3-bios-retry.sh` and `l2-uefi-retry.sh`). In QEMU without acceleration, a 100,000-iteration check took 0.6 s in the BIOS loader, so the default should take about 2 s there; no real hardware was timed, and the UEFI check was not timed.

**Behaviour to know about:** a loader older than 0.0.5 treats the new form as a broken configuration, which brings up the prompt without a password. Update the loader before the configuration.

## CMN-05: `LABEL=` and `UUID=` take the first match on any disk
**Severity:** Medium · **Status:** Partly fixed

`volumes.zig:170-204`. No preference for the config's disk and no duplicate detection. A cloned disk or inserted USB stick can supply the kernel. On UEFI, `findConfig(null)` fallback can also take a config from any disk. All-zero ISO UUIDs and zero-padded FAT serials can match `UUID=`, contrary to the manual.

**Fixed:** `LABEL=`, `UUID=` and `PARTUUID=` now prefer a volume on the same disk as the configuration, and `UUID=` no longer matches FAT or ISO 9660, as the manual says. Unit tests cover both.

**Open:** duplicates on one disk, or on two other disks, are not detected; and on UEFI the configuration itself can still come from another disk when the boot disk has none.

## CMN-06: Volume probe errors are hidden and permanent
**Severity:** Medium · **Status:** Partly fixed

`volumes.zig:54-61` turns every error (transient I/O, out of memory, checksum, unsupported) into "no filesystem" for good. The user sees only a missing config. Each opened btrfs volume uses several hundred KiB of the 8 MiB BIOS heap.

**Fixed:** a read error or lack of memory is no longer remembered as "no filesystem", and when no configuration is found, or it can't be read, the loaders say why. Unit test: `a read error while looking for a filesystem isn't remembered` (the new messages have no test).

**Open:** the heap used by each open btrfs volume in the BIOS loader is unchanged.

## CMN-07: Partition values overflow
**Severity:** Medium · **Status:** Fixed (reproduced first)

`part.zig:224`: `last - first + 1` overflows (`poc-gpt-overflow`). Code review: `start_lba * sector_size` (37-38) and `entries_lba * sector_size` (212) are unchecked; partitions and GPT `my_lba` are not validated against the disk. Sector size is only asserted, while `read` indexes bytes 510-511 (UEFI block size is unvalidated).

**Fix (applied):** the GPT length no longer overflows, the header must name the sector it was read from, the entry table offset is checked, the sector size must be 512 to 4096, and the volume list drops a partition that starts outside the disk and cuts one that runs past it. The parser itself still reports entries as written, because `install-bios` parses only the start of a disk. The line numbers above describe release 0.0.4.

**Regression tests:** `gpt: impossible partitions are dropped or cut to the disk` and `a partition table read from the start of a disk keeps what lies beyond`.

## CMN-08: Config parser leaks on error
**Severity:** Low · **Status:** Fixed (reproduced first)

`config.zig:111-117`: before `toOwnedSlice`, `cfg.entries` is empty, so the `errdefer` never frees completed entries' `initrds` (`poc-config-leak`).

**Regression test:** `a failed parse frees what it had built`.

## CMN-09: Config parser accepts mistakes
**Severity:** Low · **Status:** Partly fixed

`prompt = no` and `restricted = false` both enable the option. Repeated keys silently overwrite. `"a" "b"` is accepted with inner quotes. Extra `serial` fields are ignored. A UTF-8 BOM gives `UnknownKey`. Empty `iso =` reports `MisplacedKey`.

**Fixed:** a flag given `no`, `false`, `off` or `0` is off; a byte order mark is skipped; an empty `iso =` is `MissingValue`; and `dklilo check` warns about repeated keys, extra `serial` fields and unknown flag values. The loaders still accept them, so no working configuration stops booting.

**Open on purpose:** inner quotes are kept, because a kernel parameter may need them.

## CMN-10: Menu does not scroll and truncates silently
**Severity:** Medium · **Status:** Fixed (reproduced first)

`menu.zig:107-117,176` places rows by entry count; around 20 entries the countdown and editor leave a 25-row screen. `buildCmdline` truncates silently. A huge `timeout` overflows `(remaining + 9)` (126). Unmapped keys do not stop the countdown although "any key" is documented; stray serial bytes that map to keys do.

**Fix (applied):** a long list scrolls, a huge timeout no longer overflows, any keyboard key stops the countdown, and `dklilo check` fails on a command line longer than the loaders hold. Bytes on the serial line that mean nothing are still ignored; ones that look like keys still count. The line numbers above describe release 0.0.4.

**Regression tests:** unit tests in `menu.zig` for scrolling and the timeout, and `tests/qemu/l6-check.sh` for the long command line. The new keyboard-key behaviour has no test.

## CMN-11: Old setup headers are over-copied
**Severity:** Low · **Status:** Fixed (reproduced first)

`bootparams.zig:103-124` copies through `0x26C` regardless of the header length byte at `0x201`, despite its comment; protocol 2.10-2.14 images get unrelated bytes in newer fields. `pm_size` is an unchecked `u32` cast (112); `e820.addr + size` is unchecked (160).

**Fix (applied):** only the header length the kernel declares is copied (never less than a 2.10 header). The `pm_size` cast was fixed with BIOS-03, and the E820 sum now saturates. The line numbers above describe release 0.0.4.

**Regression test:** `header bytes past the length the kernel declares are not copied`.

## CMN-12: `openFile` accepts non-regular files
**Severity:** Low · **Status:** Fixed (reproduced first)

`volumes.zig:279-285` rejects only directories. Device nodes, FIFOs and sockets are accepted, including by `check`. The ISO mount cache key omits the base volume (253-256), and the error and OOM paths in `isoVolume`/`addDisk` have leak or double-free hazards (131-134, 258-270).

**Fix (applied):** only regular files open (`error.NotRegularFile`), the ISO mount cache includes the volume the path is relative to, and both memory-failure paths are fixed. The line numbers above describe release 0.0.4.

**Regression tests:** `only regular files can be opened`, `the same ISO path on two volumes is two mounts`, and `running out of memory while adding disks neither leaks nor frees twice` (a double free on the old code).
