#!/usr/bin/env python3
"""Runs a QEMU command and checks its serial output step by step.

Usage: bios-drive.py <serial file> <monitor socket> <step>... -- <qemu command>

Steps run in order:
  wait:TEXT   wait until TEXT appears in the serial output *after* the point
              where the previous wait matched
  key:NAME    press a key on the emulated PS/2 keyboard (monitor `sendkey`)

The serial line is only read, never written, so any reaction to a key proves
that the loader's keyboard path works. Exits 1 on the first wait that times out.
"""
import os
import socket
import subprocess
import sys
import time

TIMEOUT = 30  # seconds per wait


def main():
    split = sys.argv.index("--")
    serial, monitor, *steps = sys.argv[1:split]
    command = sys.argv[split + 1:] + [
        "-display", "none", "-no-reboot",
        "-serial", "file:" + serial,
        "-monitor", "unix:%s,server=on,wait=off" % monitor,
    ]
    qemu = subprocess.Popen(command, stdout=subprocess.DEVNULL)
    link = None
    seen = 0  # serial bytes consumed by earlier waits

    def output():
        if not os.path.exists(serial):
            return b""
        with open(serial, "rb") as f:
            return f.read()

    try:
        for step in steps:
            kind, _, arg = step.partition(":")
            if kind == "wait":
                end = time.time() + TIMEOUT
                while True:
                    at = output().find(arg.encode(), seen)
                    if at >= 0:
                        seen = at + len(arg)
                        break
                    if time.time() > end or qemu.poll() is not None:
                        print("timed out waiting for %r" % arg)
                        return 1
                    time.sleep(0.1)
            elif kind == "key":
                if link is None:
                    link = socket.socket(socket.AF_UNIX)
                    link.connect(monitor)
                time.sleep(0.5)  # let the loader reach its key read
                link.sendall(("sendkey %s\n" % arg).encode())
            else:
                print("unknown step %r" % step)
                return 1
        return 0
    finally:
        qemu.kill()
        qemu.wait()


if __name__ == "__main__":
    sys.exit(main())
