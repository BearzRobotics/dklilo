#!/bin/sh
# L11: the AArch64 UEFI loader. Without a kernel it checks that the loader runs
# under AAVMF and that the installer writes the AArch64 file names. With an
# arm64 kernel (DKLILO_KERNEL_AA64, an Image with the EFI stub) it also boots
# Linux from ext4 with an initramfs, like l2-uefi-linux.sh does for x86_64.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
dk="$root/zig-out/bin/dklilo"
fail() { echo "FAIL: $*"; exit 1; }
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT

# 1. The loader runs (skips the whole test if there is no AArch64 QEMU).
"$here/l0-uefi-aa64.sh" || { rc=$?; exit $rc; }

# 2. The installer writes AArch64 names.
mkdir -p "$d/esp"
"$dk" install-uefi "$d/esp" --arch aa64 --removable --yes >/dev/null || fail "install-uefi --arch aa64 --removable"
[ -f "$d/esp/EFI/BOOT/BOOTAA64.EFI" ] || fail "no BOOTAA64.EFI written"
cmp -s "$d/esp/EFI/BOOT/BOOTAA64.EFI" "$root/zig-out/bin/dkliloAA64.efi" || fail "BOOTAA64.EFI is not the AArch64 loader"
"$dk" install-uefi "$d/esp3" --arch mips --yes >/dev/null 2>&1 && fail "accepted an unknown architecture"
mkdir -p "$d/iso"
"$dk" mkiso-images "$d/iso" --arch aa64 >/dev/null || fail "mkiso-images --arch aa64"
mdir -i "$d/iso/efiboot.img" ::/EFI/BOOT 2>/dev/null | grep -qi "BOOTAA64" || fail "efiboot.img has no BOOTAA64.EFI"
echo "PASS: installer writes AArch64 loader names (ESP and ISO image)"

# 3. Linux boot, if an arm64 kernel is available.
cat > "$d/dklilo.conf" <<'C'
timeout = 1
default = test
image  = /boot/vmlinuz
    label  = test
    root   = PARTUUID=4a6f8c21-0000-4000-8000-000000000002
    append = "console=ttyAMA0 earlycon quiet dkl=yes"
    initrd = /boot/initrd1.img
    initrd = /boot/initrd2.cpio
C
rc=0; ARCH=aa64 "$here/make-linux-disk.sh" "$d/disk.img" "$d/dklilo.conf" || rc=$?
[ $rc -eq 77 ] && { echo "SKIP: no arm64 kernel for the Linux boot (set DKLILO_KERNEL_AA64)"; exit 0; }
[ $rc -eq 0 ] || exit $rc
ARCH=aa64 "$here/qemu-uefi.sh" "$d/disk.img" "$d/serial.txt" 180
ok=1
for want in "DKLILO-INITRAMFS-OK" "dkl=yes" "file /marker1: from-initrd-1" "file /marker2: from-initrd-2" "DKLILO-DONE"; do
    grep -qaF -- "$want" "$d/serial.txt" || { echo "missing: $want"; ok=0; }
done
if [ $ok -eq 1 ]; then echo "PASS: AArch64 UEFI boot of Linux from ext4 with 2-file initramfs"; else echo "FAIL; serial tail:"; tail -20 "$d/serial.txt"; exit 1; fi
