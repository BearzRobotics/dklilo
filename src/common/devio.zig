//! Presents a `BlockDev` to the filesystem readers as a `std.Io`.
//!
//! The readers (the `fsread` package) read through `std.Io.File.readPositional`.
//! A bootloader has no operating system, so there is no `Io` to hand them;
//! this builds one whose only working operation is `fileReadPositional`,
//! served from a block device. Everything else is `std.Io.failing`.
//!
//! The `File` is a dummy: on freestanding targets `std.Io.File.Handle` is
//! `void`, so a file cannot name a device. The device travels in the `Io`'s
//! userdata instead, and one `Io` serves exactly one `BlockDev`. The same
//! adapter is used on Linux so the loaders and the tool share a code path.

const std = @import("std");
const fsread = @import("fsread");
const blockdev = @import("blockdev.zig");

const Io = std.Io;

const vtable: Io.VTable = blk: {
    var v = Io.failing.vtable.*;
    v.fileReadPositional = readPositional;
    break :blk v;
};

fn readPositional(userdata: ?*anyopaque, _: Io.File, data: []const []u8, offset: u64) Io.File.ReadPositionalError!usize {
    const dev: *const blockdev.BlockDev = @ptrCast(@alignCast(userdata.?));
    var off = offset;
    var total: usize = 0;
    for (data) |buf| {
        if (buf.len == 0) continue;
        const size = dev.sector_count * dev.sector_size;
        if (off >= size) break; // end of file
        const n: usize = @intCast(@min(@as(u64, buf.len), size - off));
        dev.readBytes(off, buf[0..n]) catch return error.InputOutput;
        off += n;
        total += n;
        if (n < buf.len) break;
    }
    return total;
}

/// An `Io` that reads `dev`. `dev` must outlive every use of the result.
pub fn io(dev: *const blockdev.BlockDev) Io {
    return .{ .userdata = @constCast(dev), .vtable = &vtable };
}

/// The placeholder file to pass with `io(dev)`; its handle is never looked at.
pub const file: Io.File = .{
    .handle = if (@TypeOf(@as(Io.File, undefined).handle) == void) {} else -1,
    .flags = .{ .nonblocking = false },
};

/// A filesystem-reader region over bytes `start..start+len` of `dev`.
pub fn region(dev: *const blockdev.BlockDev, start: u64, len: u64) fsread.Region {
    return .{ .io = io(dev), .file = file, .start = start, .len = len };
}

/// The region covering a `blockdev.Region` (a partition, typically).
pub fn fromRegion(dev: *const blockdev.BlockDev, r: blockdev.Region) fsread.Region {
    return region(dev, r.start, r.len);
}
