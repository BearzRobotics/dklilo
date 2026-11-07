#!/bin/sh
# L12: the RISC-V 64 and 32-bit ARM UEFI loaders.
#  * RISC-V runs under edk2 on QEMU "virt" (the loader is a PE file made by
#    tools/elf2efi.zig, so this is the real test that it loads and runs).
#  * 32-bit ARM has no firmware on most hosts (there is no AAVMF32 here), so
#    only its build, PE machine type and installer file names are checked.
# Skips (77) without qemu-system-riscv64 and the RISC-V firmware.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
dk="$root/zig-out/bin/dklilo"
fail() { echo "FAIL: $*"; exit 1; }
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT

# ---- installer names, both architectures ------------------------------------
for pair in riscv64:BOOTRISCV64.EFI:dkliloRISCV64.efi arm:BOOTARM.EFI:dkliloARM.efi; do
    a=${pair%%:*}; rest=${pair#*:}; fb=${rest%%:*}; img=${rest#*:}
    mkdir -p "$d/esp-$a"
    "$dk" install-uefi "$d/esp-$a" --arch "$a" --removable --yes >/dev/null || fail "install-uefi --arch $a"
    cmp -s "$d/esp-$a/EFI/BOOT/$fb" "$root/zig-out/bin/$img" || fail "$fb is not the $a loader"
    mkdir -p "$d/iso-$a"
    "$dk" mkiso-images "$d/iso-$a" --arch "$a" >/dev/null || fail "mkiso-images --arch $a"
    mdir -i "$d/iso-$a/efiboot.img" ::/EFI/BOOT 2>/dev/null | grep -qi "${fb%.EFI}" || fail "efiboot.img has no $fb"
done
file "$root/zig-out/bin/dkliloARM.efi" | grep -q "ARMv7" || fail "dkliloARM.efi is not an ARM PE"
file "$root/zig-out/bin/dkliloRISCV64.efi" | grep -q "RISC-V" || fail "dkliloRISCV64.efi is not a RISC-V PE"
echo "PASS: installer writes RISC-V and ARM loader names (ESP and ISO image, long names)"

# ---- RISC-V under edk2 -------------------------------------------------------
code=/usr/share/qemu-efi-riscv64/RISCV_VIRT_CODE.fd
vars=/usr/share/qemu-efi-riscv64/RISCV_VIRT_VARS.fd
command -v qemu-system-riscv64 >/dev/null || { echo "SKIP: no qemu-system-riscv64"; exit 77; }
[ -f "$code" ] && [ -f "$vars" ] || { echo "SKIP: no RISC-V edk2 firmware"; exit 77; }
mkdir -p "$d/esp/EFI/BOOT"
cp "$root/zig-out/bin/dkliloRISCV64.efi" "$d/esp/EFI/BOOT/BOOTRISCV64.EFI"
cp "$code" "$d/code.fd"; cp "$vars" "$d/vars.fd"
truncate -s 32M "$d/code.fd" "$d/vars.fd"
timeout 90 qemu-system-riscv64 -machine virt,acpi=off -m 1024 -display none -no-reboot \
    -blockdev node-name=pf0,driver=file,read-only=on,filename="$d/code.fd" \
    -blockdev node-name=pf1,driver=file,filename="$d/vars.fd" \
    -machine pflash0=pf0,pflash1=pf1 \
    -drive file=fat:rw:"$d/esp",format=raw,if=virtio \
    -serial "file:$d/serial.txt" >/dev/null 2>&1 || true
grep -qa "dklilo: no usable configuration" "$d/serial.txt" \
    && echo "PASS: RISC-V UEFI loader ran under edk2 and read the boot disk" \
    || { echo "FAIL; serial:"; strings "$d/serial.txt" | tail -5; exit 1; }
