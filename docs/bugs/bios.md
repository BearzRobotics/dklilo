# BIOS loader bugs

## BIOS-01: BIOS call flags are overwritten before they are saved
**Severity:** Critical · **Status:** Fixed (reproduced first: keyboard and disk read errors)

`src/bios/realmode.zig:171-188`. After `int`, the trampoline runs `xor ax, ax` and only later `pushfd`. `xor` clears CF and sets ZF, so every caller sees CF=0, ZF=1.

- `console.zig:202`: `int 16h AH=01h` always reads as "no key", so **the physical keyboard never works**. No menu use, no editor, no password, and "Press a key" can only be answered over serial.
- `disk.zig:70`: a failed `int 13h` read looks successful. Retries and reset never run, and whatever is in the bounce buffer is returned as disk data (a possibly corrupt kernel or initramfs).
- `disk.zig:16,22` and `stage2.zig:60`: the extension check, drive-parameter and E820 carry tests are dead.

**Reproduction:** QEMU, `prompt` and `timeout = 80`, three `sendkey down`. The shipped build counted down and booted. A build differing only in the position of `pushfd` stopped the countdown and redrew the menu. The order is also visible in the disassembled `stage2.bin`. No script in `tests/qemu/` uses `sendkey`, so they send no PS/2 keys.

**Disk reproduction:** a minimal fake bzImage, with QEMU `blkdebug` failing one sector in the middle of the file. The shipped build reported no error and printed `Starting kernel...`. The build with `pushfd` moved printed `read error: IoError` and `Boot failed`. Without the injected error both builds reached `Starting kernel...`.

**Fix (applied):** `pushfd` immediately after `int`/`cli`, popped into `0x6F1C` after the registers are stored. The text above describes release 0.0.4.

**Regression tests:** `tests/qemu/l3-bios-keyboard.sh` and `tests/qemu/l3-bios-disk-error.sh`. Both failed before the fix and passed after it. Neither needs a Linux kernel. With the fix, the unit tests (84/84) and all 19 QEMU scripts passed.

**Still to do:** boot on real BIOS hardware. Disk errors that were hidden before are now reported, and real firmware may behave differently from SeaBIOS.

## BIOS-02: Real-mode stack overlaps the disk packet and scratch buffer
**Severity:** High · **Status:** Fixed (reproduced first, with a test option ROM)

`realmode.zig:13-26,161`. The stack starts at `0x6F00` and grows down through the disk address packet (`0x6E00`) and the scratch buffer (`0x6C00`). A BIOS handler using more than about 240 bytes of stack can overwrite the packet while using it; deeper use hits E820 and EDD results. QEMU would not necessarily show this.

**Reproduction:** `tests/qemu/deep-stack-rom.py` makes an option ROM that hooks `int 13h` and writes 1 KiB onto the caller's stack before passing the call on. With it, 0.0.4's loader reported `no readable filesystem found`: its own disk requests were overwritten. No real BIOS has been observed doing this.

**Fix (applied):** the real-mode stack now grows down from `0x6C00`, below the scratch buffer, disk address packet and register block. The line numbers above describe release 0.0.4.

**Regression test:** `tests/qemu/l3-bios-stack.sh`. Needs no Linux kernel.

## BIOS-03: Kernel size and load area are never checked against memory
**Severity:** High · **Status:** Fixed (reproduced first)

`stage2.zig:20-27,143-153`. The kernel goes to `0x100000` unchecked. The stack top is `0x1F00000` and the heap starts at `0x2000000`, so a protected-mode image near 30 MiB (large debug kernel, built-in initramfs) overwrites the live stack, then the heap holding filesystem state. E820 is never used to confirm that the kernel, stack or heap ranges are usable RAM. With no initramfs there is no memory check at all.

**Reproduction:** `tests/qemu/l3-bios-memory.sh` with fake kernels. On the old loader: with 24 MiB of RAM nothing was printed; with a 31 MiB kernel it stopped after `Loading`; and with 64 MiB of RAM and a kernel needing 200 MiB to unpack, it printed `Starting kernel...`.

**Fix (applied):** a new `stage2_early`, on a temporary low stack, checks against E820 that the stack and heap are usable RAM before they are used. `bootLinux` refuses a protected-mode kernel over 29 MiB (it would reach the stack), and checks that the load area and the `init_size` area are usable RAM. An initramfs of 4 GiB or more is refused, as is a kernel file with 4 GiB or more of protected-mode code (its size used to be truncated). The text above describes release 0.0.4.

**Regression tests:** the script above, and unit tests for the range check and the oversized kernel.

**Behaviour to know about:** the loader now says "not enough memory" unless RAM covers 30-31 MiB and 32-40 MiB, about 41 MiB in all. A smaller machine that happened to use little of the heap is now refused. A BIOS with no E820 map skips the RAM checks.

**Still open:** the run-address check starts at 16 MiB and ignores `pref_address` (BIOS-04). Not tested on real hardware.

## BIOS-04: `kernel_end` ignores `pref_address`
**Severity:** Medium · **Status:** Fixed (reproduced first)

`stage2.zig:142-144` assumes a relocatable kernel runs at 16 MiB. The boot protocol derives the runtime start from `pref_address` for non-relocatable kernels, and a kernel may prefer a higher address. The initramfs can then be placed where decompression overwrites it. `kernel_alignment` is also passed to `alignForward` without a power-of-two check.

**Fix (applied):** the run address now follows the boot protocol (`pref_address`, relocatable or not, with a bad alignment ignored), still no lower than 16 MiB for a relocatable kernel, and the sums saturate. The line numbers above describe release 0.0.4.

**Regression tests:** a kernel preferring 200 MiB in `l3-bios-memory.sh` (the old loader started it with 64 MiB of RAM) and a unit test.

## BIOS-05: `other = /dev/sdb1` chainloads partition 1 of the boot disk
**Severity:** High · **Status:** Partly fixed (reproduced first)

`stage2.zig:189-197` keeps only the trailing digits. The disk name is discarded, so the wrong OS can start. SPEC 5.6 says the installer resolves such names; no code does. `check` reports every chain entry `ok` unverified.

**Fixed:** the loader accepts only a number or a name under `/dev/` (it used to take any trailing digits), and for a `/dev` name says which partition of the boot disk it is starting. `check` fails if the partition doesn't exist, and warns that the disk in a `/dev` name isn't checked. On the running system, when it can open the disks, it compares them and fails if they differ.

**Regression tests:** `tests/qemu/l3-bios-hardening.sh` and `l6-check.sh`. The comparison of real disks needs root and was not run.

**Open:** the loader still can't tell which disk a `/dev` name means, so someone who doesn't run `check` can still get the boot disk's partition, now with a message.

## BIOS-06: Chainload does not check the boot signature
**Severity:** Medium · **Status:** Fixed (reproduced first)

`stage2.zig:202-222` jumps to any 512 bytes, including zeros, without testing `0x55AA`. The LBA and length casts to `u32` (218-220) are also unchecked for partitions beyond 2 TiB.

**Fix (applied):** a sector without `0x55AA` is not started, and a partition starting beyond 32-bit sector numbers is refused. The line numbers above describe release 0.0.4.

**Regression test:** `tests/qemu/l3-bios-hardening.sh`, "a partition without a boot sector isn't started". The 32-bit limit is not tested.

## BIOS-07: Promised configuration-partition record does not exist
**Severity:** Medium · **Status:** Fixed (reproduced first)

SPEC 5.3 says the installer records the config partition (GUID, or MBR signature and number). `plan.zig` writes only the stage 2 block list. Stage 2 takes the first matching file in scan order, so multi-boot disks can load another installation's config.

**Fix (applied):** `install-bios` records the partition (GPT GUID, or MBR signature and number) inside stage 2, and the BIOS loader looks there first, then searches as before, saying so. The installer chooses among several configurations as the manual describes; `--config-partition N|none` overrides it. The line numbers above describe release 0.0.4.

**Regression tests:** `tests/qemu/l3-bios-config-record.sh` (MBR and GPT), whose cases that need a record failed before, and unit tests for the format and the choice.

**Behaviour to know about:** after moving the configuration to another partition, run `install-bios` again; until then the loader finds it by searching unless the old partition still has one. The choice by mounted filesystem was tested with a made-up mount table on an image, not on real disks.

## BIOS-08: More than eight initrds fails
**Severity:** Medium · **Status:** Fixed (reproduced first)

`stage2.zig:134-135` has a fixed array of 8 and returns `NotFound` with no message. UEFI and `check` have no such limit.

**Fix (applied):** the list of initramfs files comes from the heap, with a message if that fails. The line numbers above describe release 0.0.4.

**Regression test:** nine files in `tests/qemu/l3-bios-hardening.sh`, checking the length and checksum the kernel receives.

## BIOS-09: A20 is enabled one way and never verified
**Severity:** Medium · **Status:** Fixed (by review and throwaway builds)

`realmode.zig:103-106` only uses port `0x92`. There is no wrap test and no `int 15h AX=2401h` or keyboard-controller fallback. On hardware where it fails, loads above 1 MiB alias.

**Fix (applied):** A20 is tested first and left alone if open; otherwise the BIOS call, the keyboard controller and port `0x92` are tried in turn, testing after each, and failure is reported. The line numbers above describe release 0.0.4.

**Tests:** QEMU leaves A20 open, so the suite only covers that case. In throwaway builds that closed A20 first, boot succeeded with all methods, with only the keyboard controller or only port `0x92` among the fallbacks, and with the BIOS call removed; with all three removed the message appeared. Not tested on hardware.

## BIOS-10: Direction flag is never cleared for Zig code
**Severity:** Medium · **Status:** Fixed (reproduced first, with a test option ROM)

Neither `_start` nor the return from `bios_int` runs `cld`; only `jump_kernel` does. The x86 C ABI requires DF=0, and the BIOS is not guaranteed to leave it clear.

**Fix (applied):** `cld` on entry and after every BIOS call. The line numbers above describe release 0.0.4.

**Regression test:** a BIOS that returns with DF set, in `tests/qemu/l3-bios-hardening.sh` (`bios-quirks.s`).

## BIOS-11: Smaller issues
**Severity:** Low · **Status:** Partly fixed

- `stage2.ld` assertion `ADDR(.text) + 0x400 <= 0x10000` is always true, so it does not keep real-mode code below 64 KiB.
- The EBDA (`int 12h`) is not checked before using `0x88000-0x91800`.
- Stage 1 does not verify the `DKLILOS2` magic or retry reads; a stale block list jumps into arbitrary bytes. A zero count does too.
- The command line is silently truncated (`stage2.zig:167-168`), which can drop options.
- `puts` never scrolls; later messages overwrite row 25.
- `say` drops any message over 200 bytes, including long path errors.
- `serial =` is parsed and ignored (COM1, 115200). A CR LF terminal sends two Enters.
- A failed E820 gives the kernel an empty map, with no fallback.
- An empty initrd with total size 0 forms a pointer to address 0 (`stage2.zig:155-161`).

**Fixed, with a test that failed first** (`tests/qemu/l3-bios-hardening.sh`): too little conventional memory is reported; stage 1 retries reads and refuses what isn't stage 2; a cut command line is reported; and a BIOS without E820 gets a map built from older calls, so the kernel still boots.

**Fixed, not tested by a new failing case:** the linker script now checks where the real-mode code really ends; an empty initramfs no longer forms a pointer to address 0; long messages are cut, not dropped; the screen scrolls; a CR LF from a serial terminal is one Enter. 0.0.4, given the E820 failure, said `not enough memory for the initramfs`: with no map it had nowhere to put one.

**Open:** `serial =` is still ignored.
