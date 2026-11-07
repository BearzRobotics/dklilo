# fsread

Read-only ext2/3/4, btrfs, FAT12/16/32 and ISO 9660 readers in Zig, with I/O
supplied by the caller through `std.Io`. No OS, threads or libc required.

```zig
const fsread = @import("fsread");

const region: fsread.Region = .{ .io = io, .file = file, .start = 0, .len = size };
var fs = try fsread.fs.Fs.open(allocator, region); // detects the filesystem
defer fs.deinit();
const f = try fs.lookup("/boot/vmlinuz");
const n = try fs.readAt(&f, 0, buf);
```

Only `std.Io.File.readPositional` is used. On a hosted OS pass a real `Io` and
`File`. Without an OS, provide an `Io` whose `fileReadPositional` reads your
device (copy `std.Io.failing` and override it); see dklilo's
`src/common/devio.zig` and `docs/std-io-freestanding.md` for the limits.

Requires Zig 0.17.1. Tests against real mkfs images live in the dklilo repo.
