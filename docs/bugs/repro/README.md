# Reproductions

## Parser bugs (`poc.zig`)

Each test fails, panics, leaks or hangs on the audited code (commit `38d1030`, which the commands below extract). On the code with FS-01 to FS-07 fixed, `poc-extent-leaf-hole`, `poc-btrfs-cache`, `poc-fat-bpb-overflow`, `poc-ext4-descsize` and `poc-ext4-table-overflow` pass, and `poc-fat-cycle` and `poc-fat-cluster1` stop with `error.Corrupt`. Run them in a **copy** of the tree, not on real media. Needs `mkfs.ext4`, `mkfs.btrfs`, `mkfs.fat`, `mtools`.

```sh
repo=$PWD; w=$(mktemp -d); git archive 38d1030 src deps | tar -x -C "$w"
cp docs/bugs/repro/poc.zig "$w/src/common/"; mkdir "$w/img"; cd "$w/img"
python3 -c "
with open('sparse.bin','wb') as f:
    for i in range(600): f.seek(i*3072); f.write(bytes([1+i%250])*1024)"
mkdir t1 t2 t3; cp --sparse=always sparse.bin t1/sparse
truncate -s 16M sparse.img; mkfs.ext4 -q -F -b 1024 -d t1 sparse.img
yes "BIGFILE the quick brown fox" | head -c 1000000 > t2/big.txt
yes "smallfile inline" | head -c 1500 > t2/small.txt
truncate -s 128M btrfs.img; mkfs.btrfs -q -f --rootdir t2 --compress zstd btrfs.img
mkfs.fat -F 16 -C super.img 32768; cp super.img fat16.img; mmd -i fat16.img ::/DIR
echo hi > t3/f; truncate -s 16M desc.img; mkfs.ext4 -q -F -b 4096 -O '64bit,^metadata_csum' -d t3 desc.img
printf 'pub const dir = "%s";\n' "$w/img" > "$w/poc_opts.zig"
cd "$w"
timeout 60 zig test --test-filter poc-btrfs-cache --dep fsread --dep poc_opts \
  -Mroot=src/common/poc.zig -Mfsread=deps/fsread/src/root.zig -Mpoc_opts=poc_opts.zig
```

Run one filter at a time, since a panic ends the run: `poc-extent-leaf-hole`, `poc-btrfs-cache`, `poc-fat-superfloppy`, `poc-fat-cycle` (hangs), `poc-fat-cluster1`, `poc-fat-bpb-overflow`, `poc-ext4-descsize`, `poc-ext4-table-overflow`, `poc-config-leak`, `poc-gpt-overflow`.

## BIOS keyboard (BIOS-01)

Install on a disk image whose config has `prompt` and `timeout = 80`. Boot in QEMU with `-serial file:LOG -monitor unix:SOCK,server,nowait`, and send `sendkey down` through the monitor once the menu appears. The countdown continues. To confirm the cause, move `pushfd` in `realmode.zig` to directly after the `cli` that follows `int_op`, rebuild and repeat: the countdown stops.

## BIOS read errors (BIOS-01)

Put a minimal bzImage on an ext4 test disk: five setup sectors with `setup_sects = 4`, `HdrS`, boot flag `0xAA55`, protocol `0x020F` and `LOADED_HIGH`, followed by about 400 KiB whose first bytes are `hlt` and a jump back to it. Use `timeout = 0`. Find a disk sector in the middle of the file with `debugfs -R 'bmap /boot/vmlinuz 50'` (disk sector = partition start + block * 8 for 4 KiB blocks). Boot with `-drive file=blkdebug:inject.conf:DISK,format=raw,rerror=report`, where `inject.conf` is:

```
[inject-error]
event = "read_aio"
errno = "5"
sector = "N"
```

The shipped loader prints `Starting kernel...`. With `pushfd` moved it prints `read error: IoError`.

## BIOS retry trap (CMN-01)

One entry naming a missing kernel, `timeout = 50`, no `prompt`. Answer "Press a key" over serial repeatedly.

## UEFI initrd (UEFI-01)

Under OVMF: `prompt`, `image = /fake.efi` (`zig-out/bin/fake-bootmgfw.efi` from `zig build dev`) and any `initrd`. Boot it, press a key, boot it again.

## Installer (INST-*)

Use image files and temporary directories only. Commands are in each entry. `config` cases use `--mountinfo FILE` with made-up mount lines.
