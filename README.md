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
  base. AArch64 and RISC-V boot Linux under QEMU with edk2 (not tried on real
  hardware), 32-bit ARM is only built; see [docs/zig-uefi-targets.md](docs/zig-uefi-targets.md) for how each
  is built (RISC-V needs a converter because Zig cannot link it yet).
- **Reads filesystems at boot:** ext2/3/4, btrfs (single, DUP and RAID1;
  zlib, LZO and zstd compression; subvolumes), FAT12/16/32 with long names,
  and ISO 9660 with Rock Ridge.
- **Boots Windows** by chainloading Windows Boot Manager (UEFI) or the Windows
  partition's boot sector (BIOS).
- **Text menu** with a timeout, a default entry, a command-line editor, a way
  to boot a kernel by hand, and optional password protection with a salted
  hash. It works on screen and over a serial console, and after a failed boot
  it waits for you.
- **Hybrid ISO and loopback ISO boot:** boots from DVD or USB on both
  firmware types, or boots an ISO file stored on another filesystem
  (`iso = /isos/rescue.iso`).
- **Installer** that shows what it will write before it writes to a disk or
  an ESP, and refuses to overwrite a boot loader or data it doesn't
  recognise.
- **No dependencies, no C, no separate assembler.** The only non-ordinary-Zig
  parts are the 16-bit real-mode stubs, written as `.code16` assembly blocks
  in `.zig` files.

### Non-goals (v1)

Secure Boot, graphical menus, encrypted `/boot` (LUKS), `/boot` on LVM or
software RAID, btrfs RAID0/5/6, NTFS/XFS readers, network boot, Multiboot,
32-bit x86 kernels, and BIOS on anything but x86. See [SPEC.md](SPEC.md) section 2.

## Requirements

- **BIOS:** an x86 PC with about 41 MiB of RAM or more and 512-byte disk
  sectors. A kernel's protected-mode part may be up to 29 MiB. Stage 2 needs
  about 480 free sectors before the first partition (the usual 1 MiB gap is
  plenty) or, on GPT, a BIOS boot partition at least that big.
- **UEFI:** Secure Boot off.

## Upgrading from 0.0.4

Install the new `dklilo`, then run the same `install-bios` or `install-uefi`
command again: existing configurations and installations work as they are.
Things that behave differently:

- After a failed boot the menu waits for a key instead of retrying. `m` boots
  a kernel by hand, and asks for the password if one is set.
- `dklilo password` makes a salted password hash. **Update the installed boot
  loader before putting one in `dklilo.conf`:** older loaders treat the file
  as broken and show a prompt without a password. Old hashes keep working.
- `dklilo check` fails on more problems: an empty kernel, a chainload
  partition that doesn't exist, a password hash nothing matches, or a command
  line too long to pass on.
- `install-uefi` refuses an ESP that isn't mounted; `isohybrid` asks before
  writing to a disk.
- `UUID=` no longer matches FAT volumes (use `LABEL=`), as the manual always
  said. Filesystems with unknown incompatible features are not read.

[docs/bugs](docs/bugs/README.md) records the 0.0.4 defects that were found,
what fixes each one, and what is still open.

## Building

You need [Zig](https://ziglang.org/) **0.17.1**.

```sh
zig build            # everything: stage1/stage2, the UEFI loaders, the dklilo tool
zig build -Dtarget=aarch64-linux-none   # the tool for an AArch64 machine
zig build test       # unit tests against images made by real mkfs tools
                     # (on x86_64 the reader tests also run as 32-bit)
```

Artifacts land in `zig-out/`. `zig-out/bin/dklilo` is the installer and tools
binary (static, no libc).

## Installing

`install-bios` and `install-uefi` list their writes first and need `--yes` or
an interactive confirmation (so does `isohybrid` when it is given a disk).
`install-bios` takes a whole disk and refuses targets that don't look like
one, and records which partition holds `dklilo.conf`
(`--config-partition` chooses it). `install-uefi --removable` replaces another system's loader
only with `--force`; see [the manual](docs/manpages/dklilo.1.md).

```sh
# Generate a first config from /boot, the root PARTUUID and Windows detection
dklilo config -o /boot/dklilo.conf

# Check it: parses the config and confirms every image/initrd exists,
# using the same filesystem code as the boot loaders
dklilo check /boot/dklilo.conf

# Optional: a password line for dklilo.conf
dklilo password

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
| `dklilo password` | Prints a `password =` line with a salted hash. |
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
`mkfs.btrfs` and `mkfs.fat`. The test scripts in `tests/qemu/` boot through
SeaBIOS and OVMF (and AAVMF and RISC-V edk2) or drive the `dklilo` tool on
disk images; none of them touches a real disk. Between them they use
`qemu-system-x86_64` (also `-aarch64` and `-riscv64`), the matching firmware,
`xorriso`, `mtools`, `sfdisk`, `sgdisk`, `debugfs`, `python3` and GNU `as`.
Many use fake kernels. The Linux boot tests need a distribution kernel at
`$DKLILO_KERNEL` (default `~/.cache/dklilo/vmlinuz`), and
`$DKLILO_KERNEL_AA64` and `$DKLILO_KERNEL_RISCV64` for the other
architectures. Tests skip when something is missing, and the runner lists what
it skipped. `tests/package-files.sh` checks that the files `build.zig.zon`
lists are enough to build. Windows chainloading is tested against a stub, and
by hand against a real Windows VM.

## Documentation

- [SPEC.md](SPEC.md): goals, architecture, behaviour, milestones and
  implementation notes.
- [docs/boot-flow.md](docs/boot-flow.md): both boot paths from power-on to the
  kernel.
- [docs/manpages/dklilo.conf.5.md](docs/manpages/dklilo.conf.5.md): configuration reference.
- [docs/manpages/dklilo.1.md](docs/manpages/dklilo.1.md): the `dklilo` command.
- [docs/bugs](docs/bugs/README.md): the bug hunt of 0.0.4 and what was done
  about each finding.
- [docs/zig-uefi-targets.md](docs/zig-uefi-targets.md): which UEFI targets Zig 0.17.1 can build.
- [docs/std-io-freestanding.md](docs/std-io-freestanding.md): limits of `std.Io` on freestanding targets.
- [deps/fsread](deps/fsread): the filesystem readers, reusable as a package.
- `original/`: LILO 24.2 and Slackware patches, kept as reference material
  only. dklilo is a new implementation and shares no code with it.

## Status

Pre-release. The milestones through the ISO and loopback-ISO work are
implemented (see SPEC.md section 9), and the known defects are listed in
[docs/bugs](docs/bugs/README.md). Each release is meant to be booted on at
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
