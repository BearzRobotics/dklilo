#!/bin/sh
# L0 UEFI check for AArch64: boot dkliloAA64.efi as the removable-media loader
# under AAVMF (edk2) on QEMU's "virt" machine and expect "dklilo" on the serial
# console. Skips (77) without qemu-system-aarch64 or the firmware.
set -eu
efi="${1:-zig-out/bin/dkliloAA64.efi}"
code=/usr/share/AAVMF/AAVMF_CODE.fd
vars=/usr/share/AAVMF/AAVMF_VARS.fd
command -v qemu-system-aarch64 >/dev/null || { echo "SKIP: no qemu-system-aarch64"; exit 77; }
[ -f "$code" ] && [ -f "$vars" ] || { echo "SKIP: no AAVMF firmware"; exit 77; }
d=$(mktemp -d); out="$d/serial.txt"
trap 'rm -rf "$d"' EXIT
mkdir -p "$d/esp/EFI/BOOT"
cp "$efi" "$d/esp/EFI/BOOT/BOOTAA64.EFI"
cp "$vars" "$d/vars.fd"
timeout 60 qemu-system-aarch64 -machine virt -cpu cortex-a57 -m 1024 -display none -no-reboot \
    -drive if=pflash,format=raw,readonly=on,file="$code" \
    -drive if=pflash,format=raw,file="$d/vars.fd" \
    -drive format=raw,file=fat:rw:"$d/esp" \
    -serial "file:$out" >/dev/null 2>&1 || true
grep -q dklilo "$out" && echo "PASS: AArch64 UEFI loader printed over serial" || { echo "FAIL; serial:"; head -c 600 "$out"; exit 1; }
