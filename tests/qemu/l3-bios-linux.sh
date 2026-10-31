#!/bin/sh
# L3: dklilo (BIOS) boots Linux from ext4 with a two-file initramfs, from
# both an MBR disk and a GPT disk (stage 2 in a BIOS boot partition).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
cat > "$d/dklilo.conf" <<'C'
timeout = 1
default = test
image  = /boot/vmlinuz
    label  = test
    append = "console=ttyS0 quiet dkl=bios"
    initrd = /boot/initrd1.img
    initrd = /boot/initrd2.cpio
C
for kind in mbr gpt; do
    rc=0; "$here/make-bios-disk.sh" "$d/disk.img" "$d/dklilo.conf" "$kind" || rc=$?
    [ $rc -eq 77 ] && exit 77
    [ $rc -eq 0 ] || exit $rc
    timeout 90 qemu-system-x86_64 -m 1024 -display none -no-reboot \
        -drive format=raw,file="$d/disk.img" -serial "file:$d/serial.txt" >/dev/null 2>&1 || true
    ok=1
    for want in "DKLILO-INITRAMFS-OK" "dkl=bios" "file /marker1: from-initrd-1" \
                "file /marker2: from-initrd-2" "DKLILO-DONE"; do
        grep -qaF -- "$want" "$d/serial.txt" || { echo "missing: $want"; ok=0; }
    done
    if [ $ok -eq 1 ]; then echo "PASS: BIOS boot of Linux from ext4 with 2-file initramfs ($kind disk)"; else echo "FAIL; serial tail:"; tail -c 2000 "$d/serial.txt" | cat -v | tail -25; exit 1; fi

done
