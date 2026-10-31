#!/bin/sh
# L4: dklilo boots Linux from a zstd-compressed btrfs root on both firmware
# types, with the kernel and initramfs inside a btrfs subvolume selected by
# `subvol =` in the configuration.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
# /boot is a subvolume, so inside it paths start at /; the config itself is
# found at /boot/dklilo.conf by crossing into the subvolume.
cat > "$d/dklilo.conf" <<'C'
timeout = 1
default = test
image  = /vmlinuz
    label  = test
    subvol = boot
    append = "console=ttyS0 quiet dkl=btrfs"
    initrd = /initrd1.img
    initrd = /initrd2.cpio
C
export ROOTFS=btrfs
rc=0; "$here/make-bios-disk.sh" "$d/bios.img" "$d/dklilo.conf" mbr || rc=$?
[ $rc -eq 77 ] && exit 77
[ $rc -eq 0 ] || exit $rc
"$here/make-linux-disk.sh" "$d/uefi.img" "$d/dklilo.conf"

check() { # label serial-file
    ok=1
    for want in "DKLILO-INITRAMFS-OK" "dkl=btrfs" "file /marker1: from-initrd-1" \
                "file /marker2: from-initrd-2" "DKLILO-DONE"; do
        grep -qaF -- "$want" "$2" || { echo "missing ($1): $want"; ok=0; }
    done
    if [ $ok -eq 1 ]; then echo "PASS: $1 boot of Linux from zstd btrfs subvolume"; else
        echo "FAIL ($1); serial tail:"; tail -c 1500 "$2" | cat -v | tail -20; return 1; fi
}

timeout 120 qemu-system-x86_64 -m 1024 -display none -no-reboot \
    -drive format=raw,file="$d/bios.img" -serial "file:$d/bios.txt" >/dev/null 2>&1 || true
check BIOS "$d/bios.txt"
"$here/qemu-uefi.sh" "$d/uefi.img" "$d/uefi.txt" 120
check UEFI "$d/uefi.txt"
