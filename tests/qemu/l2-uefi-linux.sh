#!/bin/sh
# L2: dklilo (UEFI) boots Linux from ext4 with a two-file initramfs, and the
# kernel command line it was given reaches the kernel.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
cat > "$d/dklilo.conf" <<'C'
timeout = 1
default = test
image  = /boot/vmlinuz
    label  = test
    root   = PARTUUID=4a6f8c21-0000-4000-8000-000000000002
    append = "console=ttyS0 quiet dkl=yes"
    initrd = /boot/initrd1.img
    initrd = /boot/initrd2.cpio
C
rc=0; "$here/make-linux-disk.sh" "$d/disk.img" "$d/dklilo.conf" || rc=$?
[ $rc -eq 77 ] && exit 77
[ $rc -eq 0 ] || exit $rc
"$here/qemu-uefi.sh" "$d/disk.img" "$d/serial.txt" 90
ok=1
for want in "DKLILO-INITRAMFS-OK" "dkl=yes" "root=PARTUUID=4a6f8c21-0000-4000-8000-000000000002" \
            "file /marker1: from-initrd-1" "file /marker2: from-initrd-2" "DKLILO-DONE"; do
    grep -qF -- "$want" "$d/serial.txt" || { echo "missing: $want"; ok=0; }
done
if [ $ok -eq 1 ]; then echo "PASS: UEFI boot of Linux from ext4 with 2-file initramfs"; else echo "FAIL; serial tail:"; tail -20 "$d/serial.txt"; exit 1; fi
