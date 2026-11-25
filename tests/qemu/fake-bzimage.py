#!/usr/bin/env python3
"""Writes a minimal bzImage: enough of the x86 boot protocol header for the
BIOS loader to accept it, then a "kernel" that only halts. The padding makes it
large enough to have sectors well past the header, so a test can damage one.

Header offsets: Documentation/arch/x86/boot.rst in the Linux source.

Usage: fake-bzimage.py <out> [--size-mib N] [--init-size-mib N]

--size-mib sets the size of the protected-mode kernel (default: 400 KiB);
--init-size-mib the memory it says it needs to unpack itself (default: 0).
"""
import argparse
import struct

args = argparse.ArgumentParser()
args.add_argument("out")
args.add_argument("--size-mib", type=int)
args.add_argument("--init-size-mib", type=int, default=0)
args = args.parse_args()

setup = bytearray(5 * 512)  # boot sector + setup_sects
setup[0x1F1] = 4  # setup_sects
struct.pack_into("<H", setup, 0x1FE, 0xAA55)  # boot_flag
setup[0x202:0x206] = b"HdrS"
struct.pack_into("<H", setup, 0x206, 0x020F)  # protocol version
setup[0x211] = 1  # loadflags: LOADED_HIGH
struct.pack_into("<I", setup, 0x214, 0x100000)  # code32_start
struct.pack_into("<I", setup, 0x22C, 0x7FFFFFFF)  # initrd_addr_max
struct.pack_into("<I", setup, 0x230, 0x1000)  # kernel_alignment
struct.pack_into("<I", setup, 0x238, 2047)  # cmdline_size
struct.pack_into("<I", setup, 0x260, args.init_size_mib << 20)  # init_size

size = args.size_mib << 20 if args.size_mib else 400 * 1024
code = b"\xF4\xEB\xFD" + b"K" * (size - 3)  # hlt; jmp back

with open(args.out, "wb") as f:
    f.write(bytes(setup) + code)
