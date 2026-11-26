#!/bin/sh
# L7: what `dklilo isohybrid` writes (docs/bugs INST-14). Builds small ISOs
# with xorriso; needs no QEMU and no kernel.
#
# Skips (77) without xorriso.
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
dk="$root/zig-out/bin/dklilo"
command -v xorriso >/dev/null || { echo "SKIP: no xorriso"; exit 77; }
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
failures=0
bad() { echo "FAIL: $*"; failures=$((failures + 1)); }
"$dk" mkiso-images "$d" >/dev/null || exit 1

# iso <out> [xorriso options for the system area]
iso() {
    out="$1"; shift
    rm -rf "$d/tree" "$out"; mkdir -p "$d/tree/boot/dklilo"
    cp "$d/eltorito.bin" "$d/efiboot.img" "$d/tree/boot/dklilo/"
    xorriso -as mkisofs -quiet -R -V DKLISO -o "$out" "$@" \
        -b boot/dklilo/eltorito.bin -no-emul-boot -boot-load-size 4 -boot-info-table \
        -eltorito-alt-boot -e boot/dklilo/efiboot.img -no-emul-boot "$d/tree" > "$d/xorriso.log" 2>&1
}
count() { od -An -tu2 -j424 -N2 "$1" | tr -d ' '; }

iso "$d/a.iso" --grub2-mbr "$d/mbr.bin"
sectors=$(od -An -tu2 -j64 -N2 "$d/eltorito.bin" | tr -d ' ') # CD sectors of stage 2
if "$dk" isohybrid "$d/a.iso" > "$d/out.txt" 2>&1 && [ "$(count "$d/a.iso")" -gt 0 ]; then
    echo "ok: makes an ISO bootable from a stick"
else bad "isohybrid: $(cat "$d/out.txt")"; fi

# An ISO made by another dklilo version, whose stage 2 has another length.
longer=$((sectors + 7))
printf "\\$(printf '%03o' $((longer % 256)))\\$(printf '%03o' $((longer / 256)))" |
    dd of="$d/eltorito.bin" bs=1 seek=64 conv=notrunc 2>/dev/null
head -c $((7 * 2048)) /dev/zero >> "$d/eltorito.bin"
iso "$d/b.iso" --grub2-mbr "$d/mbr.bin"
"$dk" isohybrid "$d/b.iso" > "$d/out.txt" 2>&1
if [ "$(count "$d/b.iso")" = $((longer * 4)) ]; then echo "ok: takes stage 2's length from the ISO"
else bad "recorded $(count "$d/b.iso") sectors, the ISO's stage 2 has $((longer * 4))"; fi

# Built without dklilo's boot code in the system area.
iso "$d/c.iso"
before=$(sha256sum "$d/c.iso" | cut -d' ' -f1)
if "$dk" isohybrid "$d/c.iso" > "$d/out.txt" 2>&1; then bad "wrote into an ISO without dklilo's boot code"
elif [ "$(sha256sum "$d/c.iso" | cut -d' ' -f1)" != "$before" ]; then bad "refused, but changed the ISO"
else echo "ok: refuses an ISO without dklilo's boot code"; fi

[ $failures -eq 0 ] || { echo "FAIL: $failures isohybrid case(s)"; exit 1; }
echo "PASS: isohybrid writes only what the ISO calls for"
