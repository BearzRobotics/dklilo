#!/usr/bin/env python3
"""Writes a PC option ROM that makes the disk BIOS use a lot of stack.

It hooks int 13h: on every call it writes 1 KiB of 0xCC onto the caller's
stack, gives the stack back, and passes the call to the BIOS's own handler.
Real BIOSes differ in how much stack they use; a loader must not keep anything
the BIOS reads (the disk address packet) just below its stack pointer.

It prints "deep-stack hook installed" on COM1 when it loads.

Usage: deep-stack-rom.py <out.rom>
"""
import struct
import sys

WORDS = 512  # pushed on each disk call
BANNER = b"deep-stack hook installed\r\n\0"


def build(handler, old, banner):
    """16-bit code, entered at ROM offset 3. The arguments are ROM offsets."""
    w = lambda v: struct.pack("<H", v)
    init = (
        b"\x60\x1e"                          # pusha; push ds
        b"\xfc"                              # cld
        b"\xbe" + w(banner) +                # mov si, banner
        b"\xba\xf8\x03"                      # mov dx, 0x3F8 (COM1)
        b"\x2e\xac"                          # 1: lodsb from cs:si
        b"\x84\xc0\x74\x03"                  # test al, al; jz 2f
        b"\xee\xeb\xf7"                      # out dx, al; jmp 1b
        b"\x31\xc0\x8e\xd8"                  # 2: ds = 0
        b"\xa1\x4c\x00\x2e\xa3" + w(old) +   # save the int 13h vector
        b"\xa1\x4e\x00\x2e\xa3" + w(old + 2) +
        b"\xc7\x06\x4c\x00" + w(handler) +   # and point it at the hook
        b"\x8c\x0e\x4e\x00"
        b"\x1f\x61\xcb"                      # pop ds; popa; retf
    )
    hook = (
        b"\x60"                              # pusha
        b"\xb9" + w(WORDS) +                 # mov cx, WORDS
        b"\x68\xcc\xcc"                      # 3: push 0xCCCC
        b"\xe2\xfb"                          # loop 3b
        b"\x81\xc4" + w(2 * WORDS) +         # add sp, 2*WORDS
        b"\x61"                              # popa
        b"\x2e\xff\x2e" + w(old)             # jmp far cs:[old]
    )
    return init, hook


init, hook = build(0, 0, 0)  # first pass: for the lengths
handler = 3 + len(init)
old = handler + len(hook)
banner = old + 4
init, hook = build(handler, old, banner)

rom = bytearray(b"\x55\xaa\x01" + init + hook + bytes(4) + BANNER)
rom += bytes(512 - len(rom))
rom[-1] = -sum(rom) & 0xFF  # an option ROM's bytes add up to zero
with open(sys.argv[1], "wb") as f:
    f.write(rom)
