#!/bin/sh
# L3: a failed boot must leave a way out (docs/bugs CMN-01): the menu, even
# when the configuration boots without showing it, and from the menu a prompt
# to boot by hand, behind the password if there is one. Fake bzImages are
# used, so no Linux is needed.
#
# Skips (77) without qemu-system-x86_64.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
dk="$root/zig-out/bin/dklilo"
command -v qemu-system-x86_64 >/dev/null || { echo "SKIP: no qemu-system-x86_64"; exit 77; }
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
failures=0

# disk <name>: a BIOS disk with the configuration read from stdin
disk() {
    rm -rf "$d/root"; mkdir -p "$d/root/boot"
    python3 -I "$here/fake-bzimage.py" "$d/root/boot/vmlinuz"
    cat > "$d/root/boot/dklilo.conf"
    rm -f "$d/fs.img" "$d/$1.img"
    truncate -s 16M "$d/fs.img"
    mkfs.ext4 -F -q -b 4096 -d "$d/root" "$d/fs.img"
    truncate -s 24M "$d/$1.img"
    printf 'label: dos\nstart=2048, size=32768, type=83\n' | sfdisk -q "$d/$1.img"
    dd if="$d/fs.img" of="$d/$1.img" bs=512 seek=2048 conv=notrunc 2>/dev/null
    "$dk" install-bios "$d/$1.img" --yes >/dev/null
}
# boot <description> <disk> <bios-drive step>...
boot() {
    what="$1"; name="$2"; shift 2
    rm -f "$d/serial.txt" "$d/monitor"
    if python3 -I "$here/bios-drive.py" "$d/serial.txt" "$d/monitor" "$@" -- \
        qemu-system-x86_64 -m 256 -drive format=raw,file="$d/$name.img" > "$d/drive.txt"; then
        echo "ok: $what"
    else
        echo "FAIL: $what: $(cat "$d/drive.txt")"
        sed 's/\x1b\[[0-9;]*[A-Za-z]/ /g' "$d/serial.txt" | tail -c 300; echo
        failures=$((failures + 1))
    fi
}
# The keys that type a kernel path, then accept it and an empty command line.
kernel="key:slash key:b key:o key:o key:t key:slash key:v key:m key:l key:i key:n key:u key:z key:ret key:ret"

disk instant <<'C'
timeout = 0
image = /boot/missing
    label = broken
image = /boot/vmlinuz
    label = good
C
boot "after a failed instant boot, the menu offers the other entry" instant \
    "wait:Boot failed" key:ret "wait:dklilo boot menu" key:down key:ret "wait:Starting kernel"

disk single <<'C'
timeout = 20
image = /boot/missing
    label = broken
C
boot "with one broken entry, a kernel can be booted by hand" single \
    "wait:Boot failed" key:ret "wait:dklilo boot menu" key:m "wait:Kernel path" \
    $kernel "wait:Starting kernel"

disk locked <<C
timeout = 0
password = $(printf %s secret | sha256sum | cut -d' ' -f1)
image = /boot/missing
    label = broken
    restricted
C
boot "booting by hand needs the password" locked \
    "wait:Boot failed" key:ret "wait:dklilo boot menu" key:m "wait:Password" \
    key:x key:ret "wait:Access denied" "wait:dklilo boot menu" \
    key:m "wait:Password" key:s key:e key:c key:r key:e key:t key:ret "wait:Kernel path" \
    $kernel "wait:Starting kernel"

[ $failures -eq 0 ] || { echo "FAIL: $failures retry case(s)"; exit 1; }
echo "PASS: a failed boot leaves a way out"
