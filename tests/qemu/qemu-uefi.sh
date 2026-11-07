#!/bin/sh
# Boots a disk image under OVMF with the serial console in <serial file>.
# Usage: qemu-uefi.sh <disk.img> <serial file> [timeout seconds] [extra qemu args...]
set -eu
disk="$1"; serial="$2"; t="${3:-60}"; shift; shift; [ $# -gt 0 ] && shift || true
v=$(mktemp); trap 'rm -f "$v"' EXIT
if [ "${ARCH:-x64}" = aa64 ]; then
    # AArch64 "virt" machine with AAVMF; the serial port is a PL011.
    cp /usr/share/AAVMF/AAVMF_VARS.fd "$v"
    timeout "$t" qemu-system-aarch64 -machine virt -cpu cortex-a57 -m 1024 -display none -no-reboot \
        -drive if=pflash,format=raw,readonly=on,file=/usr/share/AAVMF/AAVMF_CODE.fd \
        -drive if=pflash,format=raw,file="$v" \
        -drive format=raw,file="$disk" \
        -serial "file:$serial" "$@" >/dev/null 2>&1 || true
    exit 0
fi
if [ "${ARCH:-x64}" = riscv64 ]; then
    # RISC-V "virt" with edk2; the firmware images must be padded to 32 MiB.
    c=$(mktemp); trap 'rm -f "$v" "$c"' EXIT
    cp /usr/share/qemu-efi-riscv64/RISCV_VIRT_CODE.fd "$c"; cp /usr/share/qemu-efi-riscv64/RISCV_VIRT_VARS.fd "$v"
    truncate -s 32M "$c" "$v"
    timeout "$t" qemu-system-riscv64 -machine virt,acpi=off -m 1024 -display none -no-reboot \
        -blockdev node-name=pf0,driver=file,read-only=on,filename="$c" \
        -blockdev node-name=pf1,driver=file,filename="$v" \
        -machine pflash0=pf0,pflash1=pf1 \
        -drive file="$disk",format=raw,if=virtio \
        -serial "file:$serial" "$@" >/dev/null 2>&1 || true
    exit 0
fi
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$v"
timeout "$t" qemu-system-x86_64 -machine q35 -m 1024 -display none -no-reboot \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file="$v" \
    -drive format=raw,file="$disk" \
    -serial "file:$serial" "$@" >/dev/null 2>&1 || true
