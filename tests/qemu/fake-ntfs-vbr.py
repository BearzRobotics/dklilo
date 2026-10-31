#!/usr/bin/env python3
"""Writes a fake NTFS boot sector: the NTFS OEM id, the 0x55AA signature, and
real-mode code that reports on COM1 how it was entered: dl (the boot drive)
and the type byte of the partition entry ds:si points to, exactly as an MBR
would leave them. Used to test chainloading without a Windows install.

usage: fake-ntfs-vbr.py out.bin
"""
import sys

def out_text(text):
    return b"".join(bytes([0xB0, ch, 0xEE]) for ch in text)  # mov al, ch ; out dx, al

code = bytes([
    0xFA,              # cli
    0x88, 0xD3,        # mov bl, dl      ; boot drive
    0x89, 0xF5,        # mov bp, si      ; partition entry pointer
    0xBA, 0xF8, 0x03,  # mov dx, 0x3F8
])
code += out_text(b"FAKE-NTFS-BOOT-OK DL=")
code += bytes([0x88, 0xD8, 0xEE])              # mov al, bl ; out dx, al
code += out_text(b" TYPE=")
code += bytes([0x8A, 0x46, 0x04, 0xEE])        # mov al, [bp+4] ; out dx, al
code += out_text(b"\r\n")
code += bytes([0xF4, 0xEB, 0xFD])              # hlt ; jmp back to hlt

sec = bytearray(512)
sec[0:3] = bytes([0xEB, 0x52, 0x90])           # jmp short to 0x54
sec[3:11] = b"NTFS    "
sec[0x54:0x54 + len(code)] = code
sec[510:512] = bytes([0x55, 0xAA])
open(sys.argv[1], "wb").write(sec)
