# Filesystem readers as a separate package using `std.Io`

**Decision.** The ext4, btrfs, FAT and ISO 9660 readers (plus `crc` and `lzo`)
moved from `src/common` to the path dependency `deps/fsread`, so other projects
can reuse them. They read through `std.Io.File.readPositional` instead of
dklilo's `BlockDev`.

**Why.** Reuse; and the readers should not depend on how bytes are fetched.

**Alternatives.** Keep them in `src/common` (not reusable); keep `BlockDev` as the
reader interface (simpler, but a dklilo-private abstraction).

**Consequences.** The bootloaders need an `Io`: `src/common/devio.zig` builds one
over a `BlockDev`. `Volume` holds a pointer to a stable `BlockDev` copy owned by
`volumes.Set`. Binary size grew slightly. Limits of `std.Io` on freestanding
targets are in `docs/std-io-freestanding.md`.

The package can move to its own git repository by replacing the `.path` in
`build.zig.zon` with a `.url`/`.hash`.
