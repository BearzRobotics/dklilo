#!/bin/sh
# Runs the unit tests and every QEMU boot test. Tests that need a kernel are
# skipped (exit 77) when none is available; see tests/qemu/make-linux-disk.sh.
set -u
cd "$(dirname "$0")/.."
zig build || exit 1
zig build test || exit 1
fail=0
for t in tests/qemu/l*.sh; do
    case "$t" in *make-*|*qemu-uefi.sh) continue;; esac
    out=$("$t" 2>&1); rc=$?
    if [ $rc -eq 77 ]; then echo "SKIP $t"; continue; fi
    echo "$out" | tail -3
    [ $rc -eq 0 ] || fail=1
done
exit $fail
