#!/bin/sh
# L6: what the installer must refuse, and what it must still accept
# (docs/bugs INST-01, INST-02, INST-08). Works only on image files and
# temporary directories; needs no QEMU and no kernel. Every case runs, and a
# refusal also has to leave the target byte for byte as it was.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
dk="$root/zig-out/bin/dklilo"
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
failures=0
bad() { echo "FAIL: $*"; failures=$((failures + 1)); }

sum() { sha256sum "$1" | cut -d' ' -f1; }
# put <image> <byte offset> <printf format>
put() { printf "$3" | dd of="$1" bs=1 seek="$2" conv=notrunc 2>/dev/null; }
sector_text() { dd if="$1" bs=512 skip="$2" count=1 2>/dev/null | tr -d '\0'; }
sector_is_zero() { [ -z "$(sector_text "$1" "$2")" ]; }
new_disk() { # image: an MBR disk with one partition at 1 MiB
    rm -f "$1"; truncate -s 24M "$1"
    printf 'label: dos\nstart=2048, size=32768, type=83\n' | sfdisk -q "$1"
}
refuses() { # description image [install-bios options...]
    what="$1"; img="$2"; shift 2
    before=$(sum "$img")
    if "$dk" install-bios "$img" --yes "$@" > "$d/out.txt" 2>&1; then
        bad "$what: installed instead of refusing"
    elif [ "$(sum "$img")" != "$before" ]; then
        bad "$what: refused, but the image changed"
    else
        echo "ok: refuses $what"
    fi
}
accepts() { # description image [install-bios options...]
    what="$1"; img="$2"; shift 2
    if "$dk" install-bios "$img" --yes "$@" > "$d/out.txt" 2>&1; then
        echo "ok: accepts $what"
    else
        bad "$what: $(cat "$d/out.txt" | tail -3)"
    fi
}

# ---- not a partitioned disk (INST-01) ---------------------------------------
# A FAT filesystem with a large, still empty reserved area.
mkfs.fat -F 16 -R 600 -C "$d/fat.img" 32768 >/dev/null
refuses "a FAT filesystem" "$d/fat.img"

# Filesystem boot sectors, each also given a plausible partition entry, so that
# only recognising the filesystem can stop the install.
entry() { put "$1" 446 '\200\0\0\0\203\0\0\0\0\010\0\0\0\200\0\0'; put "$1" 510 '\125\252'; }
mkfs.fat -F 32 -R 600 -C "$d/fat32.img" 65536 >/dev/null
dd if=/dev/zero of="$d/fat32.img" bs=512 seek=1 count=599 conv=notrunc 2>/dev/null
entry "$d/fat32.img"
refuses "a FAT32 boot sector" "$d/fat32.img"
for fs in 'NTFS    ' 'EXFAT   '; do
    rm -f "$d/other.img"; truncate -s 24M "$d/other.img"
    put "$d/other.img" 0 '\353\122\220'; put "$d/other.img" 3 "$fs"; entry "$d/other.img"
    refuses "an ${fs%% *} boot sector" "$d/other.img"
done

new_disk "$d/disk.img"; put "$d/disk.img" 462 '\101'
refuses "a partition table with an impossible status byte" "$d/disk.img"
rm -f "$d/disk.img"; truncate -s 24M "$d/disk.img"; put "$d/disk.img" 510 '\125\252'
refuses "a disk with an empty partition table" "$d/disk.img"

new_disk "$d/disk.img"
accepts "an ordinary MBR disk" "$d/disk.img"
accepts "a reinstall over itself" "$d/disk.img"
# Sectors stage 2 occupies (from the block list it just wrote).
sectors=$(od -An -tu2 -j424 -N2 "$d/disk.img" | tr -d ' ')

# ---- an older stage 2 (INST-08) ---------------------------------------------
# older <image> <length>: as left by an earlier dklilo whose stage 2 took
# <length> sectors: its MBR block list says so, nothing follows it.
older() {
    new_disk "$1"; "$dk" install-bios "$1" --yes >/dev/null
    dd if=/dev/zero of="$1" bs=512 seek=$((1 + $2)) count=$((sectors - $2)) conv=notrunc 2>/dev/null
    put "$1" 424 "\\$(printf '%03o' $(($2 % 256)))\\$(printf '%03o' $(($2 / 256)))"
}
older "$d/disk.img" 10
accepts "an upgrade from a shorter stage 2" "$d/disk.img"

older "$d/disk.img" 10; put "$d/disk.img" $((100 * 512)) 'SOMEONE-ELSES-DATA'
refuses "foreign data after a shorter older stage 2" "$d/disk.img"

# A longer older stage 2: the install succeeds and leaves nothing of it behind,
# or a later, longer version would take the leftovers for foreign data.
older "$d/disk.img" "$sectors"
long=$((sectors + 40))
put "$d/disk.img" 424 "\\$(printf '%03o' $((long % 256)))\\$(printf '%03o' $((long / 256)))"
put "$d/disk.img" $(((long) * 512)) 'OLD-STAGE2-TAIL'
accepts "a downgrade from a longer stage 2" "$d/disk.img"
sector_is_zero "$d/disk.img" "$long" || bad "the longer stage 2's tail was left behind"

# The older length is unknown (something else rewrote the MBR code since).
older "$d/disk.img" 10
dd if=/dev/zero of="$d/disk.img" bs=1 count=440 conv=notrunc 2>/dev/null
put "$d/disk.img" 0 '\063\300\216\320'
refuses "an older stage 2 of unknown length" "$d/disk.img"
accepts "the same with --force" "$d/disk.img" --force

# --force is only about dklilo's own leftovers, never another loader.
new_disk "$d/disk.img"; put "$d/disk.img" 512 'GRUB core image data'
refuses "another loader's data even with --force" "$d/disk.img" --force

# ---- the removable-media loader (INST-02) -----------------------------------
loader="EFI/BOOT/BOOTX64.EFI"
usb() { "$dk" install-uefi "$d/esp" --arch x64 --removable --yes "$@" > "$d/out.txt" 2>&1; }
mkdir -p "$d/esp"
if usb; then echo "ok: installs onto an empty ESP"; else bad "empty ESP: $(cat "$d/out.txt")"; fi
cp "$d/esp/$loader" "$d/ours.efi"
if usb; then echo "ok: reinstalls over itself"; else bad "reinstall: $(cat "$d/out.txt")"; fi
# Another dklilo version: different bytes, still recognisably ours.
printf 'another build' >> "$d/esp/$loader"
if usb && cmp -s "$d/esp/$loader" "$d/ours.efi"; then echo "ok: replaces another dklilo version"
else bad "other dklilo version: $(cat "$d/out.txt")"; fi

printf "SOMEONE ELSE'S BOOT LOADER" > "$d/esp/$loader"; cp "$d/esp/$loader" "$d/foreign.efi"
if usb; then bad "replaced a foreign fallback loader"
elif ! cmp -s "$d/esp/$loader" "$d/foreign.efi"; then bad "refused, but changed the foreign loader"
else echo "ok: refuses to replace a foreign fallback loader"; fi
if usb --force && cmp -s "$d/esp/$loader" "$d/ours.efi"; then echo "ok: --force replaces it"
else bad "--force did not replace the loader: $(cat "$d/out.txt")"; fi

[ $failures -eq 0 ] || { echo "FAIL: $failures installer safety case(s)"; exit 1; }
echo "PASS: the installer refuses unsafe targets and accepts safe ones"
