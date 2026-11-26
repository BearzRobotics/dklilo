#!/bin/sh
# L3: the BIOS loader against unusual configurations, disks and firmware
# (docs/bugs BIOS-05, 06, 08, 10, 11). Fake bzImages are used, so no Linux is
# needed. Every case runs.
#
# Skips (77) without qemu-system-x86_64 and the GNU assembler and linker.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
dk="$root/zig-out/bin/dklilo"
command -v qemu-system-x86_64 >/dev/null || { echo "SKIP: no qemu-system-x86_64"; exit 77; }
{ command -v as && command -v ld; } >/dev/null || { echo "SKIP: no GNU as and ld"; exit 77; }
d=$(mktemp -d); trap 'rm -rf "${d:?}"' EXIT
failures=0

# quirk <name> <symbol>: an option ROM that adds that BIOS behaviour
quirk() {
    as --32 --defsym "$2=1" "$here/bios-quirks.s" -o "$d/$1.o"
    ld -m elf_i386 -Ttext 0 --oformat binary "$d/$1.o" -o "$d/$1.bin"
    python3 -I -c '
import sys
b = bytearray(open(sys.argv[1], "rb").read())
assert len(b) < 512
b += bytes(512 - len(b))
b[-1] = -sum(b) & 0xFF
open(sys.argv[2], "wb").write(b)' "$d/$1.bin" "$d/$1.rom"
}
quirk df SET_DF
quirk noe820 NO_E820
quirk lowmem LITTLE_RAM

# disk <name> <configuration> [fake-bzimage options...]: a BIOS disk with the
# files in $d/files and a second partition holding $d/second.bin
disk() {
    name="$1"; conf="$2"; shift 2
    rm -rf "${d:?}/root"; mkdir -p "$d/root/boot"
    cp "$d/files/"* "$d/root/boot/"
    python3 -I "$here/fake-bzimage.py" "$d/root/boot/vmlinuz" "$@"
    printf '%s\n' "$conf" > "$d/root/boot/dklilo.conf"
    rm -f "${d:?}/fs.img" "${d:?}/${name:?}.img"
    truncate -s 16M "$d/fs.img"
    mkfs.ext4 -F -q -b 4096 -d "$d/root" "$d/fs.img"
    truncate -s 28M "$d/$name.img"
    printf 'label: dos\nstart=2048, size=32768, type=83\nstart=34816, size=4096, type=7\n' | sfdisk -q "$d/$name.img"
    dd if="$d/fs.img" of="$d/$name.img" bs=512 seek=2048 conv=notrunc 2>/dev/null
    if [ -f "$d/second.bin" ]; then
        dd if="$d/second.bin" of="$d/$name.img" bs=512 seek=34816 conv=notrunc 2>/dev/null
    fi
    "$dk" install-bios "$d/$name.img" --yes >/dev/null
}
# run <description> <drive> <option ROM or -> <step>...
run() {
    what="$1"; drive="$2"; rom="$3"; shift 3
    case "$drive" in
        *=*) ;;
        *) drive="format=raw,file=$d/$drive.img" ;;
    esac
    extra=""
    [ "$rom" = - ] || extra="-option-rom $d/$rom.rom"
    rm -f "${d:?}/serial.txt" "${d:?}/monitor"
    # $extra is two words or none; the paths under $d have no spaces.
    if python3 -I "$here/bios-drive.py" "$d/serial.txt" "$d/monitor" "$@" -- \
        qemu-system-x86_64 -m 256 -drive "$drive" $extra > "$d/drive.txt"; then
        echo "ok: $what"
    else
        echo "FAIL: $what: $(cat "$d/drive.txt")"
        sed 's/\x1b\[[0-9;]*[A-Za-z]/ /g' "$d/serial.txt" 2>/dev/null | tail -c 300; echo
        failures=$((failures + 1))
    fi
}

# ---- initramfs files (BIOS-08, BIOS-11) -------------------------------------
mkdir -p "$d/files"
for i in 1 2 3 4 5 6 7 8 9; do head -c $((i * 3000 + i)) /dev/urandom > "$d/files/part$i"; done
: > "$d/files/nothing"
sum() { (cd "$d/files" && python3 -I "$here/fake-bzimage.py" --sum "$@"); }
nine=$(sum part1 part2 part3 part4 part5 part6 part7 part8 part9)
two=$(sum part1 part2)

conf='timeout = 0
image = /boot/vmlinuz
    label = k'
for i in 1 2 3 4 5 6 7 8 9; do
    conf="$conf
    initrd = /boot/part$i"
done
disk nine "$conf"
run "nine initramfs files, joined in order" nine - "wait:$nine"
disk none 'timeout = 0
image = /boot/vmlinuz
    initrd = /boot/nothing'
run "an empty initramfs" none - "wait:initrd=00000000 sum=00000000 end"

# ---- firmware behaviour (BIOS-10, BIOS-11) ----------------------------------
disk two 'timeout = 0
image = /boot/vmlinuz
    initrd = /boot/part1
    initrd = /boot/part2'
run "an ordinary boot hands the kernel a memory map" two - "wait:fake-kernel e820=0000000" "wait:$two"
run "a BIOS that leaves the direction flag set" two df "wait:quirk installed" "wait:$two"
run "without E820 the kernel is still booted" two noe820 "wait:quirk installed" "wait:$two"
if grep -aq "e820=00000000" "$d/serial.txt"; then
    echo "FAIL: ... but with an empty memory map"; failures=$((failures + 1))
fi
run "too little conventional memory is reported" two lowmem "wait:quirk installed" "wait:not enough low memory"

# ---- chainloading (BIOS-05, BIOS-06) ----------------------------------------
python3 -I "$here/fake-ntfs-vbr.py" "$d/second.bin"
disk chain 'prompt
other = 2
    label = two'
run "chainloads a partition by number" chain - "wait:dklilo boot menu" key:ret "wait:FAKE-NTFS-BOOT-OK"
disk named 'prompt
other = /dev/sdb2
    label = two'
run "says which disk a /dev name is taken on" named - "wait:dklilo boot menu" key:ret \
    "wait:partition 2 of the boot disk" "wait:FAKE-NTFS-BOOT-OK"
disk odd 'prompt
other = /EFI/tools/backup2
    label = two'
run "a target that names no partition isn't guessed at" odd - "wait:dklilo boot menu" key:ret \
    "wait:No boot partition found"
rm -f "${d:?}/second.bin"
disk blank 'prompt
other = 2
    label = two'
run "a partition without a boot sector isn't started" blank - "wait:dklilo boot menu" key:ret \
    "wait:not a boot sector"

# ---- command line (BIOS-11) -------------------------------------------------
disk long "timeout = 0
image = /boot/vmlinuz
    append = \"$(printf 'a%.0s' $(seq 200))\"" --cmdline-size 100
run "a command line the kernel can't hold is reported" long - "wait:command line cut to 99" "wait:fake-kernel"

# ---- stage 1 (BIOS-11) ------------------------------------------------------
cp "$d/two.img" "$d/stale.img"
dd if=/dev/urandom of="$d/stale.img" bs=512 seek=1 count=4 conv=notrunc 2>/dev/null
run "stage 1 doesn't run what isn't stage 2" stale - "screen:dklilo: cannot load stage 2"
if grep -aq "dklilo stage2" "$d/serial.txt"; then echo "FAIL: ran a damaged stage 2"; failures=$((failures + 1)); fi
printf '[inject-error]\nevent = "read_aio"\nerrno = "5"\nsector = "1"\nonce = "on"\n' > "$d/once.conf"
run "stage 1 retries a failed read" "format=raw,rerror=report,file=blkdebug:$d/once.conf:$d/two.img" - "wait:$two"

[ $failures -eq 0 ] || { echo "FAIL: $failures hardening case(s)"; exit 1; }
echo "PASS: the BIOS loader copes with unusual configurations, disks and firmware"
