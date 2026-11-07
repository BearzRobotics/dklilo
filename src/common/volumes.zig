//! The set of filesystems dklilo can see: every partition of every disk
//! (or a whole disk with no partition table), identified the way the
//! configuration names them: by `LABEL=`, `UUID=` or `PARTUUID=` prefix.
//! Shared by the BIOS and UEFI loaders and by the Linux tool.

const std = @import("std");
const blockdev = @import("blockdev.zig");
const part = @import("part.zig");
const devio = @import("devio.zig");
const fsread = @import("fsread");
const fs_mod = fsread.fs;
const iso9660 = fsread.iso9660;

pub const Error = error{
    /// A path prefix names a volume that isn't there.
    NoSuchVolume,
    /// The volume has no filesystem dklilo can read.
    NoFilesystem,
} || fs_mod.Error;

pub const Volume = struct {
    region: blockdev.Region,
    /// The device `region` is on. Must stay at a fixed address: the
    /// filesystem reader's `Io` points at it.
    dev: *const blockdev.BlockDev,
    /// Which disk this volume is on, in the order disks were added.
    disk: usize,
    /// 1-based partition number, or 0 for a whole-disk filesystem.
    number: u8,
    /// GPT unique partition GUID (on-disk byte order), if from a GPT disk.
    part_guid: ?[16]u8 = null,
    /// MBR disk signature, if from an MBR disk.
    mbr_signature: ?u32 = null,
    /// MBR partition type byte and active flag (0/false on GPT).
    mbr_type: u8 = 0,
    bootable: bool = false,
    state: enum { unprobed, open, none } = .unprobed,
    fs: fs_mod.Fs = undefined,

    /// Does the volume start with an NTFS boot sector ("NTFS    " OEM id and
    /// the 0x55AA signature)?
    pub fn hasNtfsBootSector(v: *const Volume) bool {
        var sec: [512]u8 = undefined;
        v.region.readAt(0, &sec) catch return false;
        return std.mem.eql(u8, sec[3..11], "NTFS    ") and sec[510] == 0x55 and sec[511] == 0xAA;
    }

    /// The filesystem on this volume, or null if it has none we can read.
    pub fn filesystem(self: *Volume, allocator: std.mem.Allocator) ?*fs_mod.Fs {
        switch (self.state) {
            .open => return &self.fs,
            .none => return null,
            .unprobed => {
                if (fs_mod.Fs.open(allocator, devio.fromRegion(self.dev, self.region))) |fs| {
                    self.fs = fs;
                    self.state = .open;
                    return &self.fs;
                } else |_| {
                    self.state = .none;
                    return null;
                }
            },
        }
    }
};

/// A file inside a filesystem presented as a block device, so a filesystem
/// image stored as a file (a loopback ISO) can be read in place.
const FileDev = struct {
    fs: *fs_mod.Fs,
    file: fs_mod.File,

    const sector = 2048;

    fn blockDev(self: *FileDev) blockdev.BlockDev {
        return .{
            .ctx = self,
            .readSectorsFn = read,
            .sector_size = sector,
            .sector_count = self.file.size / sector,
        };
    }

    fn read(ctx: *anyopaque, lba: u64, buf: []u8) blockdev.Error!void {
        const self: *FileDev = @ptrCast(@alignCast(ctx));
        const n = self.fs.readAt(&self.file, lba * sector, buf) catch return error.IoError;
        if (n != buf.len) return error.IoError;
    }
};

/// A mounted loopback image: the file, and a volume over it.
const Mount = struct {
    spec: []u8,
    subvol: ?[]u8,
    dev: FileDev,
    /// `dev` as a block device; `vol` reads through it.
    bd: blockdev.BlockDev,
    vol: Volume,
};

pub const Set = struct {
    allocator: std.mem.Allocator,
    vols: std.ArrayList(Volume) = .empty,
    disks: usize = 0,
    mounts: std.ArrayList(*Mount) = .empty,
    /// Copies of the disks added, at stable addresses for volumes to point at.
    devs: std.ArrayList(*blockdev.BlockDev) = .empty,

    pub fn init(allocator: std.mem.Allocator) Set {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Set) void {
        for (self.mounts.items) |m| {
            if (m.vol.state == .open) m.vol.fs.deinit();
            self.allocator.free(m.spec);
            if (m.subvol) |sv| self.allocator.free(sv);
            self.allocator.destroy(m);
        }
        self.mounts.deinit(self.allocator);
        for (self.devs.items) |d| self.allocator.destroy(d);
        self.devs.deinit(self.allocator);
        for (self.vols.items) |*v| if (v.state == .open) v.fs.deinit();
        self.vols.deinit(self.allocator);
    }

    /// Adds the partitions of `dev`. A disk with no partition table counts as
    /// one whole-disk volume (CD images, "superfloppies"). Returns the disk's
    /// index.
    pub fn addDisk(self: *Set, disk_dev: blockdev.BlockDev) std.mem.Allocator.Error!usize {
        const dp = try self.allocator.create(blockdev.BlockDev);
        errdefer self.allocator.destroy(dp);
        dp.* = disk_dev;
        try self.devs.append(self.allocator, dp);
        const dev = dp.*;
        const disk = self.disks;
        self.disks += 1;
        // An ISO 9660 volume (a DVD, or a hybrid ISO written to a stick) is
        // the whole device. On optical media (2048-byte sectors) that is all
        // there is; on a hybrid disk the partitions follow below.
        if (iso9660.isIso(devio.fromRegion(dp, dev.whole()))) {
            try self.vols.append(self.allocator, .{ .region = dev.whole(), .dev = dp, .disk = disk, .number = 0 });
            if (dev.sector_size >= 2048) return disk;
        }
        const table = part.read(dev) catch {
            if (self.vols.items.len > 0 and self.vols.items[self.vols.items.len - 1].disk == disk) return disk;
            try self.vols.append(self.allocator, .{ .region = dev.whole(), .dev = dp, .disk = disk, .number = 0 });
            return disk;
        };
        for (table.slice()) |p| {
            // The extended container itself holds no filesystem.
            if (table.kind == .mbr and (p.mbr_type == 0x05 or p.mbr_type == 0x0F or p.mbr_type == 0x85)) continue;
            try self.vols.append(self.allocator, .{
                .region = p.region(dev),
                .dev = dp,
                .disk = disk,
                .number = p.number,
                .part_guid = if (table.kind == .gpt) p.part_guid else null,
                .mbr_signature = if (table.kind == .mbr) table.disk_signature else null,
                .mbr_type = p.mbr_type,
                .bootable = p.bootable,
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
        formatUuid(fs.uuid(), &s);
        return std.ascii.eqlIgnoreCase(&s, value);
    }

    /// Finds `dklilo.conf`. The EFI System Partition's `\EFI\dklilo\dklilo.conf`
    /// wins; otherwise each volume is tried for `/boot/dklilo.conf` then
    /// `/dklilo.conf`. `disk` limits the search to one disk (the boot disk).
    pub fn findConfig(self: *Set, disk: ?usize) ?struct { vol: *Volume, path: []const u8 } {
        const esp_path = "/EFI/dklilo/dklilo.conf";
        for (self.vols.items) |*v| {
            if (disk) |d| if (v.disk != d) continue;
            const fs = v.filesystem(self.allocator) orelse continue;
            if (fs.* != .fat) continue;
            const ino = fs.lookup(esp_path) catch continue;
            if (ino.is_regular) return .{ .vol = v, .path = esp_path };
        }
        const paths = [_][]const u8{ "/boot/dklilo.conf", "/dklilo.conf" };
        for (self.vols.items) |*v| {
            if (disk) |d| if (v.disk != d) continue;
            const fs = v.filesystem(self.allocator) orelse continue;
            for (paths) |p| {
                const ino = fs.lookup(p) catch continue;
                if (ino.is_regular) return .{ .vol = v, .path = p };
            }
        }
        return null;
    }

    /// The partition to chainload for `other = windows` on BIOS: an NTFS
    /// partition on `disk`, preferring the active one (Windows' boot partition
    /// is normally active) and otherwise the first.
    pub fn findWindowsBoot(self: *Set, disk: usize) ?*Volume {
        var first: ?*Volume = null;
        for (self.vols.items) |*v| {
            if (v.disk != disk or v.number == 0 or !v.hasNtfsBootSector()) continue;
            if (v.bootable) return v;
            if (first == null) first = v;
        }
        return first;
    }

    /// The volume numbered `number` (as Linux numbers partitions) on `disk`.
    pub fn findPartition(self: *Set, disk: usize, number: u8) ?*Volume {
        for (self.vols.items) |*v| if (v.disk == disk and v.number == number) return v;
        return null;
    }

    /// Mounts the ISO file named by `spec` (a path on `default`, or with a
    /// volume prefix) and returns a volume to read the kernel and initramfs
    /// from. Mounting the same file twice returns the same volume.
    pub fn isoVolume(self: *Set, default: *Volume, spec: []const u8, subvol: ?[]const u8) Error!*Volume {
        for (self.mounts.items) |m| {
            const same_sub = if (m.subvol) |a| (subvol != null and std.mem.eql(u8, a, subvol.?)) else subvol == null;
            if (same_sub and std.mem.eql(u8, m.spec, spec)) return &m.vol;
        }
        const o = try self.openFile(default, spec, subvol);
        const m = try self.allocator.create(Mount);
        errdefer self.allocator.destroy(m);
        m.spec = try self.allocator.dupe(u8, spec);
        errdefer self.allocator.free(m.spec);
        m.subvol = if (subvol) |sv| try self.allocator.dupe(u8, sv) else null;
        m.dev = .{ .fs = o.fs, .file = o.file };
        m.bd = m.dev.blockDev();
        m.vol = .{ .region = m.bd.whole(), .dev = &m.bd, .disk = std.math.maxInt(usize), .number = 0 };
        if (!iso9660.isIso(devio.fromRegion(&m.bd, m.bd.whole()))) {
            if (m.subvol) |sv| self.allocator.free(sv);
            return error.NoFilesystem;
        }
        try self.mounts.append(self.allocator, m);
        return &m.vol;
    }

    pub const Opened = struct { fs: *fs_mod.Fs, file: fs_mod.File };

    /// Resolves a config path (with optional `LABEL=`/`UUID=`/`PARTUUID=`
    /// prefix) to an open file. `subvol` selects a btrfs subvolume first (null
    /// for the default one); it is only meaningful for btrfs volumes.
    pub fn openFile(self: *Set, default: *Volume, spec: []const u8, subvol: ?[]const u8) Error!Opened {
        const at = try self.resolve(spec, default);
        const fs = at.vol.filesystem(self.allocator) orelse return error.NoFilesystem;
        try fs.selectSubvolume(subvol);
        const file = try fs.lookup(at.path);
        if (file.is_dir) return error.IsDirectory;
        return .{ .fs = fs, .file = file };
    }

    /// Reads a whole file into memory owned by the caller.
    pub fn readFile(self: *Set, vol: *Volume, path: []const u8) Error![]u8 {
        return self.readSpec(vol, path, null);
    }

    /// Like `readFile`, for a config path with an optional subvolume.
    pub fn readSpec(self: *Set, default: *Volume, spec: []const u8, subvol: ?[]const u8) Error![]u8 {
        var o = try self.openFile(default, spec, subvol);
        const buf = try self.allocator.alloc(u8, @intCast(o.file.size));
        errdefer self.allocator.free(buf);
        const n = try o.fs.readAt(&o.file, 0, buf);
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
    formatUuid(def.filesystem(std.testing.allocator).?.uuid(), &u);
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

test "Windows boot partition: the active NTFS boot sector wins" {
    const copy = try std.testing.allocator.dupe(u8, @embedFile("mbr.img"));
    defer std.testing.allocator.free(copy);
    // Partition 2 (LBA 10240) and 3 (LBA 18432) get NTFS boot sectors; the
    // active partition is 1, which has none, so the first NTFS one is used.
    for ([_]usize{ 10240, 18432 }) |lba| {
        const sec = copy[lba * 512 ..][0..512];
        @memcpy(sec[3..11], "NTFS    ");
        sec[510] = 0x55;
        sec[511] = 0xAA;
    }
    var d = blockdev.MemDisk{ .data = copy };
    var set = Set.init(std.testing.allocator);
    defer set.deinit();
    const disk = try set.addDisk(d.blockDev());
    try std.testing.expectEqual(@as(u8, 2), set.findWindowsBoot(disk).?.number);
    try std.testing.expectEqual(@as(u8, 3), set.findPartition(disk, 3).?.number);
    try std.testing.expect(set.findPartition(disk, 9) == null);
    // Make partition 3 active: it should win now.
    set.vols.items[2].bootable = true;
    try std.testing.expectEqual(@as(u8, 3), set.findWindowsBoot(disk).?.number);
}

test "an ISO file inside an ext4 image is mounted in place" {
    var d = blockdev.MemDisk{ .data = @embedFile("ext4.img") };
    var set = Set.init(std.testing.allocator);
    defer set.deinit();
    _ = try set.addDisk(d.blockDev());
    const host = &set.vols.items[0];

    const iso = try set.isoVolume(host, "/isos/nested.iso", null);
    const data = try set.readSpec(iso, "/hello.txt", null);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("nested iso\n", data);
    // Mounting the same file again reuses the mount.
    try std.testing.expect(iso == try set.isoVolume(host, "/isos/nested.iso", null));
    // A file that is not an ISO is refused.
    try std.testing.expectError(error.NoFilesystem, set.isoVolume(host, "/boot/hello.txt", null));
    try std.testing.expectError(error.NotFound, set.isoVolume(host, "/isos/missing.iso", null));
}
