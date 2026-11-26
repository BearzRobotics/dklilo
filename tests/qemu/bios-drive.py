#!/usr/bin/env python3
"""Runs a QEMU command and checks its serial output step by step.

Usage: bios-drive.py <serial file> <monitor socket> <step>... -- <qemu command>

Steps run in order:
  wait:TEXT   wait until TEXT appears in the serial output *after* the point
              where the previous wait matched
  key:NAME    press a key on the emulated PS/2 keyboard (monitor `sendkey`)
  screen:TEXT wait until TEXT is on the VGA text screen, which is where output
              through the BIOS appears (stage 1 prints nowhere else)

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

    def command_monitor(line):
        nonlocal link
        if link is None:
            link = socket.socket(socket.AF_UNIX)
            link.connect(monitor)
        link.sendall((line + "\n").encode())

    def screen():
        dump = serial + ".vga"
        command_monitor('pmemsave 0xb8000 4000 "%s"' % dump)
        time.sleep(0.3)
        if not os.path.exists(dump):
            return b""
        with open(dump, "rb") as f:
            return f.read()[::2]  # every other byte is a colour

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
                time.sleep(0.5)  # let the loader reach its key read
                command_monitor("sendkey %s" % arg)
            elif kind == "screen":
                end = time.time() + TIMEOUT
                time.sleep(1)  # for QEMU to open the monitor socket
                while arg.encode() not in screen():
                    if time.time() > end or qemu.poll() is not None:
                        print("timed out waiting for %r on the screen" % arg)
                        return 1
            else:
                print("unknown step %r" % step)
                return 1
        return 0
    finally:
        qemu.kill()
        qemu.wait()


if __name__ == "__main__":
    sys.exit(main())
