# Build, test and documentation bugs

## BLD-01: Everything that parses untrusted data ships without safety checks
**Severity:** High · **Status:** Fixed

`build.zig` uses `ReleaseSmall` for stage 2, the UEFI loaders (including the RISC-V object) and the installer. Index, overflow and cast errors become undefined behaviour. `ai/AGENTS.md` section 10 requires the opposite for malformed input. Fixing the individual bugs is the first duty; then consider `ReleaseSafe` where the 512 KiB limit allows (size not measured).

**Fix (applied):** stage 2, the four UEFI loaders and the tool are built `ReleaseSafe`. The BIOS loader reports a failed check and halts; the UEFI loader reports it and exits to the firmware, which can try its next boot option. Debug data is stripped from the tool and the RISC-V loader, and the RISC-V loader also drops unwind tables, to stay within 512 KiB. Stage 2 grew from about 155 KiB to about 233 KiB; the largest loader is RISC-V at about 475 KiB. Stage 1 and the CD boot sector are assembly.

**Found while doing this:** with the checks on, the early memory check could need up to 5,024 bytes of stack (a bound that includes the failure path) where it had 3,288, above data the BIOS calls use. It now has its own 16 KiB, placed by the linker script.

**Tests:** both failure handlers were triggered once in throwaway builds with a planted out-of-bounds index, on SeaBIOS and OVMF; that test is not in the suite.

**Behaviour to know about:** `install-bios` now needs about 470 sectors for stage 2 before the first partition or in the BIOS boot partition, instead of about 310. The usual 1 MiB is enough. A fault that used to go unnoticed now stops the boot with a message.

## BLD-02: Tests do not reach the failing paths
**Severity:** Medium · **Status:** Partly fixed

The unit suite passed here (84/84) while the bugs in this folder exist.
- Mutation tests do not repair checksums, so checksummed parsers are rarely reached; the btrfs tests only flip bytes.
- No multi-leaf sparse ext4 file, interleaved btrfs reads, FAT through `addDisk`, empty-config `check`, or second boot attempt.
- Parsers are tested 64-bit Debug only; stage 2 is 32-bit ReleaseSmall. (With the FS-05 fix they also run as 32-bit Debug on x86_64 hosts. `ReleaseSmall` is still not tested.)
- No PS/2 keyboard test and no disk-error test (both added with the BIOS-01 fix).
- `l11-aarch64.sh` and `l12-riscv-arm.sh` print `SKIP` for the Linux boot but **exit 0** when the kernel for it is missing, so a runner reports `PASS`. `run-all.sh` shows only each script's last three lines and exit code.
- An ordinary run executes each fuzz target only as a smoke test, which falls short of SPEC 8's intent.
- Missing fixtures or tools cause skips (`FileDisk.open` returns `SkipZigTest`).

**Fixed:** the cases listed above now have tests: checksum-repairing btrfs damage, multi-leaf sparse ext4, interleaved btrfs reads, FAT through `addDisk`, an empty configuration with `check`, a second boot attempt, 32-bit reader runs, a PS/2 keyboard and disk errors. `l11` and `l12` exit 77 when their Linux boot is skipped; `tests/run-all.sh` shows the end of a failing script, lists skips, and runs the `fsread` package tests.

**Open:** an ordinary run still executes each fuzz target once; missing optional tools still cause skips; random damage to checksummed ext4 metadata is still not re-checksummed; and the unit tests are Debug builds of code that ships `ReleaseSafe` (both check safety).

## BLD-03: The package omits files its build needs
**Severity:** Medium · **Status:** Fixed (reproduced first)

`build.zig.zon` `.paths` lacks `tools/` and `tests/`, which `build.zig` references (`elf2efi.zig`, fixture script, test programs).

**Fix (applied):** `tools` and `tests` are in `.paths`.

**Regression test:** `tests/package-files.sh` builds and tests from only the listed paths. It failed before (`elf2efi.zig` and the test programs were missing). `run-all.sh` does not run it.

## BLD-04: Test fixtures are regenerated through a fragile step
**Severity:** Low · **Status:** Fixed (reproduced first: the leftover folder)

The shell step builds many images, and its path `.zig-cache/dklilo-fixtures` ignores `--cache-dir` and depends on the working directory. Interrupted runs left `.dklilo-fixtures.<pid>` folders and a running `mkfs`. The very slow runs seen here were due to a stalled disk, not dklilo: on another disk the fixture step took about a minute.

**Fix (applied):** the test images are an output of the build step, so they are in whatever cache directory the build uses and the tests run inside it; the script cleans up when stopped by a signal. Stopping 0.0.4's script left its temporary folder behind; the fixed one left nothing.

**Behaviour to know about:** the images are now cached until the script changes, which makes repeat test runs much faster. After installing an optional tool such as `mkfs.btrfs`, clear the cache to get its images.

## BLD-05: `elf2efi` trusts ELF offsets; size check needs GNU `stat`
**Severity:** Low · **Status:** Fixed (reproduced first)

`tools/elf2efi.zig:75-117` indexes with unchecked header values (a build-time input, built `ReleaseSafe`). `build.zig` uses `stat -c%s`. The RISC-V output's section alignment was checked and is correct.

**Fix (applied):** `elf2efi` checks every offset and size from the ELF before using it, and the size check uses `wc -c`. With headers or segments pointing outside the file, the old tool panicked; it now reports which. Not run on a system without GNU tools.

## DOC-01: Documentation disagrees with the code
**Severity:** Medium · **Status:** Fixed

| Claim | Reality |
|---|---|
| README: refuses to overwrite unrecognised loaders or data | Was INST-01, INST-02, INST-08; fixed |
| README, manual: every write is listed and confirmed | `isohybrid` and `mkiso-images` do not confirm |
| SPEC 5.3: installer records the config partition | BIOS-07 |
| SPEC 5.3: a broken config never leaves the machine unbootable | CMN-01 |
| SPEC 5.4: checksum mismatches reported, RAID1 falls back | FS-10, FS-12 |
| SPEC 5.6: loader presence checked, installer resolves names | Only the NTFS signature is checked; BIOS-05 |
| SPEC 5.7: `by-*` names supported | INST-06 |
| SPEC 8: errors, never hangs or crashes | FS-03, FS-06, FS-07 |
| SPEC 7: `src/bios/main.zig`; status line "L0-L7" | File is `stage2.zig`; README says loopback ISO is done |
| Manual: `serial =` | Ignored |

**Resolved:** the claims about overwriting, confirmation, the configuration record (BIOS-07), recovery from a broken configuration (CMN-01), `by-*` names, hangs and crashes, and `serial =` are now true or were corrected. In `SPEC.md`, 5.3, 5.4, 5.6, 7, 8 and the status line were changed to describe what is built; 5.1 gained the build mode, and 5.3 and 9a the new behaviour. Where the code does less than was promised (data checksums, hashed-directory checksums, `/dev` names for chainloading), the specification now says so instead.
