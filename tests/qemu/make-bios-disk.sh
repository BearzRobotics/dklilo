#!/bin/sh
# Builds a BIOS-bootable MBR test disk the way the installer will: stage 1 in
# the MBR code area (partition table kept), stage 2 at LBA 1 recorded in the
# block list, and one ext4 partition with the kernel, initramfs and config.
# The kernel is read from $DKLILO_KERNEL and only lives in the temp image.
#
# With a third argument "gpt", the disk is GPT: stage 2 goes in a BIOS boot
# partition (the MBR gap does not exist: LBA 1 is the GPT header).
#
# Set FAKE_WINDOWS=1 (mbr only) to add a second, NTFS-looking partition whose
# boot sector is the fake from fake-ntfs-vbr.py.
#
# NO_BOOTLOADER=1 leaves stage 1/2 out (the installer test installs them).
#
# Usage: make-bios-disk.sh <out.img> <dklilo.conf> [mbr|gpt]
set -eu
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$1"; conf="$2"; kind="${3:-mbr}"
kernel="${DKLILO_KERNEL:-$HOME/.cache/dklilo/vmlinuz}"
[ -f "$kernel" ] || { echo "SKIP: no kernel at $kernel (set DKLILO_KERNEL)"; exit 77; }
w=$(mktemp -d); trap 'rm -rf "$w"' EXIT

python3 "$here/tests/initramfs/mkcpio.py" "$w/initrd1.cpio" --init "$here/zig-out/bin/init" --file marker1=from-initrd-1
gzip -c "$w/initrd1.cpio" > "$w/initrd1.img"
python3 "$here/tests/initramfs/mkcpio.py" "$w/initrd2.cpio" --file marker2=from-initrd-2

mkdir -p "$w/root/boot"
cp "$kernel" "$w/root/boot/vmlinuz"
cp "$w/initrd1.img" "$w/root/boot/initrd1.img"
cp "$w/initrd2.cpio" "$w/root/boot/initrd2.cpio"
# EXTRA_FILE=path adds that file as /isos/test.iso (the loopback ISO test).
if [ -n "${EXTRA_FILE:-}" ]; then mkdir -p "$w/root/isos"; cp "$EXTRA_FILE" "$w/root/isos/test.iso"; fi
cp "$conf" "$w/root/boot/dklilo.conf"
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

rm -f "$out"
truncate -s $((root_mb + 16))M "$out"
if [ "$kind" = gpt ]; then
    sgdisk -o "$out" >/dev/null
    sgdisk -a 1 -n 1:64:2047 -t 1:EF02 -n 2:2048:$((2048 + root_sectors - 1)) -t 2:8300 "$out" >/dev/null 2>&1
    stage2_lba=64
else
    sfdisk -q "$out" >/dev/null <<S
label: dos
label-id: 0x4a6f8c21
start=2048, size=$root_sectors, type=83, bootable
$([ -n "${FAKE_WINDOWS:-}" ] && echo "start=$((2048 + root_sectors)), size=4096, type=7")
S
    stage2_lba=1
fi
dd if="$w/root.img" of="$out" bs=512 seek=2048 conv=notrunc,sparse 2>/dev/null
if [ -n "${FAKE_WINDOWS:-}" ]; then
    python3 "$here/tests/qemu/fake-ntfs-vbr.py" "$w/vbr.bin"
    dd if="$w/vbr.bin" of="$out" bs=512 seek=$((2048 + root_sectors)) conv=notrunc 2>/dev/null
fi
[ -n "${NO_BOOTLOADER:-}" ] && exit 0
python3 - "$here/zig-out/stage1.bin" "$here/zig-out/stage2.bin" "$out" "$stage2_lba" <<'PY'
import sys, struct
s1 = open(sys.argv[1], 'rb').read()
s2 = open(sys.argv[2], 'rb').read()
sectors = (len(s2) + 511) // 512
lba = int(sys.argv[4])
assert lba + sectors <= 2048, "stage 2 does not fit before the first partition"
code = bytearray(s1[:440])
code[416:426] = struct.pack('<QH', lba, sectors)  # block list: where stage 2 lives
with open(sys.argv[3], 'r+b') as f:
    f.seek(0); f.write(code)                         # keeps the partition table and signature
    f.seek(512 * lba); f.write(s2)
PY
