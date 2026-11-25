#!/bin/sh
# L3: the BIOS menu works from the PC keyboard, not only over serial
# (docs/bugs BIOS-01). Keys are sent to QEMU's PS/2 keyboard and the serial
# line is only read. The entries name missing kernels, so no Linux is needed.
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
cat > "$d/root/boot/dklilo.conf" <<'C'
prompt
timeout = 80
image = /boot/nokernel-a
    label = a
image = /boot/nokernel-b
    label = b
C
truncate -s 16M "$d/fs.img"
mkfs.ext4 -F -q -d "$d/root" "$d/fs.img"
truncate -s 24M "$d/disk.img"
printf 'label: dos\nstart=2048, size=32768, type=83\n' | sfdisk -q "$d/disk.img"
dd if="$d/fs.img" of="$d/disk.img" bs=512 seek=2048 conv=notrunc 2>/dev/null
"$dk" install-bios "$d/disk.img" --yes >/dev/null || fail "install-bios"

# Down selects the second entry, Enter boots it (it is missing, so the boot
# fails), and a third key must dismiss "Press a key" and bring the menu back.
python3 -I "$here/bios-drive.py" "$d/serial.txt" "$d/monitor" \
    "wait:Booting in" key:down key:ret \
    "wait:Loading /boot/nokernel-b" "wait:Press a key" key:spc \
    "wait:dklilo boot menu" -- \
    qemu-system-x86_64 -m 256 -drive format=raw,file="$d/disk.img" ||
    { cat "$d/serial.txt"; echo; fail "the PS/2 keyboard did not drive the menu"; }
echo "PASS: BIOS menu responds to the PS/2 keyboard"
