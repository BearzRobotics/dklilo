//! Facts about Linux block devices, read from sysfs.

const std = @import("std");
const Io = std.Io;

/// Is block device `major`:`minor` a partition of a disk? `sys` is
/// `/sys/dev/block` (a parameter so tests can fake it). The kernel gives every
/// partition, and no whole disk, a `partition` attribute.
pub fn isPartition(io: Io, sys: Io.Dir, major: u32, minor: u32) !bool {
    var buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{d}:{d}/partition", .{ major, minor }) catch unreachable;
    sys.access(io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => return false,
        else => return e,
    };
    return true;
}

test "only devices with a partition attribute are partitions" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "8:0");
    try tmp.dir.createDirPath(io, "8:1");
    try tmp.dir.writeFile(io, .{ .sub_path = "8:1/partition", .data = "1\n" });
    try std.testing.expect(!try isPartition(io, tmp.dir, 8, 0));
    try std.testing.expect(try isPartition(io, tmp.dir, 8, 1));
    try std.testing.expect(!try isPartition(io, tmp.dir, 7, 7));
}
