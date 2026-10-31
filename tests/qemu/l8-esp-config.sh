#!/bin/sh
# The configuration lives on the FAT ESP (\EFI\dklilo\dklilo.conf), read with
# dklilo's own FAT reader; the kernel and initramfs are on the ext4 root,
# named with a LABEL= prefix (plain paths refer to the config's own volume).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
cat > "$d/dklilo.conf" <<'C'
timeout = 1
default = esp
image  = LABEL=dklroot:/boot/vmlinuz
    label  = esp
    append = "console=ttyS0 quiet dkl=espconf"
    initrd = LABEL=dklroot:/boot/initrd1.img
    initrd = LABEL=dklroot:/boot/initrd2.cpio
C
export CONFIG_IN_ESP=1
rc=0; "$here/make-linux-disk.sh" "$d/disk.img" "$d/dklilo.conf" || rc=$?
[ $rc -eq 77 ] && exit 77
[ $rc -eq 0 ] || exit $rc
"$here/qemu-uefi.sh" "$d/disk.img" "$d/serial.txt" 90
ok=1
for want in "DKLILO-INITRAMFS-OK" "dkl=espconf" "file /marker1: from-initrd-1" "file /marker2: from-initrd-2"; do
    grep -qaF -- "$want" "$d/serial.txt" || { echo "missing: $want"; ok=0; }
done
if [ $ok -eq 1 ]; then echo "PASS: config read from the ESP (FAT), kernel from ext4 via LABEL="; else
    echo "FAIL; serial tail:"; tail -c 1200 "$d/serial.txt" | cat -v | tail -20; exit 1; fi
