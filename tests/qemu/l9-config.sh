#!/bin/sh
# L9: `dklilo config` on a system whose /boot is a btrfs subvolume writes a
# config with `subvol =` and `rootflags=`, and `dklilo check` then finds every
# file in a real btrfs image. Needs no root: mountinfo is faked (--mountinfo)
# and the image is built with mkfs.btrfs --rootdir.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
dk="$root/zig-out/bin/dklilo"
mkbtrfs="${DKLILO_MKFS_BTRFS:-$(command -v mkfs.btrfs || echo "$HOME/.cache/dklilo/mkfs.btrfs")}"
[ -x "$mkbtrfs" ] || { echo "SKIP: no mkfs.btrfs"; exit 77; }
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

# The files /boot would hold, as a subvolume named "boot" in the image.
mkdir -p "$d/tree/boot"
for f in vmlinuz-6.9.1 initramfs-6.9.1.img vmlinuz-6.10.2 initrd.img-6.10.2 System.map-6.10.2; do
    echo "$f" > "$d/tree/boot/$f"
done

# /dev/vda2 is the root (subvolume @), /dev/vda1 is /boot (subvolume boot).
cat > "$d/mountinfo" <<M
30 1 0:27 /@ / rw - btrfs /dev/vda2 rw,subvol=/@
31 30 0:28 /boot $d/tree/boot rw - btrfs /dev/vda1 rw,subvolid=257,subvol=/boot
M
"$dk" config --boot "$d/tree/boot" --mountinfo "$d/mountinfo" --no-windows --root PARTUUID=aaaa-02 \
    -o "$d/tree/boot/dklilo.conf" 2>"$d/err" || { cat "$d/err"; fail "config"; }
conf="$d/tree/boot/dklilo.conf"
grep -q '^    subvol = boot$' "$conf" || { cat "$conf"; fail "no subvol = boot"; }
grep -q 'rootflags=subvol=@' "$conf" || { cat "$conf"; fail "no rootflags"; }
grep -q 'root   = PARTUUID=aaaa-02' "$conf" || fail "no root="
grep -q '^image  = /vmlinuz-6.10.2$' "$conf" || { cat "$conf"; fail "paths should be relative to the boot subvolume"; }
grep -q 'initrd = /initrd.img-6.10.2' "$conf" || fail "initrd pairing"
echo "PASS: config output (subvol, rootflags, paths)"

truncate -s 128M "$d/disk.img"
"$mkbtrfs" -q -f -L dklboot --rootdir "$d/tree" --subvol rw:boot "$d/disk.img" >/dev/null 2>&1 || fail "mkfs.btrfs"
"$dk" check --device "$d/disk.img" > "$d/check.txt" 2>&1 || { cat "$d/check.txt"; fail "check"; }
grep -q "all files found" "$d/check.txt" || fail "check output"
echo "PASS: check finds every file listed by config in the btrfs image"
