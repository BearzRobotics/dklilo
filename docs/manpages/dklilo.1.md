% DKLILO(1) Version 0.0.2 | dklilo Manual
% Dakota Keeler and contributors
% 2026-11-06

# NAME

dklilo - install and check the dklilo boot loader

# SYNOPSIS

**dklilo check** [*conf*] [**--device** *DEV*]

**dklilo install-bios** *disk* [**--yes**]

**dklilo install-uefi** *esp-dir* [**--arch** *ARCH*] [**--removable**] [**--entry-file** *FILE*] [**--device** *DEV*] [**--yes**]

**dklilo config** [**--boot** *DIR*] [**-o** *FILE*] [**--force**] [**--root** *DEV*] [**--append** *STR*] [**--no-windows**]

**dklilo mkiso-images** *dir* [**--arch** *ARCH*]

**dklilo isohybrid** *iso*

# DESCRIPTION

dklilo is a boot loader with LILO's configuration syntax that reads the
filesystems itself at boot time (ext2/3/4, btrfs, FAT, ISO 9660). The
**dklilo** command is its installer and helper tool. It is one static
executable that contains the BIOS and UEFI boot images.

The boot loader reads its configuration, **dklilo.conf**(5), when the machine
boots. Changing the configuration, or adding and removing kernels, needs no
reinstall. The commands below are needed only to install the loader, to
generate and check a configuration, and to build bootable ISO images.

Every command that writes to a disk or to the EFI System Partition lists the
writes first and asks for confirmation (see **--yes**).

# COMMANDS

**check** [*conf*] [**--device** *DEV*]
:   Parses a configuration and confirms that every `image` and `initrd` exists,
    using the same filesystem and parser code as the boot loader. `iso`
    entries are mounted and checked inside the ISO. Chainload (`other`)
    entries are listed but not verified. A `root=LABEL=` or `root=UUID=`
    on an entry without `initrd` produces a warning, since the kernel cannot
    resolve it by itself.

    Without **--device**, *conf* (default `/boot/dklilo.conf`) is a file on the
    running system, and the device holding it is found from
    `/proc/self/mountinfo`. With **--device**, the configuration is searched
    for on that disk the way the boot loader searches (see FILES in
    **dklilo.conf**(5)) and *conf* is not used.

**install-bios** *disk* [**--yes**]
:   Installs stage 1 into the MBR boot code of *disk* and stage 2 into the gap
    before the first partition (MBR) or into the BIOS boot partition, type
    EF02 (GPT). The partition table is preserved. It refuses to run if the
    space for stage 2 holds anything other than zeros or an earlier dklilo, if
    there is not enough room, if a GPT disk has no BIOS boot partition, or if
    the disk has no partition table.

**install-uefi** *esp-dir* [**--arch** *ARCH*] [**--removable**] [**--entry-file** *FILE*] [**--device** *DEV*] [**--yes**]
:   Copies the UEFI loader to the mounted EFI System Partition *esp-dir*:
    `EFI/dklilo/dklilo<ARCH>.efi` (`dkliloX64.efi`, `dkliloAA64.efi`,
    `dkliloARM.efi`, `dkliloRISCV64.efi`), or
    `EFI/BOOT/BOOT<ARCH>.EFI` with **--removable**. Without **--removable** it also creates a firmware boot
    entry and puts it first in BootOrder through efivarfs
    (`/sys/firmware/efi/efivars`).

**config** [**--boot** *DIR*] [**-o** *FILE*] [**--force**] [**--root** *DEV*] [**--append** *STR*] [**--no-windows**]
:   Generates a first `dklilo.conf`. It lists the kernels (`vmlinuz*`) in
    *DIR*, names the root by PARTUUID when it can, and adds a Windows entry
    when it finds Windows Boot Manager. For btrfs it adds `subvol=` and
    `rootflags=subvol=` as needed. The result is parsed with the loader's own
    parser before it is written.

**mkiso-images** *dir* [**--arch** *ARCH*]
:   Writes `eltorito.bin`, `efiboot.img` and `mbr.bin` into the existing
    directory *dir*: the pieces **xorriso**(1) needs for a hybrid BIOS and
    UEFI ISO.

**isohybrid** *iso*
:   After **xorriso** has built the ISO, points stage 1 in its system area at
    stage 2 so the ISO also boots from a USB stick under BIOS. Only the
    10-byte block list in the ISO is rewritten.

# OPTIONS

**--yes**
:   Do not ask for confirmation (**install-bios**, **install-uefi**). Without
    it, the command prints what it will write and waits for `yes` on standard
    input. Anything else aborts with nothing written.

**--arch** *ARCH*
:   (**install-uefi**, **mkiso-images**) Which UEFI loader to install:
    `x64` (also `x86_64`, `amd64`), `aa64` (also `aarch64`, `arm64`), `arm`
    (32-bit ARM, Thumb-2) or `riscv64`.
    Default: the architecture the **dklilo** tool itself was built for, so
    that a tool built for a Raspberry Pi installs the AArch64 loader. Every
    loader is embedded in every build, so a disk or ISO for another
    architecture can be prepared from any host.

**--removable**
:   (**install-uefi**) Install as `\EFI\BOOT\BOOT<ARCH>.EFI` for removable media
    and create no boot entry.

**--entry-file** *FILE*
:   (**install-uefi**) Write the boot entry as an `EFI_LOAD_OPTION` structure
    to *FILE* instead of using efivarfs, for use with **efibootmgr**(8) or
    when efivarfs is unavailable.

**--device** *DEV*
:   (**install-uefi**) The partition holding *esp-dir*, such as `/dev/sda1` or
    `/dev/nvme0n1p1`, when it cannot be determined from
    `/proc/self/mountinfo`. (**check**) The disk to search for the
    configuration; see **check**.

**--boot** *DIR*
:   (**config**) The directory containing the kernels. Default: `/boot`.

**-o** *FILE*
:   (**config**) Write the configuration to *FILE*. Default: standard output.
    An existing *FILE* is not overwritten without **--force**.

**--force**
:   (**config**) Overwrite an existing **-o** file.

**--root** *DEV*
:   (**config**) The root device or specification (`PARTUUID=`, `UUID=`,
    `LABEL=` or a device name). Default: the device mounted at `/`.

**--append** *STR*
:   (**config**) Kernel command-line options for every generated Linux entry.
    Default: `ro quiet`.

**--no-windows**
:   (**config**) Do not add a Windows entry even if one is detected.

Options are matched by exact spelling; the `--option=value` form is not
supported. Disks may be given as `/dev/sdX`, `/dev/nvmeXnY`, `/dev/vdX` or any
`/dev/disk/by-*` path.

# EXIT STATUS

| Status | Meaning |
|---|---|
| 0 | Success. |
| 1 | The command failed, the user declined the confirmation, or **check** found a problem. A message is written to standard error. |
| 2 | Invalid command-line usage; the usage summary is written to standard error. |

# FILES

`/boot/dklilo.conf`
:   Default configuration read by **check** and the usual place for **config -o**.

`/proc/self/mountinfo`
:   Read to find the device that holds a file or directory.

`/sys/firmware/efi/efivars`
:   efivarfs, written by **install-uefi** to create the boot entry.

# EXAMPLES

Generate a configuration and check it:

    dklilo config -o /boot/dklilo.conf
    dklilo check /boot/dklilo.conf

Install for BIOS, then for UEFI:

    dklilo install-bios /dev/sda
    dklilo install-uefi /boot/efi

Prepare an AArch64 machine's ESP (for example a Raspberry Pi running UEFI firmware):

    dklilo install-uefi /boot/efi --arch aa64

Prepare a USB stick's ESP without touching the firmware's boot entries:

    dklilo install-uefi /mnt/usb --removable

Build a hybrid BIOS and UEFI ISO (kernel and `dklilo.conf` go in `tree/`):

    dklilo mkiso-images img/
    mkdir -p tree/boot/dklilo
    cp img/eltorito.bin img/efiboot.img tree/boot/dklilo/
    xorriso -as mkisofs -R -V MYLIVE -o live.iso \
        --grub2-mbr img/mbr.bin \
        -b boot/dklilo/eltorito.bin -no-emul-boot -boot-load-size 4 -boot-info-table \
        -eltorito-alt-boot -e boot/dklilo/efiboot.img -no-emul-boot \
        -append_partition 2 0xEF img/efiboot.img -appended_part_as_gpt \
        tree
    dklilo isohybrid live.iso

# DIAGNOSTICS

`dklilo: cannot open PATH: REASON`
:   A disk, directory or file could not be opened. Check the path and that you
    have permission (installing to a disk needs root).

`dklilo: the space for stage 2 holds data that is not zeros or an older dklilo.`
:   **install-bios** refused to overwrite what may be another boot loader.
    Nothing was written.

`dklilo: cannot tell which partition DIR is on; pass --device /dev/...`
:   **install-uefi** could not map the ESP to a partition. Use **--device**.

`dklilo: the loader is installed, but creating the boot entry failed`
:   The file was copied but efivarfs could not be written. Mount efivarfs, or
    use **--entry-file**.

`dklilo: config line N: ERROR`
:   **check** could not parse the configuration at line N.

`FAIL: LABEL: image PATH: ERROR`
:   **check** could not find or read that file.

# SECURITY CONSIDERATIONS

The installer writes raw disk sectors and needs privileges that allow it.
It writes only the locations it lists beforehand, and refuses to overwrite
unrecognised data in the stage 2 area. The boot menu password in
`dklilo.conf` is stored as a SHA-256 hash; it protects editing the kernel
command line in the menu only, not the files on disk. dklilo does not support
Secure Boot.

# COMPATIBILITY

Linux host for the tool. It is built for x86_64 by default, and for another
architecture with `zig build -Dtarget=aarch64-linux-none`. The loader boots
Linux and chainloads Windows on BIOS (MBR or GPT, x86 only) and on UEFI
(x86_64, AArch64, 32-bit ARM and RISC-V 64). x86_64, AArch64 and
RISC-V 64 are tested by booting Linux under QEMU with edk2 firmware; 32-bit
ARM is only built and its file names checked. None of the non-x86 loaders has
been run on real hardware. Built with Zig 0.17.1.

# LIMITATIONS

See the non-goals in the project's README and SPEC.md: no Secure Boot, no
encrypted or LVM/RAID `/boot`, no btrfs RAID0/5/6, no NTFS or XFS readers, no
network boot, no 32-bit kernels. BIOS support is x86 only; UEFI is x86_64, AArch64, 32-bit ARM and RISC-V 64, with the testing limits above.

# SEE ALSO

**dklilo.conf**(5), **xorriso**(1), **efibootmgr**(8)

Project documentation: `README.md`, `SPEC.md`, `docs/boot-flow.md`.

# AUTHOR

Dakota Keeler and contributors.

# LICENSE

MIT. The full text is in the `LICENSE` file of the source tree.

# AVAILABILITY

Source code and issue tracker: <https://github.com/BearzRobotics/dklilo>

# VERSION

This manual describes dklilo version 0.0.2.
