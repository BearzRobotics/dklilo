#!/usr/bin/env python3
"""Writes a minimal bzImage: enough of the x86 boot protocol header for the
BIOS loader to accept it, then a "kernel" that reports on COM1 what it was
given and halts:

    fake-kernel e820=NNNNNNNN initrd=SSSSSSSS sum=CCCCCCCC end

(hexadecimal: the number of memory map entries, the initramfs length, and a
checksum of its bytes; see initrd_sum below). The padding makes the image large
enough to have sectors well past the header, so a test can damage one.

Header offsets: Documentation/arch/x86/boot.rst in the Linux source.

Usage: fake-bzimage.py <out> [--size-mib N] [--init-size-mib N] [--pref-mib N]
                       [--cmdline-size N]
       fake-bzimage.py --sum <initramfs file>...

--size-mib sets the size of the protected-mode kernel (default: 400 KiB);
--init-size-mib the memory it says it needs to unpack itself (default: 0);
--pref-mib the address it prefers to run at (default: 0);
--cmdline-size the longest command line it accepts (default: 2047).
--sum prints what the kernel should report when it is given those files.
"""
import argparse
import struct
import sys

# The kernel's code, assembled for 0x100000 with GNU as from this source (32-bit
# protected mode, esi = boot_params): set a stack; print "fake-kernel e820=",
# boot_params[0x1E8]; " initrd=", ramdisk_size [0x21C]; " sum=" over the bytes
# at ramdisk_image [0x218], each step rotating the sum left by one bit and
# adding the byte; " end"; then halt.
CODE = bytes.fromhex(
    "bc0000080089f78d359a001000e85d0000000fb687e8010000e85f0000008d35"
    "ac001000e8460000008b871c020000e8490000008d35b5001000e8300000008b"
    "8f1c0200008b9f1802000031c085c9740bd1c00fb61301d04349ebf1e81c0000"
    "008d35bb001000e803000000f4ebfdfcac84c0740766baf803eeebf4c3b90800"
    "0000c1c00450240f04303c397602042766baf803ee584975e9c366616b652d6b"
    "65726e656c20653832303d0020696e697472643d002073756d3d0020656e640d"
    "0a00"
)


def initrd_sum(paths):
    """The length and checksum of these files as a loader concatenates them."""
    data = b""
    for path in paths:
        with open(path, "rb") as f:
            part = f.read()
        data += part + bytes(-len(part) % 4)
    total = 0
    for byte in data:
        total = (((total << 1) | (total >> 31)) + byte) & 0xFFFFFFFF
    return "initrd=%08x sum=%08x end" % (len(data), total)


if sys.argv[1:2] == ["--sum"]:
    print(initrd_sum(sys.argv[2:]))
    sys.exit(0)

args = argparse.ArgumentParser()
args.add_argument("out")
args.add_argument("--size-mib", type=int)
args.add_argument("--init-size-mib", type=int, default=0)
args.add_argument("--pref-mib", type=int, default=0)
args.add_argument("--cmdline-size", type=int, default=2047)
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
struct.pack_into("<I", setup, 0x238, args.cmdline_size)
struct.pack_into("<Q", setup, 0x258, args.pref_mib << 20)  # pref_address
struct.pack_into("<I", setup, 0x260, args.init_size_mib << 20)  # init_size

size = args.size_mib << 20 if args.size_mib else 400 * 1024
code = CODE + b"K" * (size - len(CODE))

with open(args.out, "wb") as f:
    f.write(bytes(setup) + code)
