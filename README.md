# dklilo

A modern LILO: a small, understandable boot loader with LILO's simple
configuration file, written in pure Zig. It boots Linux and Windows on both
**BIOS** and **UEFI** machines.

LILO was loved because it was simple and hated because it was fragile. The
fragility came from one design choice: it never read a filesystem. It recorded
the disk block numbers of each kernel in a map file, so every kernel update or
file move broke booting until you re-ran `lilo`. dklilo keeps the simplicity
and drops that design. It reads ext2/3/4, btrfs, FAT and ISO 9660 itself at
boot time, so kernels and the config can change freely and nothing needs
reinstalling.

```conf
# /boot/dklilo.conf
timeout = 50                     # tenths of a second, as in LILO
default = dkrescue

image   = /boot/vmlinuz-6.19-dkrescue
    label  = dkrescue
    root   = PARTUUID=4a6f8c21-02
    append = "ro quiet"
    initrd = /boot/initrd.img

other   = windows                # finds Windows automatically
    label  = Windows
```

## Features

- **BIOS** (MBR and GPT, x86) and **UEFI** (x86_64, **AArch64**, 32-bit ARM and
  **RISC-V 64**; for example a Raspberry Pi running UEFI firmware) from one code
  base. AArch64 and RISC-V are tested under QEMU with edk2, 32-bit ARM is only
  built; see [docs/zig-uefi-targets.md](docs/zig-uefi-targets.md) for how each
  is built (RISC-V needs a converter because Zig cannot link it yet).
- **Reads filesystems at boot:** ext2/3/4, btrfs (single, DUP and RAID1;
  zlib, LZO and zstd compression; subvolumes), FAT12/16/32 with long names,
  and ISO 9660 with Rock Ridge.
- **Boots Windows** by chainloading Windows Boot Manager (UEFI) or the Windows
  partition's boot sector (BIOS).
- **Text menu** with a timeout, a default entry, a command-line editor and
  optional password protection. It works on screen and over a serial console.
- **Hybrid ISO and loopback ISO boot:** boots from DVD or USB on both
  firmware types, or boots an ISO file stored on another filesystem
  (`iso = /isos/rescue.iso`).
- **Installer** that shows every write first and refuses to overwrite a boot
  loader or data it doesn't recognise.
- **No dependencies, no C, no separate assembler.** The only non-ordinary-Zig
  parts are the 16-bit real-mode stubs, written as `.code16` assembly blocks
  in `.zig` files.

### Non-goals (v1)

Secure Boot, graphical menus, encrypted `/boot` (LUKS), `/boot` on LVM or
software RAID, btrfs RAID0/5/6, NTFS/XFS readers, network boot, Multiboot,
32-bit x86 kernels, and BIOS on anything but x86. See [SPEC.md](SPEC.md) section 2.

## Building

You need [Zig](https://ziglang.org/) **0.17.1**.

```sh
zig build            # everything: stage1/stage2, the UEFI loaders, the dklilo tool
zig build -Dtarget=aarch64-linux-none   # the tool for an AArch64 machine
zig build test       # unit tests against images made by real mkfs tools
```

Artifacts land in `zig-out/`. `zig-out/bin/dklilo` is the installer and tools
binary (static, no libc).

## Installing

Every command lists its writes first and needs `--yes` or an interactive
confirmation.

```sh
# Generate a first config from /boot, the root PARTUUID and Windows detection
dklilo config -o /boot/dklilo.conf

# Check it: parses the config and confirms every image/initrd exists,
# using the same filesystem code as the boot loaders
dklilo check /boot/dklilo.conf

# BIOS: stage 1 into the MBR, stage 2 into the post-MBR gap or BIOS boot partition
dklilo install-bios /dev/sda

# UEFI: copy dkliloX64.efi to the ESP and create a boot entry
dklilo install-uefi /boot/efi
dklilo install-uefi /mnt/usb --removable     # \EFI\BOOT\BOOTX64.EFI, for USB sticks
dklilo install-uefi /boot/efi --arch aa64    # also arm, riscv64; default: the tool's own architecture
```

Disks can be named as `/dev/sdX`, `/dev/nvmeXnY`, `/dev/vdX`, or any
`/dev/disk/by-id`, `by-uuid`, `by-label` or `by-partuuid` path.

| Command | Does |
|---|---|
| `dklilo check [conf]` | Validates the config against the real filesystems. |
| `dklilo config` | Writes a first `dklilo.conf`. |
| `dklilo install-bios <disk>` | Installs the BIOS loader. |
| `dklilo install-uefi <esp>` | Installs the UEFI loader and boot entry. |
| `dklilo mkiso-images <dir>` | Writes `eltorito.bin`, `efiboot.img` and `mbr.bin` for building a hybrid ISO. |
| `dklilo isohybrid <iso>` | Points a hybrid ISO's stage 1 at its stage 2. |

## Configuration

The syntax follows LILO: `key = value`, `#` for comments, and `image` or
`other` start a new entry. Global keys are `timeout`, `default`, `prompt`,
`serial` and `password`. Entry keys are `image`, `label`, `root`, `append`,
`initrd` (repeatable), `subvol`, `iso`, `other` and `restricted`.

A path without a prefix refers to the filesystem the config was read from.
`LABEL=`, `UUID=` and `PARTUUID=` prefixes select another one, for example
`LABEL=boot:/vmlinuz`. The full reference is in
[docs/manpages/dklilo.conf.5.md](docs/manpages/dklilo.conf.5.md); the tool is documented in [docs/manpages/dklilo.1.md](docs/manpages/dklilo.1.md).

## Building a hybrid BIOS + UEFI ISO

```sh
dklilo mkiso-images img/
mkdir -p tree/boot/dklilo
cp img/eltorito.bin img/efiboot.img tree/boot/dklilo/
# add tree/boot/vmlinuz, tree/boot/initrd.img and tree/boot/dklilo.conf

xorriso -as mkisofs -R -V MYLIVE -o live.iso \
    --grub2-mbr img/mbr.bin \
    -b boot/dklilo/eltorito.bin -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot -e boot/dklilo/efiboot.img -no-emul-boot \
    -append_partition 2 0xEF img/efiboot.img -appended_part_as_gpt \
    tree

dklilo isohybrid live.iso
```

The kernel stays in the ISO 9660 part. `efiboot.img` only needs to hold
`\EFI\BOOT\BOOTX64.EFI`, because dklilo reads the ISO directly. A working
reference is `tests/qemu/l7-iso.sh`.

## Testing

```sh
tests/run-all.sh
```

Unit tests run against disk images created by the real `mkfs.ext4`,
`mkfs.btrfs` and `mkfs.fat`. The QEMU boot tests (`tests/qemu/`) boot a real
kernel through SeaBIOS and OVMF for each firmware, partition table and
filesystem combination, and need `qemu-system-x86_64`, OVMF, `xorriso`, and a
stock distribution kernel at `$DKLILO_KERNEL` (default
`~/.cache/dklilo/vmlinuz`). Tests skip when something is missing. Windows
chainloading is tested against a stub, and by hand against a real Windows VM.

## Documentation

- [SPEC.md](SPEC.md): goals, architecture, behaviour, milestones and
  implementation notes.
- [docs/boot-flow.md](docs/boot-flow.md): both boot paths from power-on to the
  kernel.
- [docs/manpages/dklilo.conf.5.md](docs/manpages/dklilo.conf.5.md): configuration reference.
- [docs/manpages/dklilo.1.md](docs/manpages/dklilo.1.md): the `dklilo` command.
- [docs/zig-uefi-targets.md](docs/zig-uefi-targets.md): which UEFI targets Zig 0.17.1 can build.
- [docs/std-io-freestanding.md](docs/std-io-freestanding.md): limits of `std.Io` on freestanding targets.
- [deps/fsread](deps/fsread): the filesystem readers, reusable as a package.
- `original/`: LILO 24.2 and Slackware patches, kept as reference material
  only. dklilo is a new implementation and shares no code with it.

## Status

Pre-release. The milestones through the ISO and loopback-ISO work are
implemented (see SPEC.md section 9). Each release is meant to be booted on at
least one BIOS-only and one UEFI machine before it is tagged. dklilo isn't
signed, so Secure Boot must be off.

## AI-assisted development

Much of dklilo is written with the help of AI coding assistants (Claude Code),
directed and reviewed by the maintainer. The rules that govern that work are
in [ai/AGENTS.md](ai/AGENTS.md): code must be understandable without the AI
that wrote it, claims must cite primary sources, and significant design
changes are explained before they are made. Contributors who use AI tools are
required to follow the same rules.

**Disclosure is required.** If you used AI to write or substantially shape a
contribution (code, documentation, tests or commit messages), say so in the
pull request: which tool, and what it did. AI use is welcome here; hiding it
is not. You remain responsible for understanding and being able to explain
everything you submit.

## License

[MIT](LICENSE)
