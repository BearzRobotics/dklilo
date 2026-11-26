# dklilo.conf(5)

## NAME

dklilo.conf - configuration file of the dklilo boot loader

## DESCRIPTION

`dklilo.conf` is read by the boot loader at boot time, not by the installer:
changing it takes effect at the next boot with nothing to reinstall. Its
syntax follows LILO's.

A flag such as `prompt` or `restricted` may be written alone; giving it the
value `no`, `false`, `off` or `0` turns it off. If a key is repeated, the last
one counts, and `dklilo check` warns.

Each line is `key = value`. Text after `#` is a comment (a `#` inside double
quotes is text). Values may be put in double quotes, which is needed for
values with spaces. Blank lines are ignored.

`image` and `other` start a boot entry. The keys after them belong to that
entry until the next `image` or `other`. Keys before the first entry are
global.

An empty or missing configuration is not an error: the loader then asks for a
kernel path and command line.

## FINDING THE FILE

The loader tries, in order:

1. `\EFI\dklilo\dklilo.conf` on every FAT volume of the boot disk;
2. `/boot/dklilo.conf`, then `/dklilo.conf`, on every volume of the boot disk;
3. the same on any other disk (UEFI).

Volumes are partitions, or a whole disk with no partition table (a DVD, or
an ISO written to a stick).

## GLOBAL KEYS

`timeout = N`
:   Tenths of a second before the default entry boots. `0` boots at once
    without a menu. Absent: wait forever.

`default = LABEL`
:   The entry to boot by default. It must exist. Absent: the first entry.

`prompt`
:   Always show the menu. Without it, a configuration with a single entry
    and a `timeout` boots that entry without showing the menu.

`serial = PORT,BAUD`
:   Parsed, but not used: the BIOS loader always uses COM1 at 115200 8N1, and
    the UEFI loader the firmware's console.

`password = HASH`
:   The hexadecimal SHA-256 of the password needed to edit the command line
    of `restricted` entries, and to boot by hand from the menu. Never store
    the password itself; produce the hash with
    `printf %s 'secret' | sha256sum`. A password may be up to 256 characters.

    Unlike LILO's, it does not guard booting an entry as written. With no
    `restricted` entry, anyone can edit command lines; `dklilo check` warns.
    It also does not protect the prompt shown when there is no usable
    configuration.

## ENTRY KEYS

`image = PATH`
:   Starts a Linux entry. The path of the kernel (a bzImage; on UEFI it must
    have the EFI stub).

`other = TARGET`
:   Starts an entry that chainloads another system. `windows` finds Windows
    Boot Manager (UEFI: `\EFI\Microsoft\Boot\bootmgfw.efi`, taken from the
    volume dklilo was loaded from, else from another volume of that disk, else
    from another disk, among those the firmware has made readable; BIOS:
    the NTFS partition with a Windows-style boot sector, preferring the active
    one). On BIOS, a partition number (`2`, `/dev/sda2`) selects the partition
    to chainload. On UEFI, any other value is the path of an EFI application
    on a FAT volume.

`label = NAME`
:   The name shown in the menu. Must be unique. Default: the file name of
    `image`, or the `other` target.

`root = VALUE`
:   Passed to the kernel as `root=VALUE`. The kernel cannot resolve
    `LABEL=` or `UUID=` without an initramfs, so use `PARTUUID=` or a device
    name if there is none (`dklilo check` warns about this).

`append = "OPTIONS"`
:   Added to the kernel command line after `root=`.

`initrd = PATH`
:   An initramfs. May be repeated; the files are concatenated in order, each
    padded to a 4-byte boundary, which the kernel unpacks as one.

`iso = PATH`
:   Boots from an ISO file stored on a filesystem instead of from the entry's
    own: `image` and `initrd` are then paths inside the ISO. The ISO is read
    in place, not copied into memory. The kernel command line gets
    `iso-scan/filename=PATH` appended after `root=` and `append`, which the
    initramfs of live distributions use to find the ISO. `PATH` may carry a
    `LABEL=`, `UUID=` or `PARTUUID=` prefix (see PATHS). Linux entries only.

`subvol = PATH`
:   For btrfs: the subvolume that contains `image` and `initrd`, as a path
    under the top-level subvolume. Default: the filesystem's default subvolume.

`restricted`
:   Editing this entry's command line needs `password`. Without a `password`
    it does nothing.

## PATHS

A path is absolute. Without a prefix it refers to the filesystem the
configuration was read from. A prefix selects another one:

    LABEL=boot:/vmlinuz
    UUID=1b0e3c2a-...:/vmlinuz      (ext4, btrfs)
    PARTUUID=4a6f8c21-02:/vmlinuz   (GPT GUID, or MBR signature-NN)

A configuration stored on the ESP therefore normally names its kernel with a
prefix. `UUID=` does not match FAT or ISO 9660 volumes. When more than one volume
matches a prefix, one on the same disk as the configuration is preferred, so
that a cloned disk or a USB stick does not take over.

A command line (`root=`, `append` and what dklilo adds) may be up to 1024
bytes. A path must name a regular file, or a symlink to one.

Supported filesystems: ext2, ext3, ext4, btrfs (single, DUP and RAID1 profiles;
zlib, LZO and zstd compression), FAT12/16/32 and ISO 9660 with Rock Ridge.

## THE MENU

Up/Down choose an entry and Enter boots it; a list too long for the screen
scrolls. `e` edits the kernel command line
(Enter boots, Esc goes back); for a `restricted` entry it asks for the
password first. `m` boots a kernel by hand: it asks for the kernel's path and a
command line, after the password if one is configured. Any key stops the
countdown. The menu appears on the screen and on the serial port at the same
time.

After a boot fails, or returns to the loader, the menu is shown and waits for a
key, even if the configuration would boot without it.

## EXAMPLE

    # /boot/dklilo.conf
    timeout = 50
    default = dkrescue
    prompt

    image   = /boot/vmlinuz-6.19-dkrescue
        label  = dkrescue
        root   = PARTUUID=4a6f8c21-02
        append = "ro quiet"
        initrd = /boot/initrd.img

    image   = /boot/vmlinuz-6.19-dkrescue
        label  = dkrescue-safe
        root   = PARTUUID=4a6f8c21-02
        append = "ro nomodeset"

    other   = windows
        label  = Windows

## SEE ALSO

`dklilo`(1). `dklilo config` writes a first configuration, and `dklilo check` verifies a configuration with the same code the loader uses:
every `image` and `initrd` must exist, labels must be unique.

This page describes dklilo version 0.0.4.
