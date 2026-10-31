//! The one interface everything above the hardware reads through.
//!
//! A `BlockDev` reads whole sectors at an LBA. It is backed by BIOS `int 13h`,
//! UEFI `BlockIo`, or (in tests and the Linux tool) memory or a file. A
//! `Region` is a byte range of a device, usually one partition, and is what
//! the filesystem readers take.

const std = @import("std");

pub const Error = error{
    /// The device reported a failure.
    IoError,
    /// The request went past the end of the device or region.
    OutOfRange,
};

/// Largest sector size supported (4Kn drives). Sizes the bounce buffer.
pub const max_sector_size = 4096;

pub const BlockDev = struct {
    ctx: *anyopaque,
    /// Reads `buf.len / sector_size` whole sectors starting at `lba`.
    readSectorsFn: *const fn (ctx: *anyopaque, lba: u64, buf: []u8) Error!void,
    sector_size: u32,
    sector_count: u64,

    /// Reads whole sectors. `buf.len` must be a multiple of the sector size.
    pub fn readSectors(self: BlockDev, lba: u64, buf: []u8) Error!void {
        std.debug.assert(buf.len % self.sector_size == 0);
        const n = buf.len / self.sector_size;
        if (lba > self.sector_count or n > self.sector_count - lba) return error.OutOfRange;
        if (n == 0) return;
        return self.readSectorsFn(self.ctx, lba, buf);
    }

    /// Reads an arbitrary byte range. Unaligned head and tail go through a
    /// bounce buffer; the aligned middle is read straight into `buf`.
    pub fn readBytes(self: BlockDev, offset: u64, buf: []u8) Error!void {
        const ss: u64 = self.sector_size;
        std.debug.assert(ss <= max_sector_size);
        var bounce: [max_sector_size]u8 = undefined;
        var off = offset;
        var rest = buf;
        while (rest.len > 0) {
            const in_sector = off % ss;
            if (in_sector == 0 and rest.len >= ss) {
                const aligned: usize = rest.len - rest.len % self.sector_size;
                try self.readSectors(off / ss, rest[0..aligned]);
                off += aligned;
                rest = rest[aligned..];
            } else {
                try self.readSectors(off / ss, bounce[0..self.sector_size]);
                const n: usize = @intCast(@min(@as(u64, rest.len), ss - in_sector));
                @memcpy(rest[0..n], bounce[@intCast(in_sector)..][0..n]);
                off += n;
                rest = rest[n..];
            }
        }
    }

    /// The whole device as a region.
    pub fn whole(self: BlockDev) Region {
        return .{ .dev = self, .start = 0, .len = self.sector_count * self.sector_size };
    }
};

/// A byte range of a device (a partition, typically). Offsets are relative to
/// the start of the region and reads past its end are errors.
pub const Region = struct {
    dev: BlockDev,
    start: u64,
    len: u64,

    pub fn readAt(self: Region, offset: u64, buf: []u8) Error!void {
        if (offset > self.len or buf.len > self.len - offset) return error.OutOfRange;
        return self.dev.readBytes(self.start + offset, buf);
    }

    /// A sub-range of this region.
    pub fn slice(self: Region, offset: u64, len: u64) Error!Region {
        if (offset > self.len or len > self.len - offset) return error.OutOfRange;
        return .{ .dev = self.dev, .start = self.start + offset, .len = len };
    }
};

/// A block device over a byte slice in memory. Used by tests and by the Linux
/// tool after it has read an image.
pub const MemDisk = struct {
    data: []const u8,
    sector_size: u32 = 512,

    pub fn blockDev(self: *MemDisk) BlockDev {
        return .{
            .ctx = self,
            .readSectorsFn = read,
            .sector_size = self.sector_size,
            .sector_count = self.data.len / self.sector_size,
        };
    }

    fn read(ctx: *anyopaque, lba: u64, buf: []u8) Error!void {
        const self: *MemDisk = @ptrCast(@alignCast(ctx));
        const off = lba * self.sector_size;
        @memcpy(buf, self.data[off..][0..buf.len]);
    }
};

test "readBytes handles unaligned ranges" {
    var raw: [4096]u8 = undefined;
    for (&raw, 0..) |*b, i| b.* = @truncate(i *% 7);
    var disk = MemDisk{ .data = &raw };
    const dev = disk.blockDev();
    var buf: [1500]u8 = undefined;
    try dev.readBytes(37, &buf);
    try std.testing.expectEqualSlices(u8, raw[37..][0..1500], &buf);
    try std.testing.expectError(error.OutOfRange, dev.readBytes(4000, &buf));
}
