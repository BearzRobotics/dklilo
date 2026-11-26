#!/bin/sh
# L3: the BIOS loader must refuse what doesn't fit in memory instead of
# overwriting itself or starting a kernel that can't run (docs/bugs BIOS-03).
# Fake bzImages are used, so no Linux is needed.
#
# Skips (77) without qemu-system-x86_64.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
dk="$root/zig-out/bin/dklilo"
command -v qemu-system-x86_64 >/dev/null || { echo "SKIP: no qemu-system-x86_64"; exit 77; }
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
failures=0

# disk <name> <fake-bzimage options...>: a BIOS disk that boots that kernel
disk() {
    name="$1"; shift
    rm -rf "$d/root"; mkdir -p "$d/root/boot"
    python3 -I "$here/fake-bzimage.py" "$d/root/boot/vmlinuz" "$@"
    printf 'timeout = 0\nimage = /boot/vmlinuz\n    label = k\n' > "$d/root/boot/dklilo.conf"
    rm -f "$d/fs.img" "$d/$name.img"
    truncate -s 64M "$d/fs.img"
    mkfs.ext4 -F -q -b 4096 -d "$d/root" "$d/fs.img"
    truncate -s 72M "$d/$name.img"
    printf 'label: dos\nstart=2048, size=131072, type=83\n' | sfdisk -q "$d/$name.img"
    dd if="$d/fs.img" of="$d/$name.img" bs=512 seek=2048 conv=notrunc,sparse 2>/dev/null
    "$dk" install-bios "$d/$name.img" --yes >/dev/null
}
# boot <description> <disk> <MiB of RAM> <expected text>...
boot() {
    what="$1"; name="$2"; ram="$3"; shift 3
    steps=""
    n=$#
    while [ $n -gt 0 ]; do set -- "$@" "wait:$1"; shift; n=$((n - 1)); done
    rm -f "$d/serial.txt" "$d/monitor"
    if python3 -I "$here/bios-drive.py" "$d/serial.txt" "$d/monitor" "$@" -- \
        qemu-system-x86_64 -m "$ram" -drive format=raw,file="$d/$name.img" > "$d/drive.txt"; then
        echo "ok: $what"
    else
        echo "FAIL: $what"; sed 's/\x1b\[[0-9;]*[A-Za-z]/ /g' "$d/serial.txt" | tail -c 400; echo
        failures=$((failures + 1))
    fi
}

disk small
boot "an ordinary kernel boots" small 256 "Starting kernel"
boot "and with only 64 MiB of RAM" small 64 "Starting kernel"
boot "too little RAM for the loader is reported" small 24 "dklilo: not enough memory"

disk big --size-mib 28
boot "a 28 MiB kernel still boots" big 256 "Starting kernel"
disk huge --size-mib 31
boot "a kernel reaching the loader's stack is refused" huge 256 "kernel too large" "Boot failed"

disk hungry --init-size-mib 200
boot "a kernel with room to decompress boots" hungry 256 "Starting kernel"
boot "a kernel without room to decompress is refused" hungry 64 "not enough memory" "Boot failed"

# A kernel that wants to run high must find memory there (docs/bugs BIOS-04).
disk high --pref-mib 200 --init-size-mib 8
boot "a kernel preferring a high address boots with RAM there" high 256 "Starting kernel"
boot "and is refused without it" high 64 "not enough memory" "Boot failed"

[ $failures -eq 0 ] || { echo "FAIL: $failures memory case(s)"; exit 1; }
echo "PASS: the BIOS loader checks that everything fits in memory"
