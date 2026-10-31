#!/bin/sh
# L3: the BIOS menu works over the serial console, and editing the kernel
# command line there changes what the kernel receives.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
cat > "$d/dklilo.conf" <<'C'
timeout = 600
prompt
image  = /boot/vmlinuz
    label  = test
    append = "console=ttyS0 quiet"
    initrd = /boot/initrd1.img
C
rc=0; "$here/make-bios-disk.sh" "$d/disk.img" "$d/dklilo.conf" || rc=$?
[ $rc -eq 77 ] && exit 77
[ $rc -eq 0 ] || exit $rc
: > "$d/serial.txt"
(
    i=0
    while [ $i -lt 60 ]; do
        grep -qa "Booting in" "$d/serial.txt" 2>/dev/null && break
        sleep 1; i=$((i+1))
    done
    sleep 1
    printf 'e'; sleep 1
    printf ' edited=2'; sleep 1
    printf '\r'
    sleep 20
) | timeout 80 qemu-system-x86_64 -m 1024 -display none -no-reboot \
    -drive format=raw,file="$d/disk.img" -serial mon:stdio > "$d/serial.txt" 2>&1 || true
if grep -aq "cmdline: .*edited=2" "$d/serial.txt" && grep -aq "DKLILO-DONE" "$d/serial.txt"; then
    echo "PASS: BIOS menu over serial, command line edited, kernel received it"
else
    echo "FAIL; serial tail:"; tail -c 1500 "$d/serial.txt" | cat -v | tail -25; exit 1
fi
