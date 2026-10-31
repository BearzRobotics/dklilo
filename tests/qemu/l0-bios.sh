#!/bin/sh
# L0 BIOS check: assemble a disk by hand (stage 1 in the MBR, stage 2 at
# LBA 1, block list patched in as the installer will), boot it under SeaBIOS
# and expect stage 2's banner on COM1. Usage: l0-bios.sh [zig-out dir]
set -eu
dir="${1:-zig-out}"
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
python3 - "$dir/stage1.bin" "$dir/stage2.bin" "$d/disk.img" <<'PY'
import sys, struct
s1 = bytearray(open(sys.argv[1], 'rb').read())
s2 = open(sys.argv[2], 'rb').read()
sectors = (len(s2) + 511) // 512
s1[416:426] = struct.pack('<QH', 1, sectors)      # block list: LBA 1, N sectors
disk = bytearray(1024 * 1024)
disk[0:512] = s1
disk[512:512 + len(s2)] = s2
open(sys.argv[3], 'wb').write(disk)
PY
timeout 5 qemu-system-x86_64 -drive format=raw,file="$d/disk.img" \
    -display none -serial "file:$d/serial.txt" -no-reboot >/dev/null 2>&1 || true
grep -q "stage2 (32-bit)" "$d/serial.txt" \
    && echo "PASS: BIOS stage 2 reached protected mode and printed over serial" \
    || { echo "FAIL: serial output was:"; cat "$d/serial.txt"; exit 1; }
