#!/bin/sh
# Builds from only the files build.zig.zon says the package consists of, as
# someone who fetched it would (docs/bugs BLD-03). Works in a temporary copy.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
d=$(mktemp -d); trap 'rm -rf "${d:?}"' EXIT
paths=$(sed -n 's/^ *\.paths = \.{\(.*\)},.*/\1/p' "$root/build.zig.zon" | tr -d '",')
[ -n "$paths" ] || { echo "FAIL: no .paths in build.zig.zon"; exit 1; }
(cd "$root" && for p in $paths; do tar --exclude=.zig-cache --exclude=zig-out -cf - "$p"; done) |
    tar -xf - -C "$d" --ignore-zeros
(cd "$d" && zig build dev) || { echo "FAIL: the packaged files don't build"; exit 1; }
(cd "$d" && zig build test) || { echo "FAIL: the packaged files don't pass their tests"; exit 1; }
echo "PASS: the package has everything its build needs"
