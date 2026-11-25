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
**Severity:** High · **Status:** Prefix bug reproduced via `config`; the rest code review

`main.zig:209-233,318`.
- `startsWith(dir, mp)` has no path boundary: `/mnt/bootfiles` matched mount `/mnt/boot`. `mountSubvol` is the same.
- `install-uefi` does not canonicalise the directory, so symlinks and relative paths misresolve.
- If the ESP is not mounted, `/boot/efi` falls back to the `/` mount: the loader goes into the root filesystem and a boot entry for it is put first in `BootOrder`.
- Nothing checks that the target is a FAT ESP. Non-`/dev/` sources are skipped in favour of a parent mount. mountinfo escapes are not decoded.

**Fix:** canonicalise, match whole components, require the expected mount, FAT and ESP type.

## INST-05: `check` segfaults or fails on valid setups
**Severity:** High · **Status:** Empty config and FAT disk reproduced

- Empty config (documented valid): line 515 indexes `entries[0]`. **Segmentation fault**, exit 139.
- A whole-FAT device: `--device` reported "no dklilo.conf found" although present (CMN-02). Without `--device`, line 505 takes `vols.items[0]` of an empty list, so checking a config on a mounted ESP would index out of bounds (code review).
- Only one device is added, so `LABEL=`/`UUID=`/`PARTUUID=` references to other disks falsely fail (code review).

## INST-06: Disk naming requirement is not met
**Severity:** High · **Status:** Reproduced

`splitPartitionName` (178-188) only strips digits and never resolves symlinks. `install-uefi --device` failed for a `by-id` style link (opened `...-part`) and a `by-partuuid` style link ("does not look like a partition"), both required by SPEC 5.7 and the README. The summary line is printed before this failure. A name over 256 bytes overflows `disk_buf` (186); a long mount source overflows `buf` (226).

**Fix:** resolve links and use sysfs for the parent disk and partition number.

## INST-07: Write failures can be reported as success
**Severity:** High · **Status:** Code review

- `dev.file.sync ... catch {}` (166, 847), then "Done."
- No sync between stage 2 and MBR writes, so "MBR goes last" is not guaranteed on disk.
- UEFI loader and `BootOrder` follow no ESP sync. The loader is truncated and rewritten in place (366); interruption or a full ESP leaves a broken loader.
- No backup of the old MBR or loader. No check that the target is in use.

**Fix:** sync and propagate errors between ordered steps; write a temporary file, sync, rename.

## INST-08: Data after an older stage 2 is overwritten
**Severity:** High · **Status:** Fixed (reproduced first)

`plan.zig:111-114`: if the magic matches, the whole new range is writable. Foreign data planted at sector 100, beyond a short fake old stage 2, was erased.

**Fix:** record the installed length and require zeros past it.

**Fix (applied):** an older stage 2 owns the sectors recorded in the MBR block list; anything further must be zero. A longer old one is zeroed in full. Without a matching record, `--force` is required.

**Tests:** `tests/qemu/l6-install-safety.sh` and unit tests in `plan.zig`. A disk installed by 0.0.4 upgraded without `--force`, and so did a reinstall after `wipefs -a -f` and repartitioning with `sfdisk` (same layout, MBR and GPT, on image files).

**Limit:** earlier releases did not zero the tail when installing a *shorter* stage 2. If such leftovers lie past the recorded length and a later stage 2 grows into them, the install is refused as foreign data, which `--force` does not override. The sectors must then be checked and zeroed by hand.

## INST-09: BIOS boot partition beyond 4 MiB is refused
**Severity:** Medium · **Status:** Reproduced

Only the first 4 MiB is read (138, `plan.zig:109`). A valid partition at sector 43008 gave "not enough room before the first partition", which is also the wrong explanation.

## INST-10: 512-byte sectors are hardcoded
**Severity:** Medium · **Status:** Code review

Lines 101-106 and `plan.zig:8`. On 4Kn disks, GPT parsing and offsets are wrong. `BLKGETSIZE64` (86) is the 64-bit ioctl value, so block device size is likely wrong on a 32-bit ARM build.

## INST-11: `config` writes wrong paths
**Severity:** High · **Status:** Reproduced (with `--mountinfo`)

`main.zig:680-726` uses host paths, not paths relative to the filesystem or subvolume.
- btrfs `/` and `/boot` as subvolumes of one device: emitted the full host path together with `subvol = @boot`.
- `--boot` below a mounted target root: emitted `/vmlinuz-1` where `/boot/vmlinuz-1` is correct.
- A prefix-only mount match gave the wrong prefix (INST-04).
- `root=` still comes from the running host's `/` (code review).

## INST-12: `config` ordering and labels
**Severity:** Medium · **Status:** Reproduced

`genconfig.zig:63-84,106-112`. `6.10-rc1` sorted above `6.10` and became the default. `vmlinuz-1` plus `bzImage-1` produced duplicate labels: "internal error". Code review: paths are unquoted (`#` truncates); a quote in `--append` breaks the output; initrd choice depends on directory order; CPU microcode images are not added; any NTFS partition adds Windows.

## INST-13: `config --force` replaces the file unsafely
**Severity:** Medium · **Status:** Code review

Lines 741-750: truncate-and-write can leave an empty config. Without `--force`, existence is a separate check, and any `access` error counts as "does not exist".

## INST-14: `isohybrid` writes blindly
**Severity:** High · **Status:** Code review

`main.zig:812-849`.
- Sector count comes from the **running tool's** stage 2, not the ISO's (`eltorito.bin` offset `0x40`): a version mismatch can truncate the load.
- It does not check for dklilo stage 1 before writing bytes at offset 416.
- No summary or confirmation, though the docs say every disk write is confirmed.

## INST-15: `check` misses real boot failures
**Severity:** Medium · **Status:** Partly reproduced

A 0-byte "kernel" passed with "all files found". Code review: no bzImage/EFI check, initrd count (BIOS-08), chain targets (BIOS-05) or password consistency (CMN-03). It reads the raw device under a mounted filesystem, so unflushed or journal-only changes can give wrong answers.

## INST-16: Smaller issues
**Severity:** Low · **Status:** Code review

- "Replaced boot code" detection matches a common five-byte prologue (`plan.zig:134-136`), so foreign MBR code may not be reported.
- `out`/`err` silently drop messages over 1024 bytes, including summary lines.
- An unknown option to `install-bios` can be taken as the disk name.
