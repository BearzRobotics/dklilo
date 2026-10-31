#!/bin/sh
# Boots a disk image under OVMF with the serial console in <serial file>.
# Usage: qemu-uefi.sh <disk.img> <serial file> [timeout seconds] [extra qemu args...]
set -eu
disk="$1"; serial="$2"; t="${3:-60}"; shift; shift; [ $# -gt 0 ] && shift || true
v=$(mktemp); trap 'rm -f "$v"' EXIT
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$v"
timeout "$t" qemu-system-x86_64 -machine q35 -m 1024 -display none -no-reboot \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file="$v" \
    -drive format=raw,file="$disk" \
    -serial "file:$serial" "$@" >/dev/null 2>&1 || true
