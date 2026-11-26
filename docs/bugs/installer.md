# Installer and tools bugs (`src/installer`)

Reproductions used image files and temporary directories only. No real disk or firmware variable was touched.

## INST-01: `install-bios` can destroy a filesystem
**Severity:** Critical · **Status:** Fixed (reproduced first)

`main.zig:121-169`, `plan.zig:77-122`. Any sector ending `0x55AA` is accepted as an MBR, including a filesystem boot sector. If the target "gap" is zero, bytes 0-439 (including the FAT BPB) are overwritten.

**Reproduction:** `mkfs.fat -F 16 -R 600` image, then `install-bios --yes`: reported success; `mdir` then said `non DOS media`. Other FAT layouts may be saved by the zero check.

**Fix:** require a whole disk; reject sector 0 holding a BPB or filesystem signature; reject a table with no valid entries unless explicitly requested.

**Fix (applied):** `install-bios` refuses a block device that sysfs marks as a partition (symlinks followed), a FAT, NTFS or exFAT boot sector, an MBR entry with a status byte other than `00` or `80`, and an empty MBR table. `--force` overrides none of these. The text above describes release 0.0.4.

**Tests:** `tests/qemu/l6-install-safety.sh` (needs no QEMU or kernel), unit tests in `plan.zig` and `blockinfo.zig`. The partition refusal was also checked by hand on a real partition and a `by-id` link, as a user who cannot open them.

**Limits:** image files and other non-block targets rely on the content checks alone. Other filesystems are not recognised by name; they rely on the table and zero checks. A repartitioned disk that kept an old FAT parameter block in its MBR is now refused.

## INST-02: `--removable` overwrites a foreign fallback loader
**Severity:** Critical · **Status:** Fixed (reproduced first)

`main.zig:359-366`. An existing `EFI/BOOT/BOOT<ARCH>.EFI` is replaced with no check, warning or backup; the summary says only "copy". A placeholder foreign loader was destroyed. This contradicts the README claim that foreign boot loaders are not overwritten.

**Fix:** identify our own loader; otherwise refuse without an explicit override.

**Fix (applied):** an existing fallback loader is replaced only if it contains the headings of both dklilo menu screens (true of 0.0.4 on all four architectures); otherwise `--force` is needed. A read error other than "not found" stops the install.

**Tests:** `tests/qemu/l6-install-safety.sh`. Loaders installed by a 0.0.4 build were also replaced without `--force` on all four architectures.

**Limits:** `--force` keeps no backup. Recognition is by text, not a signature, and changing the headings would break it (noted in `menu.zig`). The write itself is still not atomic (INST-07).

## INST-03: Firmware boot variables can be overwritten or lost
**Severity:** Critical · **Status:** Fixed (reproduced first)

- Lines 395-399: **any** read error (permission, I/O, entry over 4096 bytes) marks `Boot####` as free, so an existing entry can be overwritten.
- Lines 419-428: **any** failure reading `BootOrder` is ignored, and a new order containing only dklilo is written.
- Orders over 256 entries are truncated. The search can stop at the first gap above `0x40` and miss an existing dklilo entry. Any entry named "dklilo" is reused, even another installation's.

**Fix:** only `FileNotFound` means free or absent; abort otherwise.

**Fix (applied):** the logic moved to `src/installer/bootvars.zig`. Used numbers come from the directory listing; any existing `Boot####` or `BootOrder` that cannot be read stops the install, and everything is read before the first write. `BootOrder` is no longer limited to 256 entries. An entry is reused only if its description, partition number and signature, and loader path match.

**Tests:** eight unit tests on a temporary directory. Run against the old logic (moved unchanged), five failed, including the overwrite of a variable larger than 4 KiB. The unreadable-`Boot####` test also passed on the old logic, only because writing over a directory fails too, so it does not demonstrate that case. The new code was also run on a copy of one machine's real variables: existing entries were unchanged and the old order was kept after the new entry. It has not written to real firmware.

**Behaviour change:** moving dklilo to another partition now leaves the old entry in place and creates a new one. Writing the variable and `BootOrder` is still two separate steps.

## INST-04: ESP directory is mapped to the wrong partition
**Severity:** High · **Status:** Fixed

`main.zig:209-233,318`.
- `startsWith(dir, mp)` has no path boundary: `/mnt/bootfiles` matched mount `/mnt/boot`. `mountSubvol` is the same.
- `install-uefi` does not canonicalise the directory, so symlinks and relative paths misresolve.
- If the ESP is not mounted, `/boot/efi` falls back to the `/` mount: the loader goes into the root filesystem and a boot entry for it is put first in `BootOrder`.
- Nothing checks that the target is a FAT ESP. Non-`/dev/` sources are skipped in favour of a parent mount. mountinfo escapes are not decoded.

**Fix (applied):** a new parser (`mounts.zig`) matches whole path components, decodes escapes and takes the deepest mount whatever its source; directories are canonicalised; and without `--device`, `install-uefi` refuses a directory that is not on a mounted FAT filesystem. A partition whose type is not ESP gets a warning. The line numbers above describe release 0.0.4.

**Regression tests:** unit tests in `mounts.zig`, `tests/qemu/l9-config-paths.sh` (the prefix and escape cases failed on the old tool), and "refuses an ESP that isn't mounted" in `l6-install-safety.sh`, which needs the new `--mountinfo` test option and so could not be run on the old tool.

**Limit:** with `--device` or `--removable`, nothing checks that the directory is on that partition or on FAT.

## INST-05: `check` segfaults or fails on valid setups
**Severity:** High · **Status:** Fixed (reproduced first: the crash)

- Empty config (documented valid): line 515 indexes `entries[0]`. **Segmentation fault**, exit 139.
- A whole-FAT device: `--device` reported "no dklilo.conf found" although present (CMN-02). Without `--device`, line 505 takes `vols.items[0]` of an empty list, so checking a config on a mounted ESP would index out of bounds (code review).
- Only one device is added, so `LABEL=`/`UUID=`/`PARTUUID=` references to other disks falsely fail (code review).

**Fix (applied):** an empty configuration is accepted; a whole-disk FAT works (CMN-02); without `--device`, `check` adds the whole disk when it can, picks the partition, and adds the other disks if a volume prefix is used. The line numbers above describe release 0.0.4.

**Regression test:** `tests/qemu/l6-check.sh`, including the run without `--device`.

**Limit:** finding a volume on another real disk needs root and was not tested.

## INST-06: Disk naming requirement is not met
**Severity:** High · **Status:** Fixed

`splitPartitionName` (178-188) only strips digits and never resolves symlinks. `install-uefi --device` failed for a `by-id` style link (opened `...-part`) and a `by-partuuid` style link ("does not look like a partition"), both required by SPEC 5.7 and the README. The summary line is printed before this failure. A name over 256 bytes overflows `disk_buf` (186); a long mount source overflows `buf` (226).

**Fix (applied):** a block device given by any name is looked up in sysfs for its parent disk and partition number; the fixed-size buffers are gone; and the summary is printed after the lookup. The string splitting remains only for paths that are not block devices. The line numbers above describe release 0.0.4.

**Tests:** a unit test with a made-up sysfs. On this machine a `/dev/disk/by-id/...-part1` link resolved to its disk; opening it needed root, so the run stopped there. No by-partuuid link was run.

## INST-07: Write failures can be reported as success
**Severity:** High · **Status:** Partly fixed (loader writes reproduced first)

- `dev.file.sync ... catch {}` (166, 847), then "Done."
- No sync between stage 2 and MBR writes, so "MBR goes last" is not guaranteed on disk.
- UEFI loader and `BootOrder` follow no ESP sync. The loader is truncated and rewritten in place (366); interruption or a full ESP leaves a broken loader.
- No backup of the old MBR or loader. No check that the target is in use.

**Fixed:** every sync error is reported; stage 2 is synced before the MBR is written; the UEFI loader is written beside the old one, synced and renamed over it, and the filesystem is synced before the boot entry is made.

**Regression test:** "a failed write leaves the old loader in place" in `l6-install-safety.sh` (a file size limit stands in for a full ESP). The old tool left a broken loader. Sync failures themselves are not tested.

**Open:** no copy of the old MBR or loader is kept, and nothing checks whether the target is in use.

## INST-08: Data after an older stage 2 is overwritten
**Severity:** High · **Status:** Fixed (reproduced first)

`plan.zig:111-114`: if the magic matches, the whole new range is writable. Foreign data planted at sector 100, beyond a short fake old stage 2, was erased.

**Fix:** record the installed length and require zeros past it.

**Fix (applied):** an older stage 2 owns the sectors recorded in the MBR block list; anything further must be zero. A longer old one is zeroed in full. Without a matching record, `--force` is required.

**Tests:** `tests/qemu/l6-install-safety.sh` and unit tests in `plan.zig`. A disk installed by 0.0.4 upgraded without `--force`, and so did a reinstall after `wipefs -a -f` and repartitioning with `sfdisk` (same layout, MBR and GPT, on image files).

**Limit:** earlier releases did not zero the tail when installing a *shorter* stage 2. If such leftovers lie past the recorded length and a later stage 2 grows into them, the install is refused as foreign data, which `--force` does not override. The sectors must then be checked and zeroed by hand.

## INST-09: BIOS boot partition beyond 4 MiB is refused
**Severity:** Medium · **Status:** Fixed (reproduced first)

Only the first 4 MiB is read (138, `plan.zig:109`). A valid partition at sector 43008 gave "not enough room before the first partition", which is also the wrong explanation.

**Fix (applied):** a BIOS boot partition beyond the first 4 MiB is read separately, and a partition too small for stage 2 gets its own message. The line numbers above describe release 0.0.4.

**Regression test:** a partition at sector 43008 in `l6-install-safety.sh`, both installed and refused for foreign data.

**Note:** the first version of this fix silently read nothing, because `@min` with a constant gave an 11-bit integer and the tool is built without overflow checks (BLD-01). The test caught it.

## INST-10: 512-byte sectors are hardcoded
**Severity:** Medium · **Status:** Fixed (by review; not tested on such hardware)

Lines 101-106 and `plan.zig:8`. On 4Kn disks, GPT parsing and offsets are wrong. `BLKGETSIZE64` (86) is the 64-bit ioctl value, so block device size is likely wrong on a 32-bit ARM build.

**Fix (applied):** the disk's logical sector size is asked for and used by `check`, `config` and `install-uefi`; `install-bios` refuses sectors other than 512 bytes, which the BIOS loader does not support; and the size ioctl number now matches the word size. The line numbers above describe release 0.0.4.

## INST-11: `config` writes wrong paths
**Severity:** High · **Status:** Fixed (reproduced first)

`main.zig:680-726` uses host paths, not paths relative to the filesystem or subvolume.
- btrfs `/` and `/boot` as subvolumes of one device: emitted the full host path together with `subvol = @boot`.
- `--boot` below a mounted target root: emitted `/vmlinuz-1` where `/boot/vmlinuz-1` is correct.
- A prefix-only mount match gave the wrong prefix (INST-04).
- `root=` still comes from the running host's `/` (code review).

**Fix (applied):** kernel paths are worked out from the mount's root within its filesystem and its btrfs subvolume. `root=` is taken from the mounted system whose `boot` directory was given, else from the running one. The line numbers above describe release 0.0.4.

**Regression tests:** `tests/qemu/l9-config-paths.sh` and the existing `l9-config.sh`.

**Limit:** choosing the target system by the directory name `boot` is a rule of thumb; `--root` overrides it.

## INST-12: `config` ordering and labels
**Severity:** Medium · **Status:** Fixed (reproduced first)

`genconfig.zig:63-84,106-112`. `6.10-rc1` sorted above `6.10` and became the default. `vmlinuz-1` plus `bzImage-1` produced duplicate labels: "internal error". Code review: paths are unquoted (`#` truncates); a quote in `--append` breaks the output; initrd choice depends on directory order; CPU microcode images are not added; any NTFS partition adds Windows.

**Fix (applied):** release candidates sort below their release; labels are made unique; paths are quoted when needed; the initramfs choice no longer depends on directory order; `amd-ucode.img` and `intel-ucode.img` are loaded first; and on a machine started by UEFI an NTFS partition alone no longer adds Windows. An `--append` that would not read back is refused (the old tool refused it too). File names containing a quote or newline are skipped. The line numbers above describe release 0.0.4.

**Regression tests:** `tests/qemu/l9-config-paths.sh` and unit tests in `genconfig.zig`. Windows detection is not tested.

## INST-13: `config --force` replaces the file unsafely
**Severity:** Medium · **Status:** Fixed (reproduced first)

Lines 741-750: truncate-and-write can leave an empty config. Without `--force`, existence is a separate check, and any `access` error counts as "does not exist".

**Fix (applied):** without `--force` the file is created exclusively; with it, a new file is written, synced and renamed over the old one, keeping its permissions and any symlink to it. The line numbers above describe release 0.0.4.

**Regression tests:** `tests/qemu/l9-config-paths.sh` (the old tool lost the file when the rewrite failed) and a unit test.

## INST-14: `isohybrid` writes blindly
**Severity:** High · **Status:** Fixed (reproduced first)

`main.zig:812-849`.
- Sector count comes from the **running tool's** stage 2, not the ISO's (`eltorito.bin` offset `0x40`): a version mismatch can truncate the load.
- It does not check for dklilo stage 1 before writing bytes at offset 416.
- No summary or confirmation, though the docs say every disk write is confirmed.

**Fix (applied):** the stage 2 length comes from the ISO's `eltorito.bin`; an ISO without dklilo's stage 1 is refused; sync errors are reported; and writing to a block device needs confirmation or the new `--yes`. A file needs none, so build scripts keep working. The line numbers above describe release 0.0.4.

**Regression tests:** `tests/qemu/l7-isohybrid.sh` and the existing `l7-iso.sh` boots. The disk confirmation is not tested.

## INST-15: `check` misses real boot failures
**Severity:** Medium · **Status:** Partly fixed (reproduced first)

A 0-byte "kernel" passed with "all files found". Code review: no bzImage/EFI check, initrd count (BIOS-08), chain targets (BIOS-05) or password consistency (CMN-03). It reads the raw device under a mounted filesystem, so unflushed or journal-only changes can give wrong answers.

**Fixed:** an empty kernel is an error; an empty initramfs, and a kernel that is neither a bzImage nor an EFI program, are warnings; passwords, command-line length and chainload targets are checked (CMN-03, CMN-10, BIOS-05); only regular files count (CMN-12); there is no initrd limit left to check (BIOS-08); and `check` syncs before reading a mounted disk.

**Regression test:** `tests/qemu/l6-check.sh`.

**Open:** a journal that has not been replayed can still hide a recent change.

## INST-16: Smaller issues
**Severity:** Low · **Status:** Fixed (reproduced first)

- "Replaced boot code" detection matches a common five-byte prologue (`plan.zig:134-136`), so foreign MBR code may not be reported.
- `out`/`err` silently drop messages over 1024 bytes, including summary lines.
- An unknown option to `install-bios` can be taken as the disk name.

**Fix (applied):** dklilo's boot code is recognised by its first 14 bytes, long messages are no longer dropped, and an unknown option is a usage error. The line numbers above describe release 0.0.4.

**Regression tests:** `l6-install-safety.sh` (replaced boot code announced; unknown option) and a unit test. Long messages are not tested. Upgrading a disk installed by 0.0.4 relies on those 14 bytes, which are the same in 0.0.4's stage 1.
