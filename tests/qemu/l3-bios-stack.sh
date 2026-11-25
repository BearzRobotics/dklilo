#!/bin/sh
# L3: the BIOS loader must keep working when the disk BIOS uses a lot of stack
# (docs/bugs BIOS-02). A small option ROM hooks int 13h and writes 1 KiB onto
# the caller's stack on every call. A fake bzImage is used, so no Linux is
# needed.
#
# Skips (77) without qemu-system-x86_64.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
dk="$root/zig-out/bin/dklilo"
command -v qemu-system-x86_64 >/dev/null || { echo "SKIP: no qemu-system-x86_64"; exit 77; }
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

mkdir -p "$d/root/boot"
python3 -I "$here/fake-bzimage.py" "$d/root/boot/vmlinuz"
printf 'timeout = 0\nimage = /boot/vmlinuz\n    label = k\n' > "$d/root/boot/dklilo.conf"
truncate -s 16M "$d/fs.img"
mkfs.ext4 -F -q -b 4096 -d "$d/root" "$d/fs.img"
truncate -s 24M "$d/disk.img"
printf 'label: dos\nstart=2048, size=32768, type=83\n' | sfdisk -q "$d/disk.img"
dd if="$d/fs.img" of="$d/disk.img" bs=512 seek=2048 conv=notrunc 2>/dev/null
"$dk" install-bios "$d/disk.img" --yes >/dev/null || fail "install-bios"
python3 -I "$here/deep-stack-rom.py" "$d/deep.rom"

python3 -I "$here/bios-drive.py" "$d/serial.txt" "$d/monitor" \
    "wait:deep-stack hook installed" "wait:Starting kernel" -- \
    qemu-system-x86_64 -m 256 -option-rom "$d/deep.rom" -drive format=raw,file="$d/disk.img" ||
    { cat "$d/serial.txt"; echo; fail "did not boot with a stack-hungry disk BIOS"; }
echo "PASS: boots when the disk BIOS uses 1 KiB of the caller's stack"
