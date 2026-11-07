//! Read-only FAT12/16/32 reader with long file names (VFAT).
//!
//! Needed for the EFI System Partition: the configuration may live in
//! `\EFI\dklilo\dklilo.conf`. Names are compared case-insensitively (ASCII),
//! as FAT does.
//!
//! Specification: Microsoft "FAT: General Overview of On-Disk Format".

const std = @import("std");
const region_mod = @import("region.zig");

pub const Error = error{
    BadMagic,
    Unsupported,
    Corrupt,
    NotFound,
    NotDirectory,
    IsDirectory,
    NameTooLong,
    TooManyLinks,
    OutOfMemory,
} || region_mod.Error;

pub const Kind = enum { fat12, fat16, fat32 };

pub const Inode = struct {
    /// First cluster of the data (0 for an empty file and for the fixed root
    /// directory of FAT12/16).
    cluster: u32,
    size: u32,
    is_dir: bool,
    is_root: bool = false,
};

pub const DirEntry = struct {
    name: []const u8,
    inode: Inode,
};

const attr_volume_id = 0x08;
const attr_directory = 0x10;
const attr_lfn = 0x0F;

pub const Fs = struct {
    allocator: std.mem.Allocator,
    region: region_mod.Region,
    kind: Kind,
    bytes_per_sector: u32,
    cluster_size: u32,
    fat_start: u64, // byte offset
    root_start: u64, // byte offset of the fixed root (FAT12/16)
    root_bytes: u32,
    data_start: u64,
    root_cluster: u32, // FAT32
    cluster_count: u32,
    serial: u32,
    label_buf: [11]u8,
    /// Directory sector buffer and a one-sector FAT cache.
    dir_buf: []u8,
    fat_buf: []u8,
    fat_sector: u64 = std.math.maxInt(u64),

    pub fn open(allocator: std.mem.Allocator, region: region_mod.Region) Error!Fs {
        var bs: [512]u8 = undefined;
        region.readAt(0, &bs) catch return error.BadMagic;
        if (bs[510] != 0x55 or bs[511] != 0xAA) return error.BadMagic;
        const bps = std.mem.readInt(u16, bs[11..13], .little);
        const spc = bs[13];
        const reserved = std.mem.readInt(u16, bs[14..16], .little);
        const nfats = bs[16];
        const root_entries = std.mem.readInt(u16, bs[17..19], .little);
        var total: u32 = std.mem.readInt(u16, bs[19..21], .little);
        if (total == 0) total = std.mem.readInt(u32, bs[32..36], .little);
        var fat_size: u32 = std.mem.readInt(u16, bs[22..24], .little);
        const is32_layout = fat_size == 0;
        if (is32_layout) fat_size = std.mem.readInt(u32, bs[36..40], .little);

        // A FAT boot sector has sane geometry; anything else is not FAT.
        if (bps < 512 or bps > 4096 or !std.math.isPowerOfTwo(bps)) return error.BadMagic;
        if (spc == 0 or !std.math.isPowerOfTwo(spc)) return error.BadMagic;
        if (reserved == 0 or nfats == 0 or nfats > 2 or fat_size == 0 or total == 0) return error.BadMagic;

        const root_sectors: u32 = (@as(u32, root_entries) * 32 + bps - 1) / bps;
        const data_sectors = total -| (reserved + @as(u32, nfats) * fat_size + root_sectors);
        const count = data_sectors / spc;
        const kind: Kind = if (count < 4085) .fat12 else if (count < 65525) .fat16 else .fat32;
        if ((kind == .fat32) != is32_layout) return error.BadMagic;

        const dir_buf = try allocator.alloc(u8, bps);
        errdefer allocator.free(dir_buf);
        const fat_buf = try allocator.alloc(u8, bps);

        var self = Fs{
            .allocator = allocator,
            .region = region,
            .kind = kind,
            .bytes_per_sector = bps,
            .cluster_size = @as(u32, spc) * bps,
            .fat_start = @as(u64, reserved) * bps,
            .root_start = (@as(u64, reserved) + @as(u64, nfats) * fat_size) * bps,
            .root_bytes = root_sectors * bps,
            .data_start = (@as(u64, reserved) + @as(u64, nfats) * fat_size + root_sectors) * bps,
            .root_cluster = if (kind == .fat32) std.mem.readInt(u32, bs[44..48], .little) else 0,
            .cluster_count = count,
            .serial = std.mem.readInt(u32, bs[if (kind == .fat32) 67 else 39..][0..4], .little),
            .label_buf = undefined,
            .dir_buf = dir_buf,
            .fat_buf = fat_buf,
        };
        @memcpy(&self.label_buf, bs[if (kind == .fat32) 71 else 43..][0..11]);
        return self;
    }

    pub fn deinit(self: *Fs) void {
        self.allocator.free(self.dir_buf);
        self.allocator.free(self.fat_buf);
    }

    pub fn label(self: *const Fs) []const u8 {
        var n: usize = 11;
        while (n > 0 and self.label_buf[n - 1] == ' ') n -= 1;
        return self.label_buf[0..n];
    }

    /// The volume serial number in the first four bytes (FAT has no UUID).
    pub fn uuid(self: *const Fs) [16]u8 {
        var u = std.mem.zeroes([16]u8);
        std.mem.writeInt(u32, u[0..4], self.serial, .little);
        return u;
    }

    // ---- the allocation table ---------------------------------------------

    /// The cluster after `c` in its chain, or null at the end.
    fn next(self: *Fs, c: u32) Error!?u32 {
        if (c < 2 or c >= self.cluster_count + 2) return error.Corrupt;
        const entry_bytes: u64 = switch (self.kind) {
            .fat12 => @as(u64, c) + c / 2,
            .fat16 => @as(u64, c) * 2,
            .fat32 => @as(u64, c) * 4,
        };
        // Read the sector holding the entry (and the next one when a FAT12
        // entry straddles the boundary) through the one-sector cache.
        const sec = entry_bytes / self.bytes_per_sector;
        const off: usize = @intCast(entry_bytes % self.bytes_per_sector);
        const v: u32 = switch (self.kind) {
            .fat12 => blk: {
                const lo = try self.fatByte(sec, off);
                const hi = if (off + 1 < self.bytes_per_sector) try self.fatByte(sec, off + 1) else try self.fatByte(sec + 1, 0);
                const raw = @as(u32, lo) | (@as(u32, hi) << 8);
                break :blk if (c & 1 != 0) raw >> 4 else raw & 0xFFF;
            },
            .fat16 => @as(u32, try self.fatByte(sec, off)) | (@as(u32, try self.fatByte(sec, off + 1)) << 8),
            .fat32 => blk: {
                var x: u32 = 0;
                for (0..4) |i| x |= @as(u32, try self.fatByte(sec, off + i)) << @intCast(8 * i);
                break :blk x & 0x0FFFFFFF;
            },
        };
        const end: u32 = switch (self.kind) {
            .fat12 => 0xFF8,
            .fat16 => 0xFFF8,
            .fat32 => 0x0FFFFFF8,
        };
        if (v >= end) return null;
        if (v < 2 or v >= self.cluster_count + 2) return error.Corrupt; // free or bad cluster mid-chain
        return v;
    }

    fn fatByte(self: *Fs, sector: u64, off: usize) Error!u8 {
        if (self.fat_sector != sector) {
            try self.region.readAt(self.fat_start + sector * self.bytes_per_sector, self.fat_buf);
            self.fat_sector = sector;
        }
        return self.fat_buf[off];
    }

    fn clusterOffset(self: *const Fs, c: u32) u64 {
        return self.data_start + @as(u64, c - 2) * self.cluster_size;
    }

    // ---- directories ------------------------------------------------------

    /// Walks the 32-byte entries of a directory, assembling long names.
    const Iter = struct {
        fs: *Fs,
        cluster: u32,
        root_fixed: bool,
        /// Byte position within the directory (fixed root) or cluster.
        pos: u64 = 0,
        /// Sector within the current cluster, and the one loaded in dir_buf.
        loaded: bool = false,
        sector_idx: u64 = 0,
        slot: usize = 0,
        done: bool = false,
        // Long-name assembly.
        lfn: [20 * 13]u16 = undefined,
        lfn_expect: u8 = 0,
        lfn_sum: u8 = 0,
        name: [256]u8 = undefined,

        fn init(fs: *Fs, dir: Inode) Iter {
            return .{ .fs = fs, .cluster = dir.cluster, .root_fixed = dir.is_root and fs.kind != .fat32 };
        }

        /// Loads the sector holding the current position.
        fn load(it: *Iter) Error!bool {
            const fs = it.fs;
            if (it.root_fixed) {
                if (it.pos >= fs.root_bytes) return false;
                try fs.region.readAt(fs.root_start + it.pos, fs.dir_buf);
                return true;
            }
            if (it.cluster == 0) return false;
            const within = it.pos % fs.cluster_size;
            if (it.pos != 0 and within == 0) {
                it.cluster = (try fs.next(it.cluster)) orelse return false;
            }
            try fs.region.readAt(fs.clusterOffset(it.cluster) + within, fs.dir_buf);
            return true;
        }

        const Item = struct { name: []const u8, inode: Inode };

        fn nextEntry(it: *Iter) Error!?Item {
            const fs = it.fs;
            while (!it.done) {
                if (it.slot == 0) {
                    if (!try it.load()) {
                        it.done = true;
                        return null;
                    }
                }
                const e = fs.dir_buf[it.slot * 32 ..][0..32];
                it.slot += 1;
                if (it.slot * 32 >= fs.bytes_per_sector) {
                    it.slot = 0;
                    it.pos += fs.bytes_per_sector;
                    // `e` points into dir_buf, which the next load would overwrite,
                    // so copy what is needed from it before returning.
                }
                if (e[0] == 0) {
                    it.done = true;
                    return null;
                }
                if (e[0] == 0xE5) {
                    it.lfn_expect = 0;
                    continue;
                }
                const attr = e[11];
                if (attr & 0x3F == attr_lfn) {
                    const seq = e[0] & 0x1F;
                    if (e[0] & 0x40 != 0) {
                        it.lfn_expect = seq;
                        it.lfn_sum = e[13];
                        @memset(&it.lfn, 0xFFFF);
                    } else if (seq != it.lfn_expect -% 1 or e[13] != it.lfn_sum) {
                        it.lfn_expect = 0;
                        continue;
                    } else it.lfn_expect = seq;
                    if (seq == 0 or seq > 20) {
                        it.lfn_expect = 0;
                        continue;
                    }
                    const base = (@as(usize, seq) - 1) * 13;
                    const offs = [13]usize{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
                    for (offs, 0..) |o, i| it.lfn[base + i] = std.mem.readInt(u16, e[o..][0..2], .little);
                    continue;
                }
                if (attr & attr_volume_id != 0) {
                    it.lfn_expect = 0;
                    continue;
                }

                // A short entry; use the long name if its chain is complete
                // and its checksum matches.
                var name_len: usize = 0;
                if (it.lfn_expect == 1 and shortChecksum(e[0..11]) == it.lfn_sum) {
                    for (it.lfn) |ch| {
                        if (ch == 0 or ch == 0xFFFF) break;
                        name_len += encodeUtf8(ch, it.name[name_len..]) orelse return error.NameTooLong;
                    }
                } else {
                    name_len = shortName(e, &it.name);
                }
                it.lfn_expect = 0;

                const hi: u32 = if (fs.kind == .fat32) std.mem.readInt(u16, e[20..22], .little) else 0;
                const cluster = (hi << 16) | std.mem.readInt(u16, e[26..28], .little);
                const is_dir = attr & attr_directory != 0;
                return .{
                    .name = it.name[0..name_len],
                    .inode = .{
                        .cluster = cluster,
                        .size = if (is_dir) 0 else std.mem.readInt(u32, e[28..32], .little),
                        .is_dir = is_dir,
                        // ".." of a first-level directory points at cluster 0: the root.
                        .is_root = is_dir and cluster == 0,
                    },
                };
            }
            return null;
        }
    };

    fn shortChecksum(name: []const u8) u8 {
        var sum: u8 = 0;
        for (name[0..11]) |c| sum = ((sum & 1) << 7) +% (sum >> 1) +% c;
        return sum;
    }

    /// "NAME    EXT" -> "name.ext", honouring the NT lowercase flags.
    fn shortName(e: []const u8, out: *[256]u8) usize {
        var n: usize = 0;
        const base_lower = e[12] & 0x08 != 0;
        const ext_lower = e[12] & 0x10 != 0;
        var base_len: usize = 8;
        while (base_len > 0 and e[base_len - 1] == ' ') base_len -= 1;
        for (e[0..base_len], 0..) |c0, i| {
            var c = c0;
            if (i == 0 and c == 0x05) c = 0xE5; // 0xE5 is stored as 0x05
            out[n] = if (base_lower) std.ascii.toLower(c) else c;
            n += 1;
        }
        var ext_len: usize = 3;
        while (ext_len > 0 and e[8 + ext_len - 1] == ' ') ext_len -= 1;
        if (ext_len > 0) {
            out[n] = '.';
            n += 1;
            for (e[8..][0..ext_len]) |c| {
                out[n] = if (ext_lower) std.ascii.toLower(c) else c;
                n += 1;
            }
        }
        return n;
    }

    fn encodeUtf8(ch: u16, out: []u8) ?usize {
        if (ch < 0x80) {
            if (out.len < 1) return null;
            out[0] = @intCast(ch);
            return 1;
        }
        if (ch < 0x800) {
            if (out.len < 2) return null;
            out[0] = @intCast(0xC0 | (ch >> 6));
            out[1] = @intCast(0x80 | (ch & 0x3F));
            return 2;
        }
        if (out.len < 3) return null;
        if (ch >= 0xD800 and ch < 0xE000) { // lone surrogate: not representable
            out[0] = '?';
            return 1;
        }
        out[0] = @intCast(0xE0 | (ch >> 12));
        out[1] = @intCast(0x80 | ((ch >> 6) & 0x3F));
        out[2] = @intCast(0x80 | (ch & 0x3F));
        return 3;
    }

    pub fn root(self: *const Fs) Inode {
        return .{
            .cluster = self.root_cluster,
            .size = 0,
            .is_dir = true,
            .is_root = true,
        };
    }

    /// Calls `cb(ctx, entry)` for every entry (including "." and ".." where
    /// present), stopping early if it returns true. The callback must not
    /// call back into the `Fs`.
    pub fn walkDir(self: *Fs, dir: *const Inode, ctx: anytype, comptime cb: anytype) Error!void {
        if (!dir.is_dir) return error.NotDirectory;
        var it = Iter.init(self, dir.*);
        while (try it.nextEntry()) |item| {
            if (cb(ctx, DirEntry{ .name = item.name, .inode = item.inode })) return;
        }
    }

    const Find = struct { name: []const u8, found: ?Inode = null };
    fn findCb(f: *Find, e: DirEntry) bool {
        if (std.ascii.eqlIgnoreCase(e.name, f.name)) {
            f.found = e.inode;
            return true;
        }
        return false;
    }

    pub fn lookupIn(self: *Fs, dir: *const Inode, name: []const u8) Error!Inode {
        var f = Find{ .name = name };
        try self.walkDir(dir, &f, findCb);
        var ino = f.found orelse return error.NotFound;
        // ".." of a subdirectory of the root has cluster 0; resolve to the root.
        if (ino.is_dir and ino.cluster == 0) ino = self.root();
        return ino;
    }

    pub fn lookup(self: *Fs, path: []const u8) Error!Inode {
        var cur = self.root();
        var it = std.mem.tokenizeAny(u8, path, "/\\");
        while (it.next()) |comp| {
            if (comp.len > 255) return error.NameTooLong;
            if (!cur.is_dir) return error.NotDirectory;
            if (std.mem.eql(u8, comp, ".")) continue;
            cur = try self.lookupIn(&cur, comp);
        }
        return cur;
    }

    // ---- file contents ----------------------------------------------------

    /// Reads up to `buf.len` bytes of the file at `offset`, merging clusters
    /// that are adjacent on disk into single reads.
    pub fn readAt(self: *Fs, ino: *const Inode, offset: u64, buf: []u8) Error!usize {
        if (ino.is_dir) return error.IsDirectory;
        if (offset >= ino.size) return 0;
        const want: usize = @intCast(@min(@as(u64, buf.len), ino.size - offset));
        if (ino.cluster < 2) return error.Corrupt;

        // Skip to the cluster holding `offset`.
        var c = ino.cluster;
        var skip = offset / self.cluster_size;
        while (skip > 0) : (skip -= 1) c = (try self.next(c)) orelse return error.Corrupt;
        var in_cluster: u64 = offset % self.cluster_size;

        var done: usize = 0;
        while (done < want) {
            // Extend the run while the next cluster follows on disk.
            var run_end: u32 = c;
            var run_bytes: u64 = self.cluster_size - in_cluster;
            var after: ?u32 = try self.next(run_end);
            while (after != null and after.? == run_end + 1 and run_bytes < want - done) {
                run_end = after.?;
                run_bytes += self.cluster_size;
                after = try self.next(run_end);
            }
            const n: usize = @intCast(@min(run_bytes, @as(u64, want - done)));
            try self.region.readAt(self.clusterOffset(c) + in_cluster, buf[done..][0..n]);
            done += n;
            in_cluster = 0;
            if (done < want) c = after orelse return error.Corrupt;
        }
        return want;
    }
};
