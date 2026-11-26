# dklilo bug hunt

Audit of commit `38d1030` (release 0.0.4), 2026-11-24. The audit itself changed no source file. Entries and line numbers describe that commit. Every fix must keep existing supported behaviour.

**Progress:** 55 entries fixed, 11 partly fixed, 0 open. Partly fixed (each entry says what remains): BIOS-05, BIOS-11, BLD-02, CMN-05, CMN-06, CMN-09, FS-10, FS-12, INST-07, INST-15, UEFI-07.

**66 entries:** 7 critical, 20 high, 28 medium, 11 low. Many entries group several related defects.

## Status meanings

- **Reproduced:** run on image files, directories or QEMU. Where an entry says only part was reproduced, or marks items "code review", the rest was not run.
- **Code review:** found by reading the source. Not executed, so treat the stated impact as expected, not observed.
- **Needs verification:** depends on something not checked.

## Suggested fix order

1. ~~BIOS-01: keyboard and disk error detection.~~ Fixed.
2. ~~FS-01, FS-02: wrong file data from valid filesystems.~~ Fixed.
3. ~~INST-01, INST-02, INST-03, INST-08: destructive installer behaviour.~~ Fixed.
4. ~~FS-03 to FS-07, BIOS-02, BIOS-03: memory safety and hangs.~~ Fixed.
5. ~~CMN-01, UEFI-01, UEFI-02, CMN-03: boot recovery and protection.~~ Done; CMN-03 is partly fixed.
6. ~~The rest, adding a regression test with each fix (BLD-02).~~ Done; see the partly fixed entries.

## What was and was not checked

- `zig build` and `zig build test` succeeded (84/84 tests).
- The QEMU suite was run later with the kernel from the `dkde-devel` ISO built 2026-11-16 (7.3.4-dkrescue). All 17 scripts **passed on the unfixed 0.0.4 code**, despite the bugs listed here.
- The AArch64 and RISC-V Linux boots passed on the unfixed code too, using Debian netboot kernels (6.1.0-50-arm64 from bookworm, 6.12.117+deb13-riscv64 from trixie). Their SHA-256 sums matched Debian's `SHA256SUMS`; its GPG signature was not checked.
- Nothing was tested on real hardware. Real Windows was not booted (the suite uses stand-ins), and 32-bit ARM is only built, not run.
- Tests and some helper files were only sampled. `original/` was not audited. A finding not listed here is not proof of correctness.

See [repro/README.md](repro/README.md) to rerun the reproductions.

## Index

| ID | Severity | Bug | Status |
|---|---|---|---|
| [BIOS-01](bios.md) | Critical | BIOS call flags are overwritten before they are saved | **Fixed**; was reproduced (keyboard and disk) |
| [FS-01](filesystems.md) | Critical | ext4 sparse files are read wrongly, with no error | **Fixed**; was reproduced |
| [FS-02](filesystems.md) | Critical | btrfs decompression cache returns another file's data | **Fixed**; was reproduced |
| [FS-03](filesystems.md) | Critical | ext4 descriptor size overflows a 64-byte stack buffer | **Fixed**; was reproduced |
| [INST-01](installer.md) | Critical | `install-bios` can destroy a filesystem | **Fixed**; was reproduced |
| [INST-02](installer.md) | Critical | `--removable` overwrites a foreign fallback loader | **Fixed**; was reproduced |
| [INST-03](installer.md) | Critical | Firmware boot variables can be overwritten or lost | **Fixed**; was reproduced |
| [BIOS-02](bios.md) | High | Real-mode stack overlaps the disk packet and scratch buffer | **Fixed**; was reproduced |
| [BIOS-03](bios.md) | High | Kernel size and load area are never checked against memory | **Fixed**; was reproduced |
| [BIOS-05](bios.md) | High | `other = /dev/sdb1` chainloads partition 1 of the boot disk | **Partly fixed** |
| [FS-04](filesystems.md) | High | Unchecked arithmetic on on-disk values (64-bit) | **Fixed**; was reproduced |
| [FS-05](filesystems.md) | High | Bounds checks wrap on the 32-bit BIOS build | **Fixed**; was reproduced |
| [FS-06](filesystems.md) | High | FAT directory cycle hangs the loader | **Fixed**; was reproduced |
| [FS-07](filesystems.md) | High | FAT first cluster 1 underflows | **Fixed**; was reproduced |
| [CMN-01](loader-common.md) | High | A failed boot can trap the user forever | **Fixed** |
| [CMN-02](loader-common.md) | High | Whole-disk FAT volumes are invisible | **Fixed** |
| [CMN-03](loader-common.md) | High | Password protection fails open | **Fixed** |
| [UEFI-01](uefi.md) | High | One failed boot blocks later boots with an initrd | **Fixed** |
| [UEFI-02](uefi.md) | High | A stale initrd can go to the next entry | **Fixed** |
| [INST-04](installer.md) | High | ESP directory is mapped to the wrong partition | **Fixed** |
| [INST-05](installer.md) | High | `check` segfaults or fails on valid setups | **Fixed** |
| [INST-06](installer.md) | High | Disk naming requirement is not met | **Fixed** |
| [INST-07](installer.md) | High | Write failures can be reported as success | **Partly fixed** |
| [INST-08](installer.md) | High | Data after an older stage 2 is overwritten | **Fixed**; was reproduced |
| [INST-11](installer.md) | High | `config` writes wrong paths | **Fixed** |
| [INST-14](installer.md) | High | `isohybrid` writes blindly | **Fixed** |
| [BLD-01](build-tests-docs.md) | High | Everything that parses untrusted data ships without safety checks | **Fixed** |
| [BIOS-04](bios.md) | Medium | `kernel_end` ignores `pref_address` | **Fixed** |
| [BIOS-06](bios.md) | Medium | Chainload does not check the boot signature | **Fixed** |
| [BIOS-07](bios.md) | Medium | Promised configuration-partition record does not exist | **Fixed** |
| [BIOS-08](bios.md) | Medium | More than eight initrds fails | **Fixed** |
| [BIOS-09](bios.md) | Medium | A20 is enabled one way and never verified | **Fixed** |
| [BIOS-10](bios.md) | Medium | Direction flag is never cleared for Zig code | **Fixed** |
| [FS-08](filesystems.md) | Medium | Other hangs from corrupt metadata | **Fixed** |
| [FS-09](filesystems.md) | Medium | btrfs accepts stale or foreign tree blocks | **Fixed** |
| [FS-10](filesystems.md) | Medium | btrfs data has no mirror fallback | **Partly fixed** |
| [FS-11](filesystems.md) | Medium | Unknown or unreplayed on-disk state is read silently | **Fixed** |
| [FS-12](filesystems.md) | Medium | ext4 checksum verification can be skipped | **Partly fixed** |
| [FS-14](filesystems.md) | Medium | Compatibility bugs | **Fixed** |
| [CMN-04](loader-common.md) | Medium | Weak password handling | **Fixed** |
| [CMN-05](loader-common.md) | Medium | `LABEL=` and `UUID=` take the first match on any disk | **Partly fixed** |
| [CMN-06](loader-common.md) | Medium | Volume probe errors are hidden and permanent | **Partly fixed** |
| [CMN-07](loader-common.md) | Medium | Partition values overflow | **Fixed** |
| [CMN-10](loader-common.md) | Medium | Menu does not scroll and truncates silently | **Fixed** |
| [UEFI-04](uefi.md) | Medium | `other = windows` takes the first match on any FAT volume | **Fixed** |
| [UEFI-05](uefi.md) | Medium | Block device properties are trusted | **Fixed** |
| [UEFI-06](uefi.md) | Medium | Device tree copy uses boot-services memory | **Fixed** |
| [INST-09](installer.md) | Medium | BIOS boot partition beyond 4 MiB is refused | **Fixed** |
| [INST-10](installer.md) | Medium | 512-byte sectors are hardcoded | **Fixed** |
| [INST-12](installer.md) | Medium | `config` ordering and labels | **Fixed** |
| [INST-13](installer.md) | Medium | `config --force` replaces the file unsafely | **Fixed** |
| [INST-15](installer.md) | Medium | `check` misses real boot failures | **Partly fixed** |
| [BLD-02](build-tests-docs.md) | Medium | Tests do not reach the failing paths | **Partly fixed** |
| [BLD-03](build-tests-docs.md) | Medium | The package omits files its build needs | **Fixed** |
| [DOC-01](build-tests-docs.md) | Medium | Documentation disagrees with the code | **Fixed** |
| [BIOS-11](bios.md) | Low | Smaller issues | **Partly fixed** |
| [FS-13](filesystems.md) | Low | A failed read leaves a poisoned cache | **Fixed** |
| [CMN-08](loader-common.md) | Low | Config parser leaks on error | **Fixed** |
| [CMN-09](loader-common.md) | Low | Config parser accepts mistakes | **Partly fixed** |
| [CMN-11](loader-common.md) | Low | Old setup headers are over-copied | **Fixed** |
| [CMN-12](loader-common.md) | Low | `openFile` accepts non-regular files | **Fixed** |
| [UEFI-03](uefi.md) | Low | Failed attempts leak memory and images | **Fixed** |
| [UEFI-07](uefi.md) | Low | Smaller issues | **Partly fixed** |
| [INST-16](installer.md) | Low | Smaller issues | **Fixed** |
| [BLD-04](build-tests-docs.md) | Low | Test fixtures are regenerated through a fragile step | **Fixed** |
| [BLD-05](build-tests-docs.md) | Low | `elf2efi` trusts ELF offsets; size check needs GNU `stat` | **Fixed** |

## Where this stands

The report is complete.

- All 66 index rows match their entry headings and severities, and no ID reference is dangling.
- Source line references were checked against the source. One wrong range (BLD-05) was corrected.
- The ten parser reproductions were rerun using the setup steps in [repro/README.md](repro/README.md), with each filter run in a loop. All ten showed their bug.
- The disk-error half of BIOS-01 was reproduced after the first draft.
- The QEMU, UEFI and installer reproductions were each run once, with scripts that are summarised, not included, in the entries and repro notes.
- "Code review" entries have not had an independent second review.
- BIOS-01 is fixed, with two regression tests. On that code the unit tests (84/84) and all 19 QEMU scripts passed, including the AArch64 and RISC-V Linux boots. It has not been booted on real hardware.
- FS-01 and FS-02 are fixed, with three new unit tests. The two main tests failed on the old readers, and the third looped forever. With the fixes, the unit tests (87/87), the `fsread` package tests (6/6), the two original reproductions and all 19 QEMU scripts passed, including the AArch64 and RISC-V Linux boots.
- INST-01, INST-02, INST-03 and INST-08 are fixed; each entry records its tests and limits. With them, the unit tests (99/99), the `fsread` package tests (6/6) and all 20 QEMU scripts passed, including the AArch64 and RISC-V Linux boots.
- FS-03 to FS-07, BIOS-02 and BIOS-03 are fixed; each entry records its tests and limits. All 18 new damaged-metadata tests failed on the old readers (some only in the new 32-bit build), and both new BIOS scripts failed on the old loader. With the fixes, `zig build test` passed (92 passed and 1 skipped as 64-bit (the skipped test applies only to 32-bit), all 93 passed as 32-bit, and 26 installer tests) and all 22 QEMU scripts passed, including the AArch64 and RISC-V Linux boots. Nothing was tried on real hardware.
- Every remaining entry has since been worked through; each records what was reproduced, how it was fixed, its tests and its limits. Where a fix has no test, or a problem was not reproduced, the entry says so.
- On a fresh copy of the final code: `zig build test` passed (137 and 1 skipped as 64-bit, 138 as 32-bit, 35 installer tests), the `fsread` package tests passed (7/7), formatting was clean, all 30 QEMU scripts passed, including the AArch64 and RISC-V Linux boots, and `tests/package-files.sh` passed. Disks installed by 0.0.4 (MBR and GPT images) and its removable-media loaders for all four architectures were upgraded without warnings about old data.
- Salted passwords (CMN-04) came after that run. For release 0.0.5 it was all repeated on a fresh copy: 141 unit tests passed and 1 was skipped as 64-bit, 142 passed as 32-bit, plus 35 installer and 7 `fsread` tests; formatting, all 30 QEMU scripts and the package test passed.
- Nothing has been tried on real hardware, and the installer has not written to a real disk or to firmware variables.

## Left to do

- The parts listed as open in the partly fixed entries.
