#!/bin/sh
# L7: a hybrid ISO built with xorriso boots Linux through dklilo from a virtual
# DVD and from a USB-style raw disk, on both BIOS and UEFI.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
dk="$root/zig-out/bin/dklilo"
kernel="${DKLILO_KERNEL:-$HOME/.cache/dklilo/vmlinuz}"
[ -f "$kernel" ] || { echo "SKIP: no kernel at $kernel"; exit 77; }
command -v xorriso >/dev/null || { echo "SKIP: no xorriso"; exit 77; }
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

mkdir -p "$d/img" "$d/tree/boot/dklilo"
"$dk" mkiso-images "$d/img" >/dev/null
cp "$d/img/eltorito.bin" "$d/img/efiboot.img" "$d/tree/boot/dklilo/"
cp "$kernel" "$d/tree/boot/vmlinuz"
python3 "$root/tests/initramfs/mkcpio.py" "$d/i1.cpio" --init "$root/zig-out/bin/init" --file marker1=from-initrd-1
gzip -c "$d/i1.cpio" > "$d/tree/boot/initrd1.img"
python3 "$root/tests/initramfs/mkcpio.py" "$d/tree/boot/initrd2.cpio" --file marker2=from-initrd-2
cat > "$d/tree/boot/dklilo.conf" <<'C'
timeout = 1
default = iso
image  = /boot/vmlinuz
    label  = iso
    append = "console=ttyS0 quiet dkl=iso"
    initrd = /boot/initrd1.img
    initrd = /boot/initrd2.cpio
C

xorriso -as mkisofs -quiet -R -V DKLISO -o "$d/dklilo.iso" \
    --grub2-mbr "$d/img/mbr.bin" \
    -b boot/dklilo/eltorito.bin -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot -e boot/dklilo/efiboot.img -no-emul-boot \
    -append_partition 2 0xEF "$d/img/efiboot.img" -appended_part_as_gpt \
    "$d/tree" > "$d/xorriso.log" 2>&1 || { cat "$d/xorriso.log"; fail "xorriso"; }
"$dk" isohybrid "$d/dklilo.iso" >/dev/null || fail "isohybrid"

ok() { # serial-file
    for want in "DKLILO-INITRAMFS-OK" "dkl=iso" "file /marker1: from-initrd-1" "file /marker2: from-initrd-2" "DKLILO-DONE"; do
        grep -qaF -- "$want" "$1" || return 1
    done
}
bios() { # label qemu-args...
    label=$1; shift
    timeout 90 qemu-system-x86_64 -m 1024 -display none -no-reboot -serial "file:$d/$label.txt" "$@" >/dev/null 2>&1 || true
    ok "$d/$label.txt" || { echo "--- $label serial tail:"; tail -c 600 "$d/$label.txt" | cat -v; fail "$label"; }
    echo "PASS: $label"
}
uefi() {
    label=$1; shift
    cp /usr/share/OVMF/OVMF_VARS_4M.fd "$d/vars.fd"
    timeout 90 qemu-system-x86_64 -machine q35 -m 1024 -display none -no-reboot -serial "file:$d/$label.txt" \
        -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
        -drive if=pflash,format=raw,file="$d/vars.fd" "$@" >/dev/null 2>&1 || true
    ok "$d/$label.txt" || { echo "--- $label serial tail:"; tail -c 600 "$d/$label.txt" | cat -v; fail "$label"; }
    echo "PASS: $label"
}

bios "BIOS from DVD" -cdrom "$d/dklilo.iso" -boot d
bios "BIOS from USB disk" -drive format=raw,file="$d/dklilo.iso"
uefi "UEFI from DVD" -drive format=raw,media=cdrom,file="$d/dklilo.iso"
uefi "UEFI from USB disk" -drive format=raw,file="$d/dklilo.iso"
