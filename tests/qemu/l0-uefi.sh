#!/bin/sh
# L0 UEFI check: boot dkliloX64.efi as the removable-media loader under OVMF
# and expect "dklilo" on the serial console.
set -eu
efi="${1:-zig-out/bin/dkliloX64.efi}"
d=$(mktemp -d); out="$d/serial.txt"
trap 'rm -rf "$d"' EXIT
mkdir -p "$d/esp/EFI/BOOT"
cp "$efi" "$d/esp/EFI/BOOT/BOOTX64.EFI"
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$d/vars.fd"
timeout 20 qemu-system-x86_64 -machine q35 -display none -no-reboot \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file="$d/vars.fd" \
    -drive format=raw,file=fat:rw:"$d/esp" \
    -serial "file:$out" >/dev/null 2>&1 || true
grep -q dklilo "$out" && echo "PASS: UEFI loader printed over serial" || { echo "FAIL"; exit 1; }
