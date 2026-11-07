# Using `std.Io` for I/O-independent code on freestanding targets

Status as of Zig 0.17.1 (checked against the standard library source shipped
with that toolchain, `lib/std/Io.zig` and `lib/std/Io/File.zig`).

The `fsread` package (`deps/fsread`) reads ext4, btrfs, FAT and ISO 9660 through
`std.Io.File.readPositional`. The caller supplies the `std.Io`. dklilo's
bootloaders (BIOS i586 freestanding, UEFI x86_64) supply one that reads a block
device; the Linux tool uses the same adapter (`src/common/devio.zig`).

It works, and builds for `x86-freestanding` and `x86_64-uefi`. These are the
rough edges, written so they can be filed upstream.

## 1. `File.Handle` is `void` on freestanding

`Io.File.Handle = std.posix.fd_t`, and `std.posix.fd_t` is `void` for
freestanding. A `File` therefore cannot identify a device, partition or buffer.
Our adapter works around it: the device lives in `Io.userdata` and one `Io`
serves one device, with a dummy `File`. Multi-device code needs one `Io` per
device.

Wanted: a way for an `Io` implementation to define its own handle type, or a
non-`void` opaque handle on freestanding. (Also: the dummy file is written as
`if (@TypeOf(...handle) == void) {} else -1`, which is ugly.)

## 2. The vtable has 109 required entries and no optional ones

A custom `Io` that only reads must fill every field of `Io.VTable`. We copy
`Io.failing.vtable.*` and override `fileReadPositional`. That works, but:

* a new upstream operation is silently `failing` (fine, because we copy by
  value), but the code is tied to the vtable layout;
* the stubs are linked in. Measured total size change of this refactor on
  dklilo: stage2.bin 139.6 → 145.0 KB, `dkliloX64.efi` 207 → 217 KB. That
  includes the new adapter and `Region`; I did not isolate the stubs' share.

Wanted: a split of `Io` into capability groups (read-only file access, clock,
concurrency, ...) so a consumer that needs only positional reads can say so and
an implementation only provides that. Related: ziglang/zig#31421 (unused
`std.Io` functions are not removed, tracked as a known regression in 0.16/0.17).

## 3. No random-access reader type that does not need `Io.File`

`std.Io.Reader` is a forward stream and has no seek. Random access exists only
as `File.readPositional` / `File.Reader.seekTo`, which require an `Io.File`.
A filesystem reader wants "read `n` bytes at offset `o` of something", which is
what `readPositional` provides, but a `File` is a heavyweight handle for it.

Wanted: a small interface for positional reads (`read(buf, offset)`), usable
without a file handle.

## 4. Errors

`File.ReadPositionalError` is a large set (cancellation, permissions, locks,
...) irrelevant to a block-device read. `fsread` collapses it to
`error.IoError`; information is lost.

## 5. Sector alignment

`std.Io` has no notion of a minimum I/O unit. Block devices (BIOS int 13h,
UEFI BlockIo) need whole sectors, so the adapter bounces unaligned reads.
This is dklilo's job, not a defect, but a generic filesystem library cannot
express "my backing store needs 512/2048/4096-byte aligned reads" through
`std.Io`.

## Not blockers (checked)

* `Io.failing` is public and can be copied and overridden at comptime.
* `File.readPositionalAll` compiles and runs on freestanding and UEFI targets.
* Nothing needs threads, clocks or an OS: `.single_threaded` builds are fine.
