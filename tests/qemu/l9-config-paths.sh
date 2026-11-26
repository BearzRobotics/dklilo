#!/bin/sh
# L9: the paths and entries `dklilo config` writes (docs/bugs INST-04, INST-11,
# INST-12, INST-13). Needs no root, QEMU or kernel: mount tables are faked with
# --mountinfo. Every case runs.
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
dk="$root/zig-out/bin/dklilo"
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
d=$(realpath "$d")
failures=0
bad() { echo "FAIL: $*"; sed 's/^/    /' "$d/conf" "$d/err" 2>/dev/null | tail -14; failures=$((failures + 1)); }

# gen <boot dir> [options...]: the configuration is left in $d/conf
gen() {
    boot="$1"; shift
    "$dk" config --boot "$boot" --mountinfo "$d/mounts" --no-windows "$@" > "$d/conf" 2> "$d/err"
}
files() { dir="$1"; shift; rm -rf "$dir"; mkdir -p "$dir"; for f in "$@"; do echo x > "$dir/$f"; done; }
has() { grep -qF -- "$1" "$d/conf"; }
want() { # description line...
    what="$1"; shift
    for line in "$@"; do has "$line" || { bad "$what: no line '$line'"; return; }; done
    echo "ok: $what"
}

# --boot inside another system's root, mounted somewhere (an installer's target).
files "$d/target/boot" vmlinuz-1
cat > "$d/mounts" <<M
30 1 8:2 / / rw - ext4 /dev/sda2 rw
31 30 8:18 / $d/target rw - ext4 /dev/sdb2 rw
M
gen "$d/target/boot"
want "a mounted target root: paths and root= are the target's" \
    "image  = /boot/vmlinuz-1" "root   = /dev/sdb2"

# A mount whose name is only a prefix of the directory's.
files "$d/m/bootfiles" vmlinuz-1
cat > "$d/mounts" <<M
30 1 8:2 / / rw - ext4 /dev/sda2 rw
31 30 8:3 / $d/m/boot rw - ext4 /dev/sda3 rw
M
gen "$d/m/bootfiles"
want "a mount that is only a name prefix is ignored" "image  = $d/m/bootfiles/vmlinuz-1"

# A mount point with a space in it, as mountinfo writes it.
files "$d/my disk/boot" vmlinuz-1
cat > "$d/mounts" <<M
30 1 8:2 / / rw - ext4 /dev/sda2 rw
31 30 8:3 / $d/my\\040disk rw - ext4 /dev/sda3 rw
M
gen "$d/my disk/boot"
want "an escaped mount point is understood" "image  = /boot/vmlinuz-1"

# / and /boot as two subvolumes of one btrfs.
files "$d/sub/boot" vmlinuz-1
cat > "$d/mounts" <<M
30 1 0:27 /@ / rw - btrfs /dev/vda2 rw,subvol=/@
31 30 0:27 /@boot $d/sub/boot rw - btrfs /dev/vda2 rw,subvol=/@boot
M
gen "$d/sub/boot"
want "two subvolumes of one filesystem" "image  = /vmlinuz-1" "subvol = @boot"

# ---- order, labels and quoting (INST-12) ------------------------------------
printf '30 1 8:2 / / rw - ext4 /dev/sda2 rw\n' > "$d/mounts"
files "$d/k" vmlinuz-6.10-rc1 vmlinuz-6.10 vmlinuz-6.9
gen "$d/k" --root PARTUUID=aa-02
if [ "$(grep '^image' "$d/conf" | head -1 | sed 's|.*/||')" = vmlinuz-6.10 ]; then
    echo "ok: a release sorts above its release candidate"
else bad "6.10-rc1 is the default"; fi

files "$d/k" vmlinuz-2 vmlinuz-1 bzImage-1
if gen "$d/k" --root PARTUUID=aa-02 && [ "$(grep -c '^image' "$d/conf")" = 3 ]; then
    echo "ok: two kernels of one version get different labels"
else bad "duplicate labels"; fi

files "$d/k" 'vmlinuz-1#custom' intel-ucode.img initramfs-1#custom.img
gen "$d/k" --root PARTUUID=aa-02
want "a '#' in a file name is quoted" "image  = \"$d/k/vmlinuz-1#custom\""
if [ "$(grep 'initrd' "$d/conf" | head -1 | grep -c ucode)" = 1 ]; then
    echo "ok: CPU microcode comes first"
else bad "microcode is not loaded"; fi

# An --append that can't be written back as given.
files "$d/k" vmlinuz-1
if gen "$d/k" --root PARTUUID=aa-02 --append 'x="a #b'; then bad "wrote an --append that reads back differently"
else echo "ok: an --append that can't be written is refused"; fi

# ---- replacing a configuration (INST-13) ------------------------------------
files "$d/k" vmlinuz-1
echo "precious" > "$d/out.conf"; chmod 600 "$d/out.conf"
gen "$d/k" --root x -o "$d/out.conf" && bad "overwrote without --force"
[ "$(cat "$d/out.conf")" = precious ] && echo "ok: refuses to overwrite" || bad "changed without --force"
(trap '' XFSZ; ulimit -f 0; "$dk" config --boot "$d/k" --mountinfo "$d/mounts" --no-windows --root x --force -o "$d/out.conf" >/dev/null 2>"$d/err")
[ "$(cat "$d/out.conf")" = precious ] && echo "ok: a failed rewrite keeps the old file" || bad "a failed rewrite destroyed the configuration"
gen "$d/k" --root x --force -o "$d/out.conf"
if grep -q vmlinuz-1 "$d/out.conf" && [ "$(stat -c %a "$d/out.conf")" = 600 ]; then
    echo "ok: --force replaces it and keeps its permissions"
else bad "--force: $(stat -c %a "$d/out.conf")"; fi
ln -s out.conf "$d/link.conf"
gen "$d/k" --root y --force -o "$d/link.conf"
if [ -L "$d/link.conf" ] && grep -q 'root   = y' "$d/out.conf"; then echo "ok: writes through a symlink"
else bad "a symlinked configuration was replaced by a file"; fi

[ $failures -eq 0 ] || { echo "FAIL: $failures config case(s)"; exit 1; }
echo "PASS: config writes correct paths and entries"
