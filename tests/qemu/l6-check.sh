#!/bin/sh
# L6: what `dklilo check` must report (docs/bugs CMN-03). Works only on image
# files; needs no QEMU and no kernel. Every case runs.
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
dk="$root/zig-out/bin/dklilo"
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
failures=0
bad() { echo "FAIL: $*"; sed 's/^/    /' "$d/out.txt" | tail -8; failures=$((failures + 1)); }

mkdir -p "$d/files/boot"
python3 -I "$here/fake-bzimage.py" "$d/files/boot/vmlinuz"

# image <name>: an ext4 image with the files above and the config from stdin
image() {
    rm -rf "$d/root" "$d/$1.img"; cp -r "$d/files" "$d/root"
    cat > "$d/root/boot/dklilo.conf"
    truncate -s 16M "$d/$1.img"
    mkfs.ext4 -F -q -d "$d/root" "$d/$1.img"
}
# run <image>: check it; the exit status is left in $status
run() { "$dk" check --device "$d/$1.img" > "$d/out.txt" 2>&1; status=$?; }
# expect <description> <image> <pass|fail> [text the output must contain]
expect() {
    what="$1"; run "$2"
    case "$3" in
        pass) [ $status -eq 0 ] || { bad "$what: exit $status"; return; } ;;
        # An error report, not a crash.
        fail) [ $status -eq 1 ] || { bad "$what: exit $status, wanted 1"; return; } ;;
    esac
    if [ -n "${4:-}" ] && ! grep -qi -- "$4" "$d/out.txt"; then bad "$what: no mention of '$4'"; return; fi
    echo "ok: $what"
}

hash=$(printf %s secret | sha256sum | cut -d' ' -f1)

image good <<C
password = $hash
image = /boot/vmlinuz
    label = linux
    restricted
C
expect "a good configuration passes" good pass "all files found"
grep -qi "warn" "$d/out.txt" && bad "a good configuration draws a warning"

# ---- passwords that don't protect what they seem to (CMN-03) ----------------
image nothex <<C
password = zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz
image = /boot/vmlinuz
    label = linux
    restricted
C
expect "a password no one can type is an error" nothex fail "password"

image nopassword <<'C'
image = /boot/vmlinuz
    label = linux
    restricted
C
expect "restricted without a password is warned about" nopassword pass "restricted.*protects nothing"

image norestricted <<C
password = $hash
image = /boot/vmlinuz
    label = linux
C
expect "a password without restricted is warned about" norestricted pass "no entry is 'restricted'"

# ---- accepted, but probably not meant (CMN-09, CMN-10) ----------------------
image repeated <<'C'
timeout = 10
timeout = 20
image = /boot/vmlinuz
    label = linux
C
expect "a repeated key is warned about" repeated pass "line 2: 'timeout'"

{ printf 'image = /boot/vmlinuz\n    label = linux\n    append = "'; printf 'x%.0s' $(seq 1100); printf '"\n'; } | image long
expect "a command line too long for the loader is an error" long fail "command line"

# ---- configurations and disks that must not trip check (INST-05) -----------
image empty <<'C'
# nothing here yet
C
expect "an empty configuration is accepted" empty pass "no entries"

# A whole-disk FAT filesystem, as on a USB stick.
rm -f "$d/fat.img"; mkfs.fat -F 16 -C "$d/fat.img" 32768 >/dev/null
mmd -i "$d/fat.img" ::/boot
mcopy -i "$d/fat.img" "$d/files/boot/vmlinuz" ::/boot/vmlinuz
printf 'image = /boot/vmlinuz\n' > "$d/fat.conf"
mcopy -i "$d/fat.img" "$d/fat.conf" ::/boot/dklilo.conf
expect "a FAT filesystem on a whole disk" fat pass "all files found"

# ---- files that can't boot (INST-15) ----------------------------------------
: > "$d/files/boot/zero"
printf 'plain text' > "$d/files/boot/text"
image zerokernel <<'C'
image = /boot/zero
    label = z
C
expect "an empty kernel file is an error" zerokernel fail "empty"
image textkernel <<'C'
image = /boot/text
    label = t
    initrd = /boot/zero
C
expect "a kernel that isn't one is warned about" textkernel pass "does not look like a kernel"
grep -qi "initrd.*empty" "$d/out.txt" || bad "an empty initramfs is not mentioned"

# ---- a configuration on a mounted system, without --device ------------------
# As an installer runs it. The mount table is made up: its "device" is an image
# of the filesystem that is mounted on $d/mnt.
mkdir -p "$d/mnt/boot"
printf 'image = /boot/vmlinuz\n    root = /dev/sda1\n' > "$d/mnt/boot/dklilo.conf"
cp "$d/files/boot/vmlinuz" "$d/mnt/boot/"
rm -f "$d/mounted.img"; truncate -s 16M "$d/mounted.img"
mkfs.ext4 -F -q -d "$d/mnt" "$d/mounted.img"
printf '30 1 8:1 / %s rw - ext4 /dev/..%s rw\n' "$(realpath "$d/mnt")" "$(realpath "$d/mounted.img")" > "$d/mounts"
if "$dk" check "$d/mnt/boot/dklilo.conf" --mountinfo "$d/mounts" > "$d/out.txt" 2>&1 && grep -q "all files found" "$d/out.txt"; then
    echo "ok: checks a configuration on a mounted system"
else bad "without --device: $?"; fi
# A reference to a volume makes it look at the other disks too.
printf 'image = LABEL=no-such-label:/vmlinuz\n' > "$d/mnt/boot/dklilo.conf"
"$dk" check "$d/mnt/boot/dklilo.conf" --mountinfo "$d/mounts" > "$d/out.txt" 2>&1; status=$?
if [ $status -eq 1 ] && grep -q "NoSuchVolume" "$d/out.txt"; then echo "ok: a missing volume is reported"
else bad "missing volume: exit $status"; fi

# ---- chainload entries (BIOS-05, INST-15) -----------------------------------
# The BIOS loader can start only partitions of the disk it booted from.
mkdir -p "$d/chain/boot"; printf 'other = 2\n' > "$d/chain/boot/dklilo.conf"
truncate -s 16M "$d/chainfs.img"; mkfs.ext4 -F -q -d "$d/chain" "$d/chainfs.img"
disk_with() { # image config: a disk with one partition, holding that config
    printf '%s\n' "$2" > "$d/chain/boot/dklilo.conf"
    rm -f "${d:?}/chainfs.img" "${d:?}/${1:?}.img"
    truncate -s 16M "$d/chainfs.img"; mkfs.ext4 -F -q -d "$d/chain" "$d/chainfs.img"
    truncate -s 24M "$d/$1.img"
    printf 'label: dos\nstart=2048, size=32768, type=83\n' | sfdisk -q "$d/$1.img"
    dd if="$d/chainfs.img" of="$d/$1.img" bs=512 seek=2048 conv=notrunc 2>/dev/null
}
disk_with missing 'other = 3'
expect "chainloading a partition that isn't there is an error" missing fail "no partition 3"
disk_with present 'other = 1'
expect "chainloading one that is there passes" present pass "all files found"
disk_with devname 'other = /dev/sdb1'
expect "a /dev name is warned about" devname pass "disk name .* is not checked"
disk_with nowindows 'other = windows'
expect "a Windows entry with no Windows in sight is warned about" nowindows pass "no Windows"

# ---- a filesystem with a journal to replay (FS-11) --------------------------
image unclean <<'C'
image = /boot/vmlinuz
    label = linux
C
debugfs -w -R 'feature needs_recovery' "$d/unclean.img" >/dev/null 2>&1
expect "an unclean filesystem is warned about" unclean pass "not unmounted cleanly"

[ $failures -eq 0 ] || { echo "FAIL: $failures check case(s)"; exit 1; }
echo "PASS: check reports configuration problems"
