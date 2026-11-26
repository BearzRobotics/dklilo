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

pub const Partition = struct {
    /// The disk's name under /dev, e.g. `sda` or `nvme0n1`.
    disk: []const u8,
    number: u32,
};

/// The disk and partition number of block device `major`:`minor`, or null if
/// it is not a partition. `disk` is written into `buf`.
pub fn partition(io: Io, sys: Io.Dir, major: u32, minor: u32, buf: []u8) !?Partition {
    var path_buf: [64]u8 = undefined;
    const number_path = std.fmt.bufPrint(&path_buf, "{d}:{d}/partition", .{ major, minor }) catch unreachable;
    var text: [16]u8 = undefined;
    const number_text = sys.readFile(io, number_path, &text) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    const number = try std.fmt.parseInt(u32, std.mem.trim(u8, number_text, " \n"), 10);
    // `M:m` links to .../block/<disk>/<partition>.
    const link_path = std.fmt.bufPrint(&path_buf, "{d}:{d}", .{ major, minor }) catch unreachable;
    var link: [Io.Dir.max_path_bytes]u8 = undefined;
    const target = link[0..try sys.readLink(io, link_path, &link)];
    const parent = std.fs.path.dirname(target) orelse return error.UnexpectedSysfs;
    const name = std.fs.path.basename(parent);
    if (name.len == 0 or name.len > buf.len) return error.UnexpectedSysfs;
    // A '/' in a device name is a '!' in sysfs (as for cciss disks).
    @memcpy(buf[0..name.len], name);
    std.mem.replaceScalar(u8, buf[0..name.len], '!', '/');
    return .{ .disk = buf[0..name.len], .number = number };
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

test "a partition's disk and number come from sysfs, not from its name" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "devices/block/nvme0n1/nvme0n1p12");
    try tmp.dir.writeFile(io, .{ .sub_path = "devices/block/nvme0n1/nvme0n1p12/partition", .data = "12\n" });
    try tmp.dir.symLink(io, "devices/block/nvme0n1/nvme0n1p12", "259:7", .{ .is_directory = true });
    try tmp.dir.createDirPath(io, "8:0");
    var buf: [64]u8 = undefined;
    const p = (try partition(io, tmp.dir, 259, 7, &buf)).?;
    try std.testing.expectEqualStrings("nvme0n1", p.disk);
    try std.testing.expectEqual(@as(u32, 12), p.number);
    try std.testing.expect(try partition(io, tmp.dir, 8, 0, &buf) == null);
}
