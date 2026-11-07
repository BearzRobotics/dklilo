//! One face for every filesystem reader. Loaders open a partition without
//! caring whether it holds ext4 or btrfs, then look up and read files.

const std = @import("std");
const region_mod = @import("region.zig");
const ext4 = @import("ext4.zig");
const btrfs = @import("btrfs.zig");
const iso9660 = @import("iso9660.zig");
const fat = @import("fat.zig");

pub const Error = ext4.Error || btrfs.Error || iso9660.Error || fat.Error;

pub const Kind = enum { ext4, btrfs, iso9660, fat };

/// A file or directory found by `lookup`. Opaque apart from the common fields.
pub const File = struct {
    size: u64,
    is_dir: bool,
    is_regular: bool,
    impl: union(Kind) { ext4: ext4.Inode, btrfs: btrfs.Inode, iso9660: iso9660.Inode, fat: fat.Inode },
};

pub const Fs = union(Kind) {
    ext4: ext4.Fs,
    btrfs: btrfs.Fs,
    iso9660: iso9660.Fs,
    fat: fat.Fs,

    /// Opens the filesystem on `region`, detecting its type.
    pub fn open(allocator: std.mem.Allocator, region: region_mod.Region) Error!Fs {
        if (ext4.Fs.open(allocator, region)) |f| {
            return .{ .ext4 = f };
        } else |e| switch (e) {
            error.BadMagic => {},
            else => return e,
        }
        if (btrfs.Fs.open(allocator, region)) |f| {
            return .{ .btrfs = f };
        } else |e| switch (e) {
            error.BadMagic => {},
            else => return e,
        }
        if (iso9660.Fs.open(allocator, region)) |f| {
            return .{ .iso9660 = f };
        } else |e| switch (e) {
            error.BadMagic => {},
            else => return e,
        }
        return .{ .fat = try fat.Fs.open(allocator, region) };
    }

    pub fn deinit(self: *Fs) void {
        switch (self.*) {
            inline else => |*f| f.deinit(),
        }
    }

    pub fn label(self: *const Fs) []const u8 {
        return switch (self.*) {
            inline else => |*f| f.label(),
        };
    }

    pub fn uuid(self: *const Fs) [16]u8 {
        return switch (self.*) {
            .ext4 => |f| f.uuid,
            .btrfs => |*f| f.uuid(),
            .iso9660 => |*f| f.uuid(),
            .fat => |*f| f.uuid(),
        };
    }

    /// Selects a btrfs subvolume (`subvol =` in the config); a no-op on ext4
    /// when `subvol` is null, an error otherwise.
    pub fn selectSubvolume(self: *Fs, subvol: ?[]const u8) Error!void {
        switch (self.*) {
            .btrfs => |*f| try f.useSubvolume(subvol),
            .ext4, .iso9660, .fat => if (subvol != null) return error.Unsupported,
        }
    }

    pub fn lookup(self: *Fs, path: []const u8) Error!File {
        switch (self.*) {
            .ext4 => |*f| {
                const i = try f.lookup(path);
                return .{ .size = i.size, .is_dir = i.isDir(), .is_regular = i.isRegular(), .impl = .{ .ext4 = i } };
            },
            .btrfs => |*f| {
                const i = try f.lookup(path);
                return .{ .size = i.size, .is_dir = i.isDir(), .is_regular = i.isRegular(), .impl = .{ .btrfs = i } };
            },
            .iso9660 => |*f| {
                const i = try f.lookup(path);
                return .{ .size = i.size, .is_dir = i.is_dir, .is_regular = !i.is_dir and !i.is_symlink, .impl = .{ .iso9660 = i } };
            },
            .fat => |*f| {
                const i = try f.lookup(path);
                return .{ .size = i.size, .is_dir = i.is_dir, .is_regular = !i.is_dir, .impl = .{ .fat = i } };
            },
        }
    }

    /// Reads up to `buf.len` bytes at `offset`; returns the count (short only
    /// at end of file).
    pub fn readAt(self: *Fs, file: *const File, offset: u64, buf: []u8) Error!usize {
        return switch (self.*) {
            .ext4 => |*f| f.readAt(&file.impl.ext4, offset, buf),
            .btrfs => |*f| f.readAt(&file.impl.btrfs, offset, buf),
            .iso9660 => |*f| f.readAt(&file.impl.iso9660, offset, buf),
            .fat => |*f| f.readAt(&file.impl.fat, offset, buf),
        };
    }
};
