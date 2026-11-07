#!/usr/bin/env python3
"""Writes a newc cpio archive without needing root (so device nodes work).

usage: mkcpio.py out.cpio [--init FILE] [--file NAME=CONTENT]...
Always includes /dev/console (char 5,1), /proc and /dev directories.
"""
import sys, os, struct

def entry(name, mode, data=b"", rdev=(0, 0), ino=[1]):
    ino[0] += 1
    nm = name.encode() + b"\0"
    hdr = "070701" + "".join("%08X" % v for v in (
        ino[0], mode, 0, 0, 1, 0, len(data), 0, 0, rdev[0], rdev[1], len(nm), 0))
    out = hdr.encode() + nm
    out += b"\0" * (-len(out) % 4)
    out += data
    out += b"\0" * (-len(data) % 4)
    return out

def main():
    out_path, args = sys.argv[1], sys.argv[2:]
    buf = b""
    buf += entry("dev", 0o040755)
    buf += entry("dev/console", 0o020600, rdev=(5, 1))
    buf += entry("proc", 0o040755)
    i = 0
    while i < len(args):
        if args[i] == "--init":
            buf += entry("init", 0o100755, open(args[i + 1], "rb").read()); i += 2
        elif args[i] == "--file":
            n, c = args[i + 1].split("=", 1)
            buf += entry(n, 0o100644, c.encode() + b"\n"); i += 2
        else:
            sys.exit("bad arg " + args[i])
    buf += entry("TRAILER!!!", 0)
    open(out_path, "wb").write(buf)

main()
