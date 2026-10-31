#!/bin/sh
# L5 (UEFI): the menu starts Windows Boot Manager from the ESP. A fake
# bootmgfw.efi stands in; it checks it was given a device handle.
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
rc=0; "$here/make-linux-disk.sh" "$d/disk.img" "$d/dklilo.conf" || rc=$?
[ $rc -eq 77 ] && exit 77
[ $rc -eq 0 ] || exit $rc
"$here/qemu-uefi.sh" "$d/disk.img" "$d/serial.txt" 40
if grep -aq "FAKE-BOOTMGR-OK device=yes" "$d/serial.txt"; then
    echo "PASS: UEFI chainload started Windows Boot Manager from the ESP"
else
    echo "FAIL; serial tail:"; tail -c 800 "$d/serial.txt" | cat -v; exit 1
fi
