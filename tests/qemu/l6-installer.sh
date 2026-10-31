#!/bin/sh
# L6: the installer. `dklilo install-bios` makes MBR and GPT disks bootable,
# refuses to overwrite foreign data in the post-MBR gap, `check` validates a
# configuration with the loader's own filesystem code, and `install-uefi`
# produces a bootable ESP.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
dk="$root/zig-out/bin/dklilo"
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

cat > "$d/dklilo.conf" <<'C'
timeout = 1
default = test
image  = /boot/vmlinuz
    label  = test
    append = "console=ttyS0 quiet dkl=installed"
    initrd = /boot/initrd1.img
    initrd = /boot/initrd2.cpio
C
boots() { # disk-image serial-file
    timeout 90 qemu-system-x86_64 -m 1024 -display none -no-reboot \
        -drive format=raw,file="$1" -serial "file:$2" >/dev/null 2>&1 || true
    grep -qaF "dkl=installed" "$2" && grep -qaF "DKLILO-DONE" "$2"
}

# ---- BIOS, MBR and GPT ------------------------------------------------------
for kind in mbr gpt; do
    rc=0; NO_BOOTLOADER=1 "$here/make-bios-disk.sh" "$d/$kind.img" "$d/dklilo.conf" "$kind" || rc=$?
    [ $rc -eq 77 ] && exit 77
    [ $rc -eq 0 ] || exit $rc
    timeout 20 qemu-system-x86_64 -m 64 -display none -no-reboot -drive format=raw,file="$d/$kind.img" \
        -serial "file:$d/pre.txt" >/dev/null 2>&1 || true
    grep -qaF "DKLILO-DONE" "$d/pre.txt" 2>/dev/null && fail "$kind disk booted before installing"
    "$dk" install-bios "$d/$kind.img" --yes > "$d/install.log" || { cat "$d/install.log"; fail "install-bios ($kind)"; }
    boots "$d/$kind.img" "$d/$kind.txt" || fail "$kind disk did not boot after install-bios"
    echo "PASS: install-bios makes a $kind disk bootable"
    # Reinstalling over our own stage 2 is fine.
    "$dk" install-bios "$d/$kind.img" --yes >/dev/null || fail "reinstall over dklilo ($kind)"
done

# ---- refusal: foreign data in the gap ---------------------------------------
NO_BOOTLOADER=1 "$here/make-bios-disk.sh" "$d/foreign.img" "$d/dklilo.conf" mbr
printf 'GRUB core image data, not ours' | dd of="$d/foreign.img" bs=512 seek=1 conv=notrunc 2>/dev/null
before=$(sha256sum "$d/foreign.img" | cut -d' ' -f1)
if "$dk" install-bios "$d/foreign.img" --yes > "$d/refuse.log" 2>&1; then fail "installer overwrote foreign data"; fi
after=$(sha256sum "$d/foreign.img" | cut -d' ' -f1)
[ "$before" = "$after" ] || fail "the disk changed although the installer refused"
grep -q "Refusing" "$d/refuse.log" || fail "no explanation printed"
echo "PASS: install-bios refuses to overwrite foreign data and leaves the disk untouched"

# Without --yes and without typing 'yes', nothing is written.
NO_BOOTLOADER=1 "$here/make-bios-disk.sh" "$d/noyes.img" "$d/dklilo.conf" mbr
before=$(sha256sum "$d/noyes.img" | cut -d' ' -f1)
echo no | "$dk" install-bios "$d/noyes.img" > /dev/null 2>&1 && fail "installed without confirmation"
[ "$before" = "$(sha256sum "$d/noyes.img" | cut -d' ' -f1)" ] || fail "disk changed without confirmation"
echo "PASS: no confirmation, no write"

# ---- check ------------------------------------------------------------------
"$dk" check --device "$d/mbr.img" > "$d/check.log" 2>&1 || { cat "$d/check.log"; fail "check on a good config"; }
grep -q "all files found" "$d/check.log" || fail "check did not report success"
cat > "$d/bad.conf" <<'C'
timeout = 1
image  = /boot/vmlinuz
    label  = ok
    initrd = /boot/initrd1.img
image  = /boot/vmlinuz-missing
    label  = broken
    initrd = /boot/initrd-missing.img
C
NO_BOOTLOADER=1 "$here/make-bios-disk.sh" "$d/bad.img" "$d/bad.conf" mbr
if "$dk" check --device "$d/bad.img" > "$d/badcheck.log" 2>&1; then fail "check accepted a config with missing files"; fi
grep -q "vmlinuz-missing" "$d/badcheck.log" && grep -q "initrd-missing" "$d/badcheck.log" || fail "check did not name the missing files"
echo "PASS: check validates files with the loader's own filesystem code"

# ---- UEFI -------------------------------------------------------------------
rc=0; NO_LOADER=1 "$here/make-linux-disk.sh" "$d/uefi.img" "$d/dklilo.conf" || rc=$?
[ $rc -eq 0 ] || exit $rc
mkdir -p "$d/esp"
"$dk" install-uefi "$d/esp" --removable --yes >/dev/null || fail "install-uefi --removable"
[ -f "$d/esp/EFI/BOOT/BOOTX64.EFI" ] || fail "no BOOTX64.EFI written"
# Copy the installed tree into the ESP partition of the disk image.
off=$((2048 * 512))
mcopy -s -i "$d/uefi.img@@$off" "$d/esp/EFI" ::/ 2>/dev/null || fail "could not copy into the ESP"
"$here/qemu-uefi.sh" "$d/uefi.img" "$d/uefi.txt" 90
grep -qaF "dkl=installed" "$d/uefi.txt" && grep -qaF "DKLILO-DONE" "$d/uefi.txt" || fail "UEFI disk did not boot after install-uefi"
echo "PASS: install-uefi --removable makes a bootable ESP"

# The boot entry payload: an EFI_LOAD_OPTION for partition 1 of the disk.
cp "$d/uefi.img" "$d/vdisk"
mkdir -p "$d/esp2"
"$dk" install-uefi "$d/esp2" --device "$d/vdisk1" --entry-file "$d/entry.bin" --yes >/dev/null || fail "install-uefi --entry-file"
[ -f "$d/esp2/EFI/dklilo/dkliloX64.efi" ] || fail "loader not copied"
python3 - "$d/entry.bin" <<'PY' || fail "EFI_LOAD_OPTION malformed"
import struct, sys
b = open(sys.argv[1], 'rb').read()
attrs, plen = struct.unpack_from('<IH', b, 0)
assert attrs == 1
desc_end = b.index(b'\0\0', 6) + 2
if (desc_end - 6) % 2: desc_end += 1
assert b[6:desc_end].decode('utf-16-le').rstrip('\0') == 'dklilo'
path = b[desc_end:]
assert len(path) == plen, (len(path), plen)
assert path[0] == 4 and path[1] == 1                       # hard drive node
num, start, size = struct.unpack_from('<IQQ', path, 4)
assert num == 1 and start == 2048, (num, start)
assert path[41] == 2                                       # GPT signature
assert path[42] == 4 and path[43] == 4                     # file path node
assert path[-4:] == bytes([0x7f, 0xff, 4, 0])
PY
echo "PASS: install-uefi builds a correct EFI_LOAD_OPTION"
