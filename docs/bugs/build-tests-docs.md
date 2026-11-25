# Build, test and documentation bugs

## BLD-01: Everything that parses untrusted data ships without safety checks
**Severity:** High · **Status:** Code review

`build.zig` uses `ReleaseSmall` for stage 2, the UEFI loaders (including the RISC-V object) and the installer. Index, overflow and cast errors become undefined behaviour. `ai/AGENTS.md` section 10 requires the opposite for malformed input. Fixing the individual bugs is the first duty; then consider `ReleaseSafe` where the 512 KiB limit allows (size not measured).

## BLD-02: Tests do not reach the failing paths
**Severity:** Medium · **Status:** Code review

The unit suite passed here (84/84) while the bugs in this folder exist.
- Mutation tests do not repair checksums, so checksummed parsers are rarely reached; the btrfs tests only flip bytes.
- No multi-leaf sparse ext4 file, interleaved btrfs reads, FAT through `addDisk`, empty-config `check`, or second boot attempt.
- Parsers are tested 64-bit Debug only; stage 2 is 32-bit ReleaseSmall. (With the FS-05 fix they also run as 32-bit Debug on x86_64 hosts. `ReleaseSmall` is still not tested.)
- No PS/2 keyboard test and no disk-error test (both added with the BIOS-01 fix).
- `l11-aarch64.sh` and `l12-riscv-arm.sh` print `SKIP` for the Linux boot but **exit 0** when the kernel for it is missing, so a runner reports `PASS`. `run-all.sh` shows only each script's last three lines and exit code.
- An ordinary run executes each fuzz target only as a smoke test, which falls short of SPEC 8's intent.
- Missing fixtures or tools cause skips (`FileDisk.open` returns `SkipZigTest`).

## BLD-03: The package omits files its build needs
**Severity:** Medium · **Status:** Code review

`build.zig.zon` `.paths` lacks `tools/` and `tests/`, which `build.zig` references (`elf2efi.zig`, fixture script, test programs).

## BLD-04: Test fixtures are regenerated through a fragile step
**Severity:** Low · **Status:** Code review; slowness observed

The shell step builds many images, and its path `.zig-cache/dklilo-fixtures` ignores `--cache-dir` and depends on the working directory. Interrupted runs left `.dklilo-fixtures.<pid>` folders and a running `mkfs`. The very slow runs seen here were due to a stalled disk, not dklilo: on another disk the fixture step took about a minute.

## BLD-05: `elf2efi` trusts ELF offsets; size check needs GNU `stat`
**Severity:** Low · **Status:** Code review

`tools/elf2efi.zig:75-117` indexes with unchecked header values (a build-time input, built `ReleaseSafe`). `build.zig` uses `stat -c%s`. The RISC-V output's section alignment was checked and is correct.

## DOC-01: Documentation disagrees with the code
**Severity:** Medium · **Status:** Code review

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
