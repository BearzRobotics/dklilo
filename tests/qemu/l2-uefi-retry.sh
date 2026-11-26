#!/bin/sh
# L2: after a boot that returns to the loader, the next one must work and must
# not inherit the previous entry's initramfs (docs/bugs UEFI-01, UEFI-02). A
# fake EFI application stands in for the kernel: it reports the initramfs it
# is offered and returns. No Linux is needed.
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

cat > "$d/dklilo.conf" <<'C'
prompt
image  = /fake.efi
    label  = with-initrd
    initrd = /initrd.img
image  = /fake.efi
    label  = without-initrd
image  = /fake.efi
    label  = accented
    append = "name=é€"
C
printf '0123456789' > "$d/initrd.img" # offered as 12 bytes: padded to 4
truncate -s 33M "$d/esp.img"
mkfs.fat -F 16 -n ESP "$d/esp.img" >/dev/null
mmd -i "$d/esp.img" ::/EFI ::/EFI/BOOT ::/EFI/dklilo
mcopy -i "$d/esp.img" "$root/zig-out/bin/dkliloX64.efi" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$d/esp.img" "$d/dklilo.conf" ::/EFI/dklilo/dklilo.conf
mcopy -i "$d/esp.img" "$root/zig-out/bin/fake-bootmgfw.efi" ::/fake.efi
mcopy -i "$d/esp.img" "$d/initrd.img" ::/initrd.img
truncate -s 40M "$d/disk.img"
printf 'label: gpt\nstart=2048, size=67584, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B\n' | sfdisk -q "$d/disk.img"
dd if="$d/esp.img" of="$d/disk.img" bs=512 seek=2048 conv=notrunc 2>/dev/null

# boot <description> <bios-drive step>...
boot() {
    what="$1"; shift
    cp /usr/share/OVMF/OVMF_VARS_4M.fd "$d/vars.fd"
    rm -f "$d/serial.txt" "$d/monitor"
    if python3 -I "$here/bios-drive.py" "$d/serial.txt" "$d/monitor" "$@" -- \
        qemu-system-x86_64 -machine q35 -m 512 \
        -drive if=pflash,format=raw,readonly=on,file="$code" \
        -drive if=pflash,format=raw,file="$d/vars.fd" \
        -drive format=raw,file="$d/disk.img" > "$d/drive.txt"; then
        echo "ok: $what"
    else
        echo "FAIL: $what: $(cat "$d/drive.txt")"
        sed 's/\x1b\[[0-9;]*[A-Za-z]/ /g' "$d/serial.txt" | tail -c 500; echo
        failures=$((failures + 1))
    fi
}

boot "the same entry boots twice" \
    "wait:dklilo boot menu" key:ret "wait:initrd=12" "wait:Press a key" key:ret \
    "wait:dklilo boot menu" key:ret "wait:initrd=12"
boot "an entry without an initramfs is offered none" \
    "wait:dklilo boot menu" key:ret "wait:initrd=12" "wait:Press a key" key:ret \
    "wait:dklilo boot menu" key:down key:ret "wait:initrd=none"

boot "a command line that isn't ASCII arrives as text" \
    "wait:dklilo boot menu" key:up key:ret "wait:unit=00e9 unit=20ac"

[ $failures -eq 0 ] || { echo "FAIL: $failures retry case(s)"; exit 1; }
echo "PASS: a boot that returns leaves nothing behind"
