#!/bin/sh
# Runs the unit tests (dklilo's and the fsread package's) and every QEMU boot
# test. Tests that need a kernel or a tool that isn't there are skipped (exit
# 77) and listed again at the end; see tests/qemu/make-linux-disk.sh.
set -u
cd "$(dirname "$0")/.."
zig build dev || exit 1
zig build test || exit 1
(cd deps/fsread && zig build test) || exit 1
fail=""
skip=""
for t in tests/qemu/l*.sh; do
    out=$("$t" 2>&1); rc=$?
    case $rc in
        0) echo "$out" | tail -3 ;;
        77) echo "SKIP $t"; echo "$out" | grep '^SKIP'; skip="$skip $t" ;;
        *) echo "---- $t failed (exit $rc) ----"; echo "$out" | tail -40; fail="$fail $t" ;;
    esac
done
[ -z "$skip" ] || echo "Skipped:$skip"
if [ -n "$fail" ]; then echo "FAILED:$fail"; exit 1; fi
echo "All tests that ran passed."
