#!/bin/sh
# L2: the menu works over the serial console, and editing the kernel command
# line at the menu changes what the kernel receives. Keys are typed into
# QEMU's serial port after the menu has appeared.
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
rc=0; "$here/make-linux-disk.sh" "$d/disk.img" "$d/dklilo.conf" || rc=$?
[ $rc -eq 77 ] && exit 77
[ $rc -eq 0 ] || exit $rc

v="$d/vars.fd"; cp /usr/share/OVMF/OVMF_VARS_4M.fd "$v"
# Wait for the menu text to show up on the serial port, then type: e,
# " edited=1", Enter. (The countdown is stopped by the first key.)
(
    i=0
    while [ $i -lt 60 ]; do
        grep -qa "Booting in" "$d/serial.txt" 2>/dev/null && break
        sleep 1; i=$((i+1))
    done
    sleep 1
    printf 'e'; sleep 1
    printf ' edited=1'; sleep 1
    printf '\r'
    sleep 20
) | timeout 80 qemu-system-x86_64 -machine q35 -m 1024 -display none -no-reboot \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file="$v" \
    -drive format=raw,file="$d/disk.img" \
    -serial mon:stdio > "$d/serial.txt" 2>&1 || true

if grep -aq "cmdline: .*edited=1" "$d/serial.txt" && grep -aq "DKLILO-DONE" "$d/serial.txt"; then
    echo "PASS: menu shown on serial, command line edited, kernel received it"
else
    echo "FAIL; serial tail:"; tail -c 1500 "$d/serial.txt" | cat -v | tail -25; exit 1
fi
