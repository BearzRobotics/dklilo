#!/bin/sh
# L3: a failed BIOS disk read must stop the boot, never be taken as success
# (docs/bugs BIOS-01). QEMU's blkdebug driver makes one sector in the middle
# of the kernel unreadable. A fake bzImage is used, so no Linux is needed.
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

# The disk sector holding file block 50 of the kernel (4 KiB blocks, the
# partition starts at sector 2048).
block=$(debugfs -R 'bmap /boot/vmlinuz 50' "$d/fs.img" 2>/dev/null)
[ "$block" -gt 0 ] || fail "cannot locate the kernel on the test disk"
printf '[inject-error]\nevent = "read_aio"\nerrno = "5"\nsector = "%s"\n' \
    $((2048 + block * 8)) > "$d/inject.conf"

# Without the fault the loader must get as far as starting the kernel,
# otherwise the second half would prove nothing.
python3 -I "$here/bios-drive.py" "$d/good.txt" "$d/monitor1" "wait:Starting kernel" -- \
    qemu-system-x86_64 -m 256 -drive format=raw,file="$d/disk.img" ||
    { cat "$d/good.txt"; echo; fail "the healthy disk did not boot"; }

python3 -I "$here/bios-drive.py" "$d/bad.txt" "$d/monitor2" \
    "wait:read error: IoError" "wait:Boot failed" -- \
    qemu-system-x86_64 -m 256 \
    -drive "format=raw,rerror=report,file=blkdebug:$d/inject.conf:$d/disk.img" ||
    { cat "$d/bad.txt"; echo; fail "the read error was not reported"; }
grep -qa "Starting kernel" "$d/bad.txt" && fail "started a partly read kernel"
echo "PASS: a BIOS disk read error stops the boot"
