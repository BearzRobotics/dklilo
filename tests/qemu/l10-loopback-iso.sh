#!/bin/sh
# L10: an entry with `iso =` boots the kernel and initramfs from inside an ISO
# file stored on an ext4 or btrfs partition, on BIOS and UEFI, and the kernel
# is told where the ISO is (iso-scan/filename=).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
kernel="${DKLILO_KERNEL:-$HOME/.cache/dklilo/vmlinuz}"
[ -f "$kernel" ] || { echo "SKIP: no kernel at $kernel"; exit 77; }
command -v xorriso >/dev/null || { echo "SKIP: no xorriso"; exit 77; }
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

# The ISO holds the kernel and initramfs at its top level; the host
# filesystem's own /boot copies are not used by this entry.
mkdir -p "$d/isotree"
cp "$kernel" "$d/isotree/vmlinuz"
python3 "$root/tests/initramfs/mkcpio.py" "$d/i1.cpio" --init "$root/zig-out/bin/init" --file marker1=from-initrd-1
gzip -c "$d/i1.cpio" > "$d/isotree/initrd1.img"
python3 "$root/tests/initramfs/mkcpio.py" "$d/isotree/initrd2.cpio" --file marker2=from-initrd-2
xorriso -as mkisofs -quiet -R -V LOOPISO -o "$d/test.iso" "$d/isotree" >/dev/null 2>&1

cat > "$d/dklilo.conf" <<'C'
timeout = 1
default = loop
image  = /vmlinuz
    label  = loop
    iso    = /isos/test.iso
    append = "console=ttyS0 quiet dkl=loop"
    initrd = /initrd1.img
    initrd = /initrd2.cpio
C
export EXTRA_FILE="$d/test.iso"

ok() {
    for want in "DKLILO-INITRAMFS-OK" "dkl=loop iso-scan/filename=/isos/test.iso" \
                "file /marker1: from-initrd-1" "file /marker2: from-initrd-2" "DKLILO-DONE"; do
        grep -qaF -- "$want" "$1" || { echo "missing: $want"; return 1; }
    done
}

for fs in ext4 btrfs; do
    export ROOTFS=$fs
    rc=0; "$here/make-bios-disk.sh" "$d/bios.img" "$d/dklilo.conf" mbr || rc=$?
    [ $rc -eq 77 ] && exit 77
    [ $rc -eq 0 ] || exit $rc
    timeout 120 qemu-system-x86_64 -m 1024 -display none -no-reboot \
        -drive format=raw,file="$d/bios.img" -serial "file:$d/bios-$fs.txt" >/dev/null 2>&1 || true
    ok "$d/bios-$fs.txt" || { tail -c 800 "$d/bios-$fs.txt" | cat -v; fail "BIOS loopback ISO on $fs"; }
    echo "PASS: BIOS boots from an ISO file on $fs"

    "$here/make-linux-disk.sh" "$d/uefi.img" "$d/dklilo.conf"
    "$here/qemu-uefi.sh" "$d/uefi.img" "$d/uefi-$fs.txt" 120
    ok "$d/uefi-$fs.txt" || { tail -c 800 "$d/uefi-$fs.txt" | cat -v; fail "UEFI loopback ISO on $fs"; }
    echo "PASS: UEFI boots from an ISO file on $fs"
done
