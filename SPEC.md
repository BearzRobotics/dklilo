# dklilo — Specification

Status: **Draft v0.2**. Anything marked **OPEN** is an undecided question.
Resolve it here before writing code that depends on it.

---

## 1. Vision

A modern LILO: a small, understandable boot loader with LILO's simple
configuration file, written in Zig, that boots Linux and Windows on both BIOS
and UEFI machines.

LILO was loved because it was simple and hated because it was fragile. Its
fragility came from one design choice: it never read a filesystem. The
installer recorded the disk block numbers of each kernel in a map file, so
every kernel update, file move or defragment silently broke booting until
`lilo` was run again. dklilo keeps LILO's simplicity and drops that design.
It reads ext2/3/4, btrfs and FAT itself at boot time, so the configuration
and kernels can change freely without reinstalling anything.

```
# /boot/dklilo.conf
timeout = 50                     # tenths of a second, as in LILO
default = dkrescue
serial  = 0,115200

image   = /boot/vmlinuz-6.19-dkrescue
    label  = dkrescue
    root   = PARTUUID=4a6f8c21-02
    append = "ro quiet"

image   = /boot/vmlinuz-6.19-dkrescue
    label  = dkrescue-safe
    root   = PARTUUID=4a6f8c21-02
    append = "ro nomodeset"

other   = windows                # finds Windows automatically
    label  = Windows
```

### 1.1 Relationship to LILO

- The original LILO 24.2 source and Slackware's patches (in `original/`) are
  **reference material**, not a code base. dklilo is a new implementation.
  LILO's behaviour and configuration syntax are the model; its code is not
  ported.
- The configuration file keeps LILO's syntax and keyword names wherever the
  meaning is unchanged, so a LILO user can read it immediately.
- Slackware's NVMe and `/dev/disk/by-id` (with colons) patches show what
  real systems need from the installer's device handling. Both are
  requirements here (see 5.6).

## 2. Goals and non-goals

### Goals (v1)

- Boots Linux on **BIOS** (MBR and GPT disks) and **UEFI** (x86_64).
- Reads kernels, initramfs files and its own configuration from **ext2/3/4,
  btrfs and FAT** at boot time. No block maps, no reinstall after a kernel
  update.
- **Boots Windows**: by chainloading Windows Boot Manager on UEFI, and by
  chainloading the Windows partition's boot sector on BIOS.
- A text menu with a timeout, a default entry, and a line editor for
  changing the kernel command line at boot.
- Works over a **serial console** as well as the screen.
- Boots the DKRescue **hybrid ISO** from DVD and USB on both firmware types.
- Written in Zig 0.17.0, with no C and no separate assembler (see 3.1).

### Non-goals (v1)

These are explicitly out of scope. Adding any of them requires changing this
spec first.

- **Secure Boot.** dklilo isn't signed, so machines with Secure Boot on must
  turn it off. (A Windows install on such a machine still boots normally from
  its own boot manager.)
- **Graphical menus, themes, fonts, mouse support.**
- **Encrypted `/boot`** (LUKS) and `/boot` on **LVM or software RAID**. The
  kernel and initramfs must be on a plain partition.
- **btrfs RAID5/6 and RAID0** for the filesystem holding the kernel. Single,
  DUP and RAID1 are supported (see 5.4).
- **Reading NTFS or XFS.** Windows is booted by chainloading, which doesn't
  need NTFS.
- **Network boot**, **Multiboot**, **32-bit (i386) kernels**, and
  architectures other than x86_64. aarch64 UEFI is a possible later goal.

## 3. Stack

| Layer | Choice |
|---|---|
| Language | Zig **0.17.0**, pinned in `build.zig.zon` |
| BIOS stage 1 | 16-bit real-mode code as global `asm` blocks in `.zig` files |
| BIOS stage 2 | Zig, `x86-freestanding`, 32-bit protected mode |
| UEFI loader | Zig, `x86_64-uefi`, using `std.os.uefi` |
| Installer and tools | Zig, `x86_64-linux-none`, static, no libc |
| Decompression | `std.compress.flate` (zlib), `std.compress.zstd`, and dklilo's own LZO decoder |
| Dependencies | None |
| License | MIT (see `LICENSE`) |

### 3.1 What "pure Zig" means here

Everything is Zig source built by `zig build`, with no C files and no
external assembler. One part can't be ordinary Zig: the BIOS starts the
machine in 16-bit real mode, and Zig doesn't generate 16-bit code. So:

- **Stage 1** (the 440 bytes in the MBR) and the **real-mode trampoline**
  that stage 2 uses to call BIOS services are written as `.code16` assembly
  inside `comptime { asm(...); }` blocks in `.zig` files. Zig's built-in
  assembler handles them.
- Everything else (the filesystems, configuration, menu, and both Linux boot
  protocols) is ordinary Zig, shared between the BIOS and UEFI builds.

Every assembly block carries a comment explaining what each instruction
sequence is for, under the same documentation standard as the rest of the
code (see 8).

## 4. Architecture

### 4.1 Build artifacts

| Artifact | What it is |
|---|---|
| `stage1.bin` | 440-byte MBR boot code (BIOS) |
| `stage2.bin` | BIOS loader, a flat binary, loaded by stage 1 |
| `dkliloX64.efi` | UEFI loader (PE32+ application) |
| `eltorito.bin` | BIOS boot image for the ISO (stage 2 with a CD-specific start) |
| `dklilo` | The installer and checking tool, run under Linux |

### 4.2 Shared modules

The same code runs in the loaders and in the Linux tool. That's what makes it
testable: the filesystem readers are exercised against disk images in
ordinary unit tests long before they run on bare metal.

| Module | Job |
|---|---|
| `blockdev` | One interface: read N sectors at LBA. Backed by BIOS `int 13h`, UEFI `BlockIo`, or a file under Linux. |
| `part` | MBR (including extended partitions) and GPT parsing. |
| `fs/ext4`, `fs/btrfs`, `fs/fat`, `fs/iso9660` | Read-only filesystem readers (5.4). |
| `compress/lzo` | LZO decompression for btrfs. |
| `config` | Parser for `dklilo.conf` (5.2). |
| `menu` | The menu and command-line editor, drawn through a small console interface. |
| `console` | Screen and serial output, keyboard and serial input, behind one interface. |
| `linux/bootparams` | The x86 Linux boot protocol structures (5.5). |

### 4.3 Boot flow

**BIOS:**

1. The firmware loads the MBR to `0x7C00`. Stage 1 loads stage 2 using a
   short list of LBAs the installer wrote into it (stage 2's own location
   is the only block list dklilo keeps).
2. Stage 2 switches to 32-bit protected mode. When it needs the BIOS (disk
   reads, memory map, keyboard, video), it drops briefly to real mode
   through the trampoline.
3. Stage 2 finds the partition holding `dklilo.conf`, reads it, and shows
   the menu.
4. For Linux: it loads the kernel and initramfs, fills in `boot_params`,
   and jumps to the kernel's 32-bit entry point (5.5).
   For Windows: it loads the target partition's boot sector to `0x7C00` and
   jumps to it in real mode, with `DL` set to the drive number.

**UEFI:**

1. The firmware runs `dkliloX64.efi` from the EFI System Partition.
2. It finds `dklilo.conf` (5.3) and shows the menu.
3. For Linux: it reads the kernel with dklilo's own filesystem code through
   `BlockIo`, starts it as an EFI application with `LoadImage`/`StartImage`
   (the kernel's EFI stub), passes the command line as load options, and
   provides the initramfs through the `LINUX_EFI_INITRD_MEDIA` `LoadFile2`
   protocol (5.5).
   For Windows: it starts `\EFI\Microsoft\Boot\bootmgfw.efi` from the ESP
   with `LoadImage`/`StartImage`.

## 5. Behaviour

### 5.1 Size limits

| Artifact | Limit | Why |
|---|---|---|
| `stage1.bin` | 440 bytes | The MBR code area before the disk signature. |
| `stage2.bin` | 512 KiB | Must fit in the 1 MiB gap after the MBR, or in a BIOS boot partition. |
| `dkliloX64.efi` | 512 KiB | Keeps the ESP footprint small; enforced by a build check. |

### 5.2 Configuration file

Syntax follows LILO: `key = value`, one per line; `#` starts a comment;
`image` and `other` begin a new boot entry, and the indented lines after
them belong to it.

**Global keys:**

| Key | Meaning |
|---|---|
| `timeout` | Tenths of a second before the default boots. `0` boots immediately; absent means wait forever. |
| `default` | Label of the default entry. Absent means the first entry. |
| `prompt` | Always show the menu, even with one entry. |
| `serial` | `port,baud` for a serial console, used alongside the screen. |
| `password` | Optional password required to edit a command line (stored as a SHA-256 hash, never plain text). |

**Entry keys:**

| Key | Applies to | Meaning |
|---|---|---|
| `image` | Linux | Path to the kernel (see paths, below). |
| `label` | both | Name shown in the menu. Must be unique. |
| `root` | Linux | Passed to the kernel as `root=`. |
| `append` | Linux | Extra kernel command-line text. |
| `initrd` | Linux | Path to the initramfs. May be given more than once; files are concatenated. |
| `subvol` | Linux | btrfs subvolume holding `image` and `initrd`, if not the default. |
| `other` | chainload | `windows` to find Windows Boot Manager automatically, or a partition (BIOS) / EFI file path (UEFI). |
| `restricted` | both | Editing this entry's command line needs `password`. |

**Paths** are absolute paths on a filesystem. Without a prefix they refer to
the filesystem `dklilo.conf` was read from. A prefix selects another one:
`LABEL=boot:/vmlinuz`, `UUID=…:/vmlinuz`, `PARTUUID=…:/vmlinuz`.

The kernel can't resolve `root=LABEL=…` or `root=UUID=…` without an
initramfs, so `dklilo check` warns when `root=` uses either and the entry
has no `initrd`. `PARTUUID=` works without one.

### 5.3 Finding the configuration

- **BIOS:** the installer records the partition holding `dklilo.conf` by
  GPT partition GUID, or MBR disk signature plus partition number. Stage 2
  looks there; if that fails, it searches every partition on the boot disk
  for `/boot/dklilo.conf` and then `/dklilo.conf`.
- **UEFI:** first `\EFI\dklilo\dklilo.conf` on the ESP, then
  `/boot/dklilo.conf` on every partition of the boot disk.
- If no configuration is found, dklilo shows a prompt where a kernel path
  and command line can be typed by hand. A broken config never leaves the
  machine unbootable.

### 5.4 Filesystems

All readers are read-only and never write to the disk.

- **ext2/3/4:** block maps and extents, `64bit`, `flex_bg`, inline data,
  and htree directories (read as plain directories, which htree allows).
  `metadata_csum` checksums are verified, and a mismatch is reported rather
  than silently ignored.
- **btrfs:** superblock, the system chunk array and chunk tree, the root
  tree, subvolumes, inline and regular extents, and zlib, LZO and zstd
  compression. Profiles: single, DUP and RAID1 (reading the first good copy,
  falling back to the mirror on a checksum error).
- **FAT12/16/32** with long file names: needed for the ESP.
- **ISO 9660** with Rock Ridge: needed to boot the DKRescue ISO.

### 5.5 Booting Linux

- **BIOS:** the 32-bit x86 boot protocol (2.10 or newer). dklilo loads the
  protected-mode kernel at 1 MiB, places the initramfs as high as
  `initrd_addr_max` allows, fills in `boot_params` (including the E820
  memory map from `int 15h, ax=E820h`), and jumps to `code32_start`. The
  kernel switches to 64-bit mode itself. `type_of_loader` is `0xFF`
  (undefined), since dklilo has no assigned ID.
- **UEFI:** the kernel is started as an EFI application through its EFI
  stub (kernels need `CONFIG_EFI_STUB`, which DKRescue's has). The
  initramfs is provided through `LoadFile2` on the
  `LINUX_EFI_INITRD_MEDIA_GUID` device path, which kernels since 5.8 use.
  This is the interface the kernel documents for loaders, rather than the
  older EFI handover protocol.

### 5.6 Booting Windows

- **UEFI:** `other = windows` finds `\EFI\Microsoft\Boot\bootmgfw.efi` on
  the ESP and starts it. Windows on UEFI machines is always installed this
  way.
- **BIOS:** `other = windows` finds the first NTFS partition whose boot
  sector has the NTFS signature and an `NTLDR`/`BOOTMGR` loader, loads that
  boot sector, and jumps to it. `other = /dev/sda1` style names (resolved by
  the installer) pick a partition explicitly.

### 5.7 The installer (`dklilo`)

| Command | Does |
|---|---|
| `dklilo check [conf]` | Parses the configuration and, using the same filesystem code as the loaders, confirms every `image` and `initrd` exists and every label is unique. |
| `dklilo install-bios <disk>` | Writes stage 1 to the MBR (keeping the partition table and disk signature) and stage 2 to the post-MBR gap or the GPT BIOS boot partition. |
| `dklilo install-uefi <esp>` | Copies `dkliloX64.efi` to `\EFI\dklilo\` and creates a boot entry by writing the `Boot####` and `BootOrder` variables through `/sys/firmware/efi/efivars`. `--removable` installs to `\EFI\BOOT\BOOTX64.EFI` instead, for USB sticks. |
| `dklilo mkiso-images <dir>` | Writes `eltorito.bin` and a FAT EFI image into a directory, ready for `xorriso` to build a hybrid ISO. |

- Disks can be named as `/dev/sdX`, `/dev/nvmeXnY`, `/dev/vdX`, or any
  `/dev/disk/by-id/…`, `by-uuid`, `by-label` or `by-partuuid` path,
  including names containing colons.
- Every write is shown in a summary first (device, offsets, sizes) and
  needs `--yes` or an interactive confirmation.
- `install-uefi` builds the boot entry as a standard `EFI_LOAD_OPTION`
  (the same binary layout efibootmgr and efivar use). By default it writes
  it straight to efivarfs. With `--entry-file <path>` it writes the
  `Boot####` payload to a file instead, so efibootmgr-style tooling can
  import it and the entry can be created from environments without efivarfs.
- The installer refuses to overwrite anything in the post-MBR gap that
  isn't zeros or an older dklilo stage 2, so it never clobbers another
  boot loader or data it doesn't recognise.

## 6. Shared conventions

- Code and documentation conventions are the same as dkde's (sections 6.4
  and 6.5 of the dkde spec): `zig fmt`, Zig's official naming, `//!` module
  comments, `///` on every public declaration, comments that explain why.
- Every on-disk structure (MBR, GPT, ext4 superblock, btrfs items,
  `boot_params`) is declared as an `extern struct` with a comment linking to
  its specification, and a `comptime` assertion of its size.
- `docs/boot-flow.md` walks through both boot paths from power-on to the
  kernel, and `docs/dklilo.conf.5.md` is the configuration reference (and
  the source of the man page).

## 7. Repository layout

```
build.zig
build.zig.zon
LICENSE              MIT
SPEC.md
original/            LILO 24.2 and Slackware patches (reference only, not built)
docs/
  boot-flow.md
  dklilo.conf.5.md
src/
  common/
    blockdev.zig  part/  fs/  compress/  config.zig  menu.zig  console.zig  linux/
  bios/
    stage1.zig        MBR code (.code16 asm)
    realmode.zig      real-mode trampoline and BIOS service wrappers
    main.zig          stage 2
  uefi/
    main.zig
  installer/
    main.zig
tests/
  images/           scripts that build test disk images with mkfs tools
  qemu/             boot tests under SeaBIOS and OVMF
```

## 8. Testing

- **Filesystem and partition readers** are unit-tested in userspace against
  disk images created by the real `mkfs.ext4`, `mkfs.btrfs` (with each
  compression type) and `mkfs.fat`, and compared file by file with the
  originals.
- **Fuzzing:** every on-disk parser is fuzzed with Zig's built-in fuzzer.
  A corrupt disk must produce an error, never a hang or a crash, because a
  rescue disk's boot loader will meet damaged disks.
- **QEMU boot tests** for every combination of firmware (SeaBIOS, OVMF),
  partition table (MBR, GPT) and filesystem (ext4, btrfs), checking that
  the kernel prints its command line and the initramfs contents arrived.
- **Windows chainloading** is tested manually against a Windows VM on BIOS
  and UEFI, since it can't be automated without a Windows licence in CI.
- **Real hardware:** each release is booted on at least one BIOS-only and
  one UEFI machine before it's tagged.

## 9. Milestones

Each milestone is merged only when all its acceptance criteria pass.

### L0 — Skeleton
- `zig build` produces every artifact in 4.1. The UEFI loader and BIOS
  stage 2 print a message in QEMU.
- **Done when:** both boot in QEMU (OVMF and SeaBIOS) and print over serial.

### L1 — Partitions and ext4
- `blockdev`, MBR, GPT and the ext2/3/4 reader, in userspace.
- **Done when:** every file in a test ext4 image (extents, 64bit,
  metadata_csum, large directories) reads back identical to the original.

### L2 — UEFI Linux boot
- Configuration parser, menu, ext4 over `BlockIo`, EFI stub boot with
  `LoadFile2` initramfs.
- **Done when:** DKRescue boots on OVMF from an ext4 root with an initramfs,
  and editing the command line at the menu works.

### L3 — BIOS Linux boot
- Stage 1, the real-mode trampoline, `int 13h` extensions, E820, and the
  32-bit boot protocol.
- **Done when:** the same configuration boots DKRescue on SeaBIOS, from
  both an MBR and a GPT disk.

### L4 — btrfs
- Everything in 5.4 for btrfs, including all three compression types and
  subvolumes.
- **Done when:** DKRescue boots from a zstd-compressed btrfs subvolume on
  both firmware types.

### L5 — Windows
- Everything in 5.6.
- **Done when:** a menu entry boots Windows on a UEFI VM and on a BIOS VM.

### L6 — Installer
- Everything in 5.7 except `mkiso-images`.
- **Done when:** `dklilo install-bios` and `install-uefi` produce bootable
  disks from inside DKRescue, and the installer refuses to overwrite an
  unrecognised post-MBR gap.

### L7 — ISO
- ISO 9660 reader, El Torito BIOS image, EFI image, `mkiso-images`.
- **Done when:** a DKRescue ISO built with `xorriso` boots from a virtual
  DVD and as a USB disk image, on both firmware types.

### L8 — DKRescue integration
- dklilo replaces extlinux and GRUB in the DKRescue build posts.
- **Done when:** DKRescue's ISO and installed systems use only dklilo.

### L9 — Config generator (post-v1)
- `dklilo config`: detects disks, kernels and Windows installs and writes a
  first `dklilo.conf`, like Slackware's `liloconfig`.
- **Done when:** on a fresh DKRescue install, `dklilo config` produces a
  configuration that `dklilo check` accepts and that boots.

## 10. Decisions

Resolved from the original open questions:

1. **License: MIT.** dklilo is new code, so it isn't bound by LILO's BSD
   license; `original/` stays reference-only under its own licenses.
2. **UEFI boot entries:** efivarfs is the default; `--entry-file` also
   emits the standard `EFI_LOAD_OPTION` format for efibootmgr-compatible
   tooling (5.7).
3. **Config generator:** `dklilo config` is planned after v1 as milestone L9.
