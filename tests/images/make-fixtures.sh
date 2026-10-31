#!/bin/sh
# Builds the test disk images with the real mkfs/partitioning tools, and a
# manifest ("sha256  size  path") of the files each filesystem was populated
# from, so the Zig tests can compare what dklilo reads against the originals.
# Needs no root: mke2fs -d populates an image from a directory.
# Usage: make-fixtures.sh <output dir>
set -eu
out="$1"
mkdir -p "$out"
w=$(mktemp -d); trap 'rm -rf "$w"' EXIT

# --- the tree every filesystem image is populated from ----------------------
t="$w/tree"
mkdir -p "$t/boot/sub/deeper" "$t/many"
printf 'hello\n' > "$t/boot/hello.txt"
: > "$t/boot/empty"
printf 'x' > "$t/boot/one-byte"
head -c 4096 /dev/urandom > "$t/boot/exactly-4k"
head -c 4097 /dev/urandom > "$t/boot/4k-plus-1"
head -c 1023 /dev/urandom > "$t/boot/under-1k"
head -c 5000000 /dev/urandom > "$t/boot/big.bin"
head -c 300000 /dev/urandom > "$t/boot/medium.bin"
printf 'nested\n' > "$t/boot/sub/deeper/file"
long=$(printf 'n%.0s' $(seq 1 255))
printf 'long\n' > "$t/boot/sub/$long"
ln -s hello.txt "$t/boot/link-fast"
ln -s sub/deeper/file "$t/boot/link-dir"
ln -s "/boot/sub/deeper/file" "$t/boot/link-abs"
slow=$(printf 's%.0s' $(seq 1 100))
ln -s "$slow" "$t/boot/link-slow-dangling"
# A sparse file: data, a hole, then more data.
dd if=/dev/urandom of="$t/boot/sparse" bs=4096 count=2 2>/dev/null
dd if=/dev/urandom of="$t/boot/sparse" bs=4096 seek=300 count=2 conv=notrunc 2>/dev/null
# A directory big enough to get an htree on ext4.
i=0; while [ $i -lt 3000 ]; do : > "$t/many/file-with-a-longish-name-$i"; i=$((i+1)); done
printf 'tiny\n' > "$t/many/file-with-a-longish-name-7"

( cd "$t" && find . -type f | sort | while read -r f; do
    p=${f#.}
    printf '%s  %s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$(wc -c < "$f")" "$p"
  done ) > "$out/manifest.txt"

# --- filesystem images ------------------------------------------------------
mk() { # name mkfs-command... (image path is $out/<name>.img)
    n="$1"; shift
    truncate -s 16M "$out/$n.img"
    "$@" -d "$t" "$out/$n.img" >/dev/null 2>&1
}
mk ext4       mkfs.ext4 -F -q -b 4096 -L dkltest
# mke2fs -d writes linear directories; -D makes e2fsck rebuild them as htrees.
e2fsck -fyD "$out/ext4.img" >/dev/null 2>&1 || true
mk ext4-1k    mkfs.ext4 -F -q -b 1024
mk ext4-64bit mkfs.ext4 -F -q -b 4096 -O 64bit
mk ext2       mkfs.ext2 -F -q -b 1024
mk ext3       mkfs.ext3 -F -q -b 4096
# Inline data: only the small files fit, but the directories do too.
mk ext4-inline mkfs.ext4 -F -q -b 4096 -O inline_data

# --- partition tables -------------------------------------------------------
truncate -s 64M "$out/mbr.img"
sfdisk -q "$out/mbr.img" >/dev/null <<S
label: dos
label-id: 0x4a6f8c21
start=2048, size=8192, type=83, bootable
start=10240, size=8192, type=7
start=18432, size=4096, type=c
start=22528, type=5
start=24576, size=4096, type=83
start=30720, size=8192, type=83
S
truncate -s 64M "$out/gpt.img"
sfdisk -q "$out/gpt.img" >/dev/null <<S
label: gpt
label-id: 6a1e7c3e-9a01-4f6c-8b5d-0c2c0fd0a001
start=2048, size=8192, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=11111111-2222-3333-4444-555555555555, name="root"
start=10240, size=8192, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee, name="esp"
S
