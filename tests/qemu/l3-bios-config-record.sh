#!/bin/sh
# L3: install-bios records which partition holds dklilo.conf, and the BIOS
# loader looks there first (docs/bugs BIOS-07, SPEC 5.3). Fake bzImages are
# used, so no Linux is needed. Which configuration was read shows in the name
# of its menu entry. Every case runs.
#
# Skips (77) without qemu-system-x86_64.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
dk="$root/zig-out/bin/dklilo"
command -v qemu-system-x86_64 >/dev/null || { echo "SKIP: no qemu-system-x86_64"; exit 77; }
d=$(mktemp -d); trap 'rm -rf "${d:?}"' EXIT
d=$(realpath "$d")
failures=0
bad() { echo "FAIL: $*"; failures=$((failures + 1)); }

# part <name> <entry label, or - for no config>: a filesystem image
part() {
    rm -rf "${d:?}/root"; mkdir -p "$d/root/boot"
    python3 -I "$here/fake-bzimage.py" "$d/root/boot/vmlinuz"
    if [ "$2" != - ]; then
        printf 'prompt\nimage = /boot/vmlinuz\n    label = %s\n' "$2" > "$d/root/boot/dklilo.conf"
    fi
    rm -f "${d:?}/${1:?}.fs"; truncate -s 8M "$d/$1.fs"
    mkfs.ext4 -F -q -b 4096 -d "$d/root" "$d/$1.fs"
}
part one config-one
part two config-two
part bare -

# disk <image> <mbr|gpt> <filesystem 1> <filesystem 2>
disk() {
    img="$d/$1.img"
    rm -f "${img:?}"; truncate -s 24M "$img"
    if [ "$2" = mbr ]; then
        printf 'label: dos\nlabel-id: 0x11223344\nstart=2048, size=16384, type=83\nstart=18432, size=16384, type=83\n' |
            sfdisk -q "$img"
    else
        printf 'label: gpt\nfirst-lba: 34\nstart=34, size=2000, type=21686148-6449-6E6F-744E-656564454649\nstart=2048, size=16384, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4\nstart=18432, size=16384, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4\n' |
            sfdisk -q "$img"
    fi
    put "$1" 2048 "$3"
    put "$1" 18432 "$4"
}
put() { dd if="$d/$3.fs" of="$d/$1.img" bs=512 seek="$2" conv=notrunc 2>/dev/null; }
install() { # image [options...]
    img="$1"; shift
    "$dk" install-bios "$d/$img.img" --yes "$@" > "$d/out.txt" 2>&1
}
# boots <description> <image> <text>...: what the loader shows, in order
boots() {
    what="$1"; img="$2"; shift 2
    n=$#
    while [ $n -gt 0 ]; do a="$1"; shift; set -- "$@" "wait:$a"; n=$((n - 1)); done
    rm -f "${d:?}/serial.txt" "${d:?}/monitor"
    if python3 -I "$here/bios-drive.py" "$d/serial.txt" "$d/monitor" "$@" -- \
        qemu-system-x86_64 -m 256 -drive format=raw,file="$d/$img.img" > "$d/drive.txt"; then
        echo "ok: $what"
    else
        bad "$what: $(cat "$d/drive.txt")"
        sed 's/\x1b\[[0-9;]*[A-Za-z]/ /g' "$d/serial.txt" | tail -c 300; echo
    fi
}

for kind in mbr gpt; do
    if [ $kind = mbr ]; then first=1; second=2; else first=2; second=3; fi

    # Two configurations: the one asked for wins over the first on the disk.
    disk $kind $kind one two
    if install $kind --config-partition $second; then
        boots "$kind: the recorded partition's configuration is used" $kind config-two
    else bad "$kind: --config-partition: $(tail -2 "$d/out.txt")"; fi

    # The only configuration is found and recorded by itself; one added to an
    # earlier partition afterwards doesn't take over.
    disk $kind $kind bare two
    install $kind || bad "$kind: install: $(tail -2 "$d/out.txt")"
    put $kind 2048 one
    boots "$kind: the only configuration is recorded without being asked" $kind config-two
done

# The record no longer leads to a configuration: search, and say so.
disk gone mbr one two
install gone --config-partition 2 || bad "install: $(tail -2 "$d/out.txt")"
put gone 18432 bare
boots "a record that leads nowhere falls back to searching" gone \
    "no configuration on the partition recorded" config-one

# Two configurations and nothing to choose by: none is recorded, and it says so.
disk both mbr one two
install both || bad "install: $(tail -2 "$d/out.txt")"
if grep -q -- "--config-partition" "$d/out.txt"; then echo "ok: says how to choose between two"
else bad "no word about choosing: $(cat "$d/out.txt")"; fi
boots "without a record the first configuration is used, as before" both config-one

# An installer's target is mounted somewhere: of two, that one is meant.
disk target mbr one two
mkdir -p "$d/target/boot"
printf 'prompt\n' > "$d/target/boot/dklilo.conf"
printf '30 1 8:1 / / rw - overlay overlay rw\n31 30 8:2 / %s rw - ext4 /dev/..%s2 rw\n' \
    "$d/target" "$d/target.img" > "$d/mounts"
if install target --mountinfo "$d/mounts"; then
    boots "the mounted system's partition is recorded" target config-two
else bad "mounted target: $(tail -2 "$d/out.txt")"; fi
# A reinstall with nothing mounted keeps what was recorded.
if install target; then
    boots "a reinstall keeps the recorded partition" target config-two
else bad "reinstall: $(tail -2 "$d/out.txt")"; fi
if install target --config-partition none; then
    boots "--config-partition none records nothing" target config-one
else bad "--config-partition none: $(tail -2 "$d/out.txt")"; fi

before=$(sha256sum "$d/target.img" | cut -d' ' -f1)
if install target --config-partition 7; then bad "recorded a partition that isn't there"
elif [ "$(sha256sum "$d/target.img" | cut -d' ' -f1)" != "$before" ]; then bad "refused, but changed the disk"
else echo "ok: refuses a partition that isn't there"; fi

[ $failures -eq 0 ] || { echo "FAIL: $failures config record case(s)"; exit 1; }
echo "PASS: the BIOS loader reads the configuration from the recorded partition"
