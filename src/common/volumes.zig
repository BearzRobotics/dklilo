//! The set of filesystems dklilo can see: every partition of every disk
//! (or a whole disk with no partition table), identified the way the
//! configuration names them: by `LABEL=`, `UUID=` or `PARTUUID=` prefix.
//! Shared by the BIOS and UEFI loaders and by the Linux tool.

const std = @import("std");
const blockdev = @import("blockdev.zig");
const part = @import("part.zig");
const ext4 = @import("fs/ext4.zig");

pub const Error = error{
    /// A path prefix names a volume that isn't there.
    NoSuchVolume,
    /// The volume has no filesystem dklilo can read.
    NoFilesystem,
} || ext4.Error;

pub const Volume = struct {
    region: blockdev.Region,
    /// Which disk this volume is on, in the order disks were added.
    disk: usize,
    /// 1-based partition number, or 0 for a whole-disk filesystem.
    number: u8,
    /// GPT unique partition GUID (on-disk byte order), if from a GPT disk.
    part_guid: ?[16]u8 = null,
    /// MBR disk signature, if from an MBR disk.
    mbr_signature: ?u32 = null,
    state: enum { unprobed, ext4, none } = .unprobed,
    fs: ext4.Fs = undefined,

    /// The ext4 filesystem on this volume, or null if it has none we can read.
    pub fn filesystem(self: *Volume, allocator: std.mem.Allocator) ?*ext4.Fs {
        switch (self.state) {
            .ext4 => return &self.fs,
            .none => return null,
            .unprobed => {
                if (ext4.Fs.open(allocator, self.region)) |fs| {
                    self.fs = fs;
                    self.state = .ext4;
                    return &self.fs;
                } else |_| {
                    self.state = .none;
                    return null;
                }
            },
        }
    }
};

pub const Set = struct {
    allocator: std.mem.Allocator,
    vols: std.ArrayList(Volume) = .empty,
    disks: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Set {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Set) void {
        for (self.vols.items) |*v| if (v.state == .ext4) v.fs.deinit();
        self.vols.deinit(self.allocator);
    }

    /// Adds the partitions of `dev`. A disk with no partition table counts as
    /// one whole-disk volume (CD images, "superfloppies"). Returns the disk's
    /// index.
    pub fn addDisk(self: *Set, dev: blockdev.BlockDev) std.mem.Allocator.Error!usize {
        const disk = self.disks;
        self.disks += 1;
        const table = part.read(dev) catch {
            try self.vols.append(self.allocator, .{ .region = dev.whole(), .disk = disk, .number = 0 });
            return disk;
        };
        for (table.slice()) |p| {
            // The extended container itself holds no filesystem.
            if (table.kind == .mbr and (p.mbr_type == 0x05 or p.mbr_type == 0x0F or p.mbr_type == 0x85)) continue;
            try self.vols.append(self.allocator, .{
                .region = p.region(dev),
                .disk = disk,
                .number = p.number,
                .part_guid = if (table.kind == .gpt) p.part_guid else null,
                .mbr_signature = if (table.kind == .mbr) table.disk_signature else null,
            });
        }
        return disk;
    }

    pub const Located = struct { vol: *Volume, path: []const u8 };

    /// Splits `LABEL=x:/path` style specs. Plain paths use `default`.
    pub fn resolve(self: *Set, spec: []const u8, default: *Volume) Error!Located {
        const prefixes = [_][]const u8{ "LABEL=", "UUID=", "PARTUUID=" };
        inline for (prefixes) |pre| {
            if (std.mem.startsWith(u8, spec, pre)) {
                const rest = spec[pre.len..];
                const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return error.NoSuchVolume;
                const value = rest[0..colon];
                const path = rest[colon + 1 ..];
                for (self.vols.items) |*v| if (self.matches(v, pre, value)) return .{ .vol = v, .path = path };
                return error.NoSuchVolume;
            }
        }
        return .{ .vol = default, .path = spec };
    }

    fn matches(self: *Set, v: *Volume, comptime prefix: []const u8, value: []const u8) bool {
        if (std.mem.eql(u8, prefix, "PARTUUID=")) {
            if (v.part_guid) |g| {
                var s: [36]u8 = undefined;
                part.formatGuid(g, &s);
                return std.ascii.eqlIgnoreCase(&s, value);
            }
            if (v.mbr_signature) |sig| {
                var b: [16]u8 = undefined;
                const s = std.fmt.bufPrint(&b, "{x:0>8}-{x:0>2}", .{ sig, v.number }) catch return false;
                return std.ascii.eqlIgnoreCase(s, value);
            }
            return false;
        }
        const fs = v.filesystem(self.allocator) orelse return false;
        if (std.mem.eql(u8, prefix, "LABEL=")) return std.mem.eql(u8, fs.label(), value);
        var s: [36]u8 = undefined;
        formatUuid(fs.uuid, &s);
        return std.ascii.eqlIgnoreCase(&s, value);
    }

    /// Finds `dklilo.conf`: for each volume, `/boot/dklilo.conf` then
    /// `/dklilo.conf`. `disk` limits the search to one disk (the boot disk).
    pub fn findConfig(self: *Set, disk: ?usize) ?struct { vol: *Volume, path: []const u8 } {
        const paths = [_][]const u8{ "/boot/dklilo.conf", "/dklilo.conf" };
        for (self.vols.items) |*v| {
            if (disk) |d| if (v.disk != d) continue;
            const fs = v.filesystem(self.allocator) orelse continue;
            for (paths) |p| {
                const ino = fs.lookup(p) catch continue;
                if (ino.isRegular()) return .{ .vol = v, .path = p };
            }
        }
        return null;
    }

    /// Reads a whole file into memory owned by the caller.
    pub fn readFile(self: *Set, vol: *Volume, path: []const u8) Error![]u8 {
        const fs = vol.filesystem(self.allocator) orelse return error.NoFilesystem;
        const ino = try fs.lookup(path);
        if (ino.isDir()) return error.IsDirectory;
        const buf = try self.allocator.alloc(u8, @intCast(ino.size));
        errdefer self.allocator.free(buf);
        const n = try fs.readAt(&ino, 0, buf);
        if (n != buf.len) return error.Corrupt;
        return buf;
    }
};

/// Formats an ext4 UUID (plain byte order) as 8-4-4-4-12.
pub fn formatUuid(uuid: [16]u8, out: *[36]u8) void {
    const hex = "0123456789abcdef";
    var o: usize = 0;
    for (uuid, 0..) |b, n| {
        if (n == 4 or n == 6 or n == 8 or n == 10) {
            out[o] = '-';
            o += 1;
        }
        out[o] = hex[b >> 4];
        out[o + 1] = hex[b & 0xF];
        o += 2;
    }
}

test "a whole-disk filesystem is found by label, UUID, and config path" {
    var d = blockdev.MemDisk{ .data = @embedFile("ext4.img") };
    var set = Set.init(std.testing.allocator);
    defer set.deinit();
    const disk = try set.addDisk(d.blockDev());
    try std.testing.expectEqual(@as(usize, 0), disk);
    try std.testing.expectEqual(@as(usize, 1), set.vols.items.len);

    const def = &set.vols.items[0];
    const by_label = try set.resolve("LABEL=dkltest:/boot/hello.txt", def);
    try std.testing.expectEqualStrings("/boot/hello.txt", by_label.path);
    try std.testing.expect(by_label.vol == def);

    var u: [36]u8 = undefined;
    formatUuid(def.filesystem(std.testing.allocator).?.uuid, &u);
    var spec_buf: [64]u8 = undefined;
    const spec = try std.fmt.bufPrint(&spec_buf, "UUID={s}:/x", .{u});
    try std.testing.expectEqualStrings("/x", (try set.resolve(spec, def)).path);

    try std.testing.expectError(error.NoSuchVolume, set.resolve("LABEL=nope:/x", def));
    try std.testing.expectEqualStrings("/plain", (try set.resolve("/plain", def)).path);

    const data = try set.readFile(def, "/boot/hello.txt");
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("hello\n", data);
}

test "partitions of an MBR disk are listed, extended container skipped" {
    var d = blockdev.MemDisk{ .data = @embedFile("mbr.img") };
    var set = Set.init(std.testing.allocator);
    defer set.deinit();
    _ = try set.addDisk(d.blockDev());
    // 3 primaries + 2 logical (the extended container is skipped).
    try std.testing.expectEqual(@as(usize, 5), set.vols.items.len);
    try std.testing.expectEqual(@as(u8, 5), set.vols.items[3].number);
    try std.testing.expectEqual(@as(?u32, 0x4a6f8c21), set.vols.items[0].mbr_signature);
    try std.testing.expect(set.findConfig(null) == null); // no filesystems here
}
