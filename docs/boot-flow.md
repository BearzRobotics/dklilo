# How dklilo boots

This walks through both boot paths from power-on to the kernel. File names
refer to the source tree.

## Pieces

| Piece | Source | Runs in |
|---|---|---|
| Stage 1 (MBR, 440 bytes) | `src/bios/stage1.zig` | 16-bit real mode |
| Stage 2 (BIOS loader) | `src/bios/stage2.zig`, `realmode.zig` | 32-bit protected mode |
| CD boot sector | `src/bios/cdstub.zig` | 16-bit real mode |
| UEFI loader | `src/uefi/main.zig` | UEFI boot services, x86_64 |
| Shared code | `src/common/` | both loaders and the `dklilo` tool |

The shared code is the point of the design: configuration parsing, the menu,
partition tables and every filesystem reader are the same code in the BIOS
loader, the UEFI loader and the Linux installer, so the installer's `check`
command proves a configuration with the code that will boot it.

## BIOS

1. **Firmware** loads sector 0 of the boot disk to `0x7C00` and jumps there
   with the drive number in `dl`. That sector is **stage 1**.
2. **Stage 1** forces `cs = 0`, then reads stage 2 with `int 13h` extended
   reads (retrying a failed one, and refusing to jump into anything that
   doesn't carry stage 2's signature). Where stage 2 lives is the only block list dklilo keeps: one
   extent (a 64-bit LBA and a 16-bit sector count) at MBR offset 416, written
   by `dklilo install-bios`. Stage 2 is loaded at `0x8000` and entered with
   `dl` still holding the drive.
3. **Stage 2's first code** (`realmode.zig`) makes sure A20 is on (if it
   isn't, it tries the BIOS call, the keyboard controller and port `0x92`,
   testing after each), loads a flat GDT and sets `CR0.PE`. From here the CPU runs flat 32-bit
   code and Zig takes over. `stage2_early` runs first, on a temporary stack
   in low memory: it checks that there is enough conventional memory, and
   the memory map (E820, or one made from older BIOS calls) for RAM where the
   stack and heap go, and stops with a message if not. Then `stage2_main`.
4. **BIOS services** are still needed for the disk, keyboard and screen. The
   trampoline `bios_int(vec)` drops to real mode (via a 16-bit protected-mode
   segment, so the segment limits are right), runs `int vec` with registers
   taken from a fixed block at `0x6F00`, and comes back. Interrupts are only
   enabled while a BIOS call runs.
5. **Finding the configuration.** Stage 2 asks the BIOS for the boot drive's
   geometry (`int 13h ah=48h`), reads its partition table (MBR with extended
   partitions, or GPT) and probes each partition for ext2/3/4, btrfs, FAT or
   ISO 9660. It looks first on the partition `install-bios` recorded inside
   stage 2. Failing that, it looks for `\EFI\dklilo\dklilo.conf` on FAT
   volumes, then `/boot/dklilo.conf` and `/dklilo.conf`. No configuration, or a broken one,
   leads to a prompt where a kernel path and command line can be typed.
6. **The menu** draws on the screen and on COM1 at the same time and reads
   keys from both. `m` asks for a kernel path and command line (after the
   password, if there is one). Once a boot has failed or returned, the menu
   always waits for a key.
7. **Linux** (`bootLinux`): read the setup header from the kernel file,
   require boot protocol 2.10 or newer; read the protected-mode kernel
   straight from the filesystem to `0x100000`; place the initramfs as high as
   `initrd_addr_max` and the memory map allow, above where the kernel will
   unpack itself; refuse a kernel that doesn't fit; fill in `boot_params`
   (`src/common/linux/bootparams.zig`) at `0x90000` with the command line at
   `0x91000`; then `jump_kernel`: interrupts off, `cs = 0x10`, `ds/es/ss =
   0x18`, `esi = boot_params`, jump to `code32_start`. The kernel switches to
   64-bit mode itself.
8. **Windows** (`chainload`): load the Windows partition's boot sector to
   `0x7C00` (if it ends in `0x55AA`) with a copy of its MBR partition entry
   at `0x7BE`, return to real mode and `jmp 0000:7C00` with `dl` set to the
   drive.

### From a CD or a USB stick

The BIOS loads the first 2048 bytes of `eltorito.bin` (the CD boot sector)
and enters it with the CD drive in `dl`. It finds stage 2 in the same file
using the *boot info table* `xorriso -boot-info-table` fills in, reads it with
2048-byte `int 13h` reads and jumps to it. A hybrid ISO written to a USB
stick boots through stage 1 instead, which `dklilo isohybrid` points at the
same stage 2 copy inside the ISO.

## UEFI

1. **Firmware** runs the loader for its architecture from the ESP
   (`\EFI\BOOT\BOOT<ARCH>.EFI`, or `\EFI\dklilo\dklilo<ARCH>.efi` through a boot
   entry; `<ARCH>` is `X64`, `AA64`, `ARM` or `RISCV64`). The rest of this section is the
   same on every architecture. On ARM and RISC-V the first thing the loader does
   is copy the firmware's device tree into memory of its own
   (docs/zig-uefi-targets.md explains why).
2. **Disks.** dklilo asks the firmware for every `BlockIo` handle that is a
   whole disk and reads those with its own partition and filesystem code.
   The firmware's partition handles are ignored. Which disk it started from
   is found by comparing device paths.
3. **Configuration and menu** work exactly as on BIOS. The firmware console
   already includes serial.
4. **Linux** is started as an EFI application: the kernel file is read into
   memory, `LoadImage` is given the buffer, the command line becomes the
   image's load options (UTF-16), and the initramfs is offered through a
   `LoadFile2` protocol installed on a handle whose device path carries the
   `LINUX_EFI_INITRD_MEDIA_GUID`. This is the interface kernels since 5.8 use;
   it needs a kernel built with `CONFIG_EFI_STUB`. If the kernel returns, or
   can't be started, the protocol is removed again.
5. **Windows**: `\EFI\Microsoft\Boot\bootmgfw.efi` is looked for on the FAT
   volume dklilo came from, then the rest of that disk, then other disks that
   the firmware exposes, and started with `LoadImage` from its *device
   path* (not from memory), because boot managers locate their own volume
   from it.

## When something is wrong

The loaders and the tool are built `ReleaseSafe`. If a safety check fails,
the BIOS loader prints `dklilo: internal error: ...` and halts; the UEFI
loader prints it and returns to the firmware, which can try its next boot
option.

## Memory map (BIOS)

```
0x00500-0x06BFF  real-mode stack (grows down from 0x6C00)
0x06C00          scratch buffer for BIOS results
0x06E00          disk address packet
0x06F00          register block for BIOS calls
0x08000-0x87FFF  stage 2 (at most 512 KiB), its zeroed data, and the 16 KiB
                 stack used until the memory check has passed
0x88000-0x8FFFF  32 KiB disk bounce buffer
0x90000          boot_params, 0x91000 kernel command line
0x100000         kernel
0x1E00000        stack (grows down from 0x1F00000)
0x2000000        8 MiB heap
(top of RAM)     initramfs
```
