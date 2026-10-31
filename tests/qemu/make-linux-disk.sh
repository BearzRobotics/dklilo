#!/bin/sh
# Builds a bootable GPT test disk: a FAT ESP holding the UEFI loader and an
# ext4 partition holding the kernel, two initramfs files and dklilo.conf.
# Needs no root (mtools and mke2fs -d). The kernel is never copied into the
# repository: it is read from $DKLILO_KERNEL (default ~/.cache/dklilo/vmlinuz)
# and lives only in the temporary image.
#
# Usage: make-linux-disk.sh <out.img> <dklilo.conf> [extra initrd args...]
set -eu
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$1"; conf="$2"
kernel="${DKLILO_KERNEL:-$HOME/.cache/dklilo/vmlinuz}"
[ -f "$kernel" ] || { echo "SKIP: no kernel at $kernel (set DKLILO_KERNEL)"; exit 77; }
w=$(mktemp -d); trap 'rm -rf "$w"' EXIT

# Two initramfs files: the first has /init, the second only a marker. The
# kernel must unpack both (they are concatenated by the loader).
python3 "$here/tests/initramfs/mkcpio.py" "$w/initrd1.cpio" --init "$here/zig-out/bin/init" --file marker1=from-initrd-1
gzip -c "$w/initrd1.cpio" > "$w/initrd1.img"
python3 "$here/tests/initramfs/mkcpio.py" "$w/initrd2.cpio" --file marker2=from-initrd-2

mkdir -p "$w/root/boot"
cp "$kernel" "$w/root/boot/vmlinuz"
cp "$w/initrd1.img" "$w/root/boot/initrd1.img"
cp "$w/initrd2.cpio" "$w/root/boot/initrd2.cpio"
# CONFIG_IN_ESP=1 puts the configuration on the ESP (\EFI\dklilo\dklilo.conf)
# instead of on the root filesystem.
[ -n "${CONFIG_IN_ESP:-}" ] || cp "$conf" "$w/root/boot/dklilo.conf"

# ESP (FAT16, 33 MiB) and root (ext4, 64 MiB) as separate images, then dd'd
# into a GPT disk at the partition offsets.
truncate -s 33M "$w/esp.img"
mkfs.fat -F 16 -n ESP "$w/esp.img" >/dev/null
mmd -i "$w/esp.img" ::/EFI ::/EFI/BOOT
# NO_LOADER=1 leaves the ESP without the loader (the installer test adds it).
[ -n "${NO_LOADER:-}" ] || mcopy -i "$w/esp.img" "$here/zig-out/bin/dkliloX64.efi" ::/EFI/BOOT/BOOTX64.EFI
if [ -n "${CONFIG_IN_ESP:-}" ]; then
    mmd -i "$w/esp.img" ::/EFI/dklilo
    mcopy -i "$w/esp.img" "$conf" ::/EFI/dklilo/dklilo.conf
fi
if [ -n "${FAKE_WINDOWS:-}" ]; then   # a stand-in Windows Boot Manager
    mmd -i "$w/esp.img" ::/EFI/Microsoft ::/EFI/Microsoft/Boot
    mcopy -i "$w/esp.img" "$here/zig-out/bin/fake-bootmgfw.efi" ::/EFI/Microsoft/Boot/bootmgfw.efi
fi
# ROOTFS=btrfs builds a zstd-compressed btrfs root with /boot as a subvolume
# (needs mkfs.btrfs); the default is ext4.
rootfs="${ROOTFS:-ext4}"
if [ "$rootfs" = btrfs ]; then
    mkbtrfs="${DKLILO_MKFS_BTRFS:-$(command -v mkfs.btrfs || echo "$HOME/.cache/dklilo/mkfs.btrfs")}"
    [ -x "$mkbtrfs" ] || { echo "SKIP: no mkfs.btrfs"; exit 77; }
    root_mb=160
    truncate -s ${root_mb}M "$w/root.img"
    "$mkbtrfs" -q -f -L dklroot --rootdir "$w/root" --compress zstd --subvol rw:boot "$w/root.img" >/dev/null 2>&1
else
    root_mb=64
    truncate -s ${root_mb}M "$w/root.img"
    mkfs.ext4 -F -q -L dklroot -d "$w/root" "$w/root.img" >/dev/null 2>&1
fi
root_sectors=$((root_mb * 2048))

truncate -s $((root_mb + 40))M "$out"
sfdisk -q "$out" >/dev/null <<S
label: gpt
start=2048, size=67584, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
start=69632, size=$root_sectors, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=4a6f8c21-0000-4000-8000-000000000002
S
dd if="$w/esp.img" of="$out" bs=512 seek=2048 conv=notrunc 2>/dev/null
dd if="$w/root.img" of="$out" bs=512 seek=69632 conv=notrunc,sparse 2>/dev/null
