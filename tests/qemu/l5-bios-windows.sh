#!/bin/sh
# L5 (BIOS): the menu chainloads a Windows-style boot partition. A fake NTFS
# boot sector stands in for Windows; it reports dl and the partition entry.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
cat > "$d/dklilo.conf" <<'C'
timeout = 1
default = Windows
image  = /boot/vmlinuz
    label  = linux
    append = "console=ttyS0"
other  = windows
    label  = Windows
C
export FAKE_WINDOWS=1
rc=0; "$here/make-bios-disk.sh" "$d/disk.img" "$d/dklilo.conf" mbr || rc=$?
[ $rc -eq 77 ] && exit 77
[ $rc -eq 0 ] || exit $rc
timeout 30 qemu-system-x86_64 -m 256 -display none -no-reboot \
    -drive format=raw,file="$d/disk.img" -serial "file:$d/serial.txt" >/dev/null 2>&1 || true
export LC_ALL=C
if grep -aq "FAKE-NTFS-BOOT-OK DL=$(printf '\200') TYPE=$(printf '\007')" "$d/serial.txt"; then
    echo "PASS: BIOS chainload reached the Windows boot sector (dl=0x80, entry type 07)"
else
    echo "FAIL; serial tail:"; tail -c 600 "$d/serial.txt" | cat -v; exit 1
fi
