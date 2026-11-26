#!/bin/sh
# L5 (UEFI): with a Windows Boot Manager on more than one disk, the one on
# dklilo's own disk is started, whatever order the firmware lists them in, and
# one that won't load doesn't end the search (docs/bugs UEFI-04). Stand-ins
# are used, so neither Windows nor Linux is needed.
#
# Skips (77) without qemu-system-x86_64, OVMF or mtools.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
code=/usr/share/OVMF/OVMF_CODE_4M.fd
command -v qemu-system-x86_64 >/dev/null || { echo "SKIP: no qemu-system-x86_64"; exit 77; }
[ -f "$code" ] || { echo "SKIP: no OVMF"; exit 77; }
command -v mcopy >/dev/null || { echo "SKIP: no mtools"; exit 77; }
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
failures=0

printf 'prompt\nother = windows\n    label = Windows\n' > "$d/dklilo.conf"
printf 'this is not an EFI application' > "$d/broken.efi"

# disk <name> <bootmgfw.efi> [with-loader]
disk() {
    rm -f "$d/esp.img" "$d/$1.img"
    truncate -s 33M "$d/esp.img"
    mkfs.fat -F 16 -n ESP "$d/esp.img" >/dev/null
    mmd -i "$d/esp.img" ::/EFI ::/EFI/BOOT ::/EFI/dklilo ::/EFI/Microsoft ::/EFI/Microsoft/Boot
    mcopy -i "$d/esp.img" "$2" ::/EFI/Microsoft/Boot/bootmgfw.efi
    if [ -n "${3:-}" ]; then
        mcopy -i "$d/esp.img" "$root/zig-out/bin/dkliloX64.efi" ::/EFI/BOOT/BOOTX64.EFI
        mcopy -i "$d/esp.img" "$d/dklilo.conf" ::/EFI/dklilo/dklilo.conf
    fi
    truncate -s 40M "$d/$1.img"
    printf 'label: gpt\nstart=2048, size=67584, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B\n' | sfdisk -q "$d/$1.img"
    dd if="$d/esp.img" of="$d/$1.img" bs=512 seek=2048 conv=notrunc 2>/dev/null
}
# boot <description> <first disk> <second disk, which holds dklilo>
boot() {
    cp /usr/share/OVMF/OVMF_VARS_4M.fd "$d/vars.fd"
    rm -f "$d/serial.txt" "$d/monitor"
    if python3 -I "$here/bios-drive.py" "$d/serial.txt" "$d/monitor" \
        "wait:dklilo boot menu" key:ret "wait:FAKE-BOOTMGR-OK" -- \
        qemu-system-x86_64 -machine q35 -m 512 \
        -drive if=pflash,format=raw,readonly=on,file="$code" \
        -drive if=pflash,format=raw,file="$d/vars.fd" \
        -drive if=none,id=a,format=raw,file="$d/$2.img" -device ide-hd,drive=a,bus=ide.0 \
        -drive if=none,id=b,format=raw,file="$d/$3.img" -device ide-hd,drive=b,bus=ide.1 \
        > "$d/drive.txt"; then
        echo "ok: $1"
    else
        echo "FAIL: $1: $(cat "$d/drive.txt")"
        sed 's/\x1b\[[0-9;]*[A-Za-z]/ /g' "$d/serial.txt" | tail -c 400; echo
        failures=$((failures + 1))
    fi
}

disk other "$d/broken.efi"
disk own "$root/zig-out/bin/fake-bootmgfw.efi" with-loader
boot "dklilo's own disk is preferred to one the firmware lists first" other own

disk other "$root/zig-out/bin/fake-bootmgfw.efi"
disk own "$d/broken.efi" with-loader
boot "a boot manager that won't load doesn't end the search" other own

[ $failures -eq 0 ] || { echo "FAIL: $failures chainload case(s)"; exit 1; }
echo "PASS: UEFI chainload picks a boot manager that works, from our disk first"
