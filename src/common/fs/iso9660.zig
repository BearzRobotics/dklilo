//! Read-only ISO 9660 reader with Rock Ridge (long names, symlinks).
//!
//! Enough to boot from a DVD or a hybrid ISO written to a USB stick: the
//! primary volume descriptor, directory records, Rock Ridge `NM` (names), `SL`
//! (symlinks) and `CE` (continuation areas). Joliet, UDF, multi-extent files
//! and interleaved files are not supported.
//!
//! Specification: ECMA-119; Rock Ridge: IEEE P1282 / SUSP (IEEE P1281).

const std = @import("std");
const blockdev = @import("../blockdev.zig");

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
} || blockdev.Error;

/// ISO 9660 logical block size (2048 on every medium dklilo reads).
pub const block_size = 2048;
const max_symlinks = 8;

pub const Inode = struct {
    /// First logical block and byte length of the file's data.
    extent: u32,
    size: u64,
    is_dir: bool,
    is_symlink: bool,
    /// Rock Ridge symlink target (when `is_symlink`).
    link: [240]u8 = undefined,
    link_len: u8 = 0,
};

pub const Fs = struct {
    allocator: std.mem.Allocator,
    region: blockdev.Region,
    root: Inode,
    label_buf: [32]u8,
    label_len: usize,
    /// Directory sector, and a second one for Rock Ridge continuation areas.
    sector: []u8,
    cont: []u8,

    pub fn open(allocator: std.mem.Allocator, region: blockdev.Region) Error!Fs {
        var pvd: [block_size]u8 = undefined;
        // Volume descriptors start at logical block 16; type 1 is the primary.
        var n: u32 = 16;
        while (true) : (n += 1) {
            if (n > 40) return error.BadMagic;
            region.readAt(@as(u64, n) * block_size, &pvd) catch return error.BadMagic;
            if (!std.mem.eql(u8, pvd[1..6], "CD001")) return error.BadMagic;
            if (pvd[0] == 1) break;
            if (pvd[0] == 255) return error.BadMagic;
        }
        if (pvd[6] != 1) return error.Unsupported;
        const lbs = std.mem.readInt(u16, pvd[128..130], .little);
        if (lbs != block_size) return error.Unsupported;

        const root_rec = pvd[156..190];
        var self = Fs{
            .allocator = allocator,
            .region = region,
            .root = .{
                .extent = std.mem.readInt(u32, root_rec[2..6], .little),
                .size = std.mem.readInt(u32, root_rec[10..14], .little),
                .is_dir = true,
                .is_symlink = false,
            },
            .label_buf = undefined,
            .label_len = 0,
            .sector = &.{},
            .cont = &.{},
        };
        @memcpy(&self.label_buf, pvd[40..72]);
        var l: usize = 32;
        while (l > 0 and (self.label_buf[l - 1] == ' ' or self.label_buf[l - 1] == 0)) l -= 1;
        self.label_len = l;
        self.sector = try allocator.alloc(u8, block_size);
        errdefer allocator.free(self.sector);
        self.cont = try allocator.alloc(u8, block_size);
        return self;
    }

    pub fn deinit(self: *Fs) void {
        self.allocator.free(self.sector);
        self.allocator.free(self.cont);
    }

    pub fn label(self: *const Fs) []const u8 {
        return self.label_buf[0..self.label_len];
    }

    /// ISO 9660 has no UUID worth matching; volumes are named by label.
    pub fn uuid(self: *const Fs) [16]u8 {
        _ = self;
        return std.mem.zeroes([16]u8);
    }

    // ---- Rock Ridge -----------------------------------------------------

    const Entry = struct {
        inode: Inode,
        name: [255]u8 = undefined,
        name_len: usize = 0,
        has_rr_name: bool = false,
    };

    /// Decodes one directory record at `rec` (whose system-use area may point
    /// to a continuation area read into `self.cont`).
    fn decode(self: *Fs, rec: []const u8) Error!Entry {
        const len: usize = rec[0];
        if (len < 34 or len > rec.len) return error.Corrupt;
        const name_len: usize = rec[32];
        if (33 + name_len > len) return error.Corrupt;
        const flags = rec[25];
        if (flags & 0x80 != 0) return error.Unsupported; // multi-extent file

        var e = Entry{ .inode = .{
            .extent = std.mem.readInt(u32, rec[2..6], .little),
            .size = std.mem.readInt(u32, rec[10..14], .little),
            .is_dir = flags & 2 != 0,
            .is_symlink = false,
        } };

        // Plain ISO name: drop the ";1" version and a trailing dot.
        const raw = rec[33..][0..name_len];
        var base = raw;
        if (std.mem.indexOfScalar(u8, base, ';')) |semi| base = base[0..semi];
        if (base.len > 0 and base[base.len - 1] == '.') base = base[0 .. base.len - 1];
        if (name_len == 1 and raw[0] == 0) base = ".";
        if (name_len == 1 and raw[0] == 1) base = "..";
        @memcpy(e.name[0..base.len], base);
        e.name_len = base.len;

        // System use area follows the name (padded to an even offset).
        var su_start = 33 + name_len;
        if (name_len % 2 == 0) su_start += 1;
        if (su_start < len) try self.parseSystemUse(&e, rec[su_start..len], 0);
        return e;
    }

    fn parseSystemUse(self: *Fs, e: *Entry, area: []const u8, depth: u32) Error!void {
        if (depth > 4) return error.Corrupt;
        var p: usize = 0;
        var name_done = false;
        while (p + 4 <= area.len) {
            const sig = area[p..][0..2];
            const elen: usize = area[p + 2];
            if (elen < 4 or p + elen > area.len) break;
            const body = area[p..][0..elen];
            if (std.mem.eql(u8, sig, "NM") and elen >= 5) {
                const nflags = body[4];
                if (!name_done) {
                    // Start of a (possibly continued) name replaces the ISO name.
                    if (!e.has_rr_name) e.name_len = 0;
                    e.has_rr_name = true;
                    name_done = true;
                }
                if (nflags & 0x02 != 0) {
                    e.name[0] = '.';
                    e.name_len = 1;
                } else if (nflags & 0x04 != 0) {
                    e.name[0] = '.';
                    e.name[1] = '.';
                    e.name_len = 2;
                } else {
                    const part = body[5..];
                    if (e.name_len + part.len > e.name.len) return error.NameTooLong;
                    @memcpy(e.name[e.name_len..][0..part.len], part);
                    e.name_len += part.len;
                }
                if (nflags & 0x01 == 0) name_done = false; // name complete
                if (nflags & 0x01 == 0) e.has_rr_name = true;
            } else if (std.mem.eql(u8, sig, "SL") and elen >= 5) {
                e.inode.is_symlink = true;
                try appendLink(&e.inode, body[5..]);
            } else if (std.mem.eql(u8, sig, "CE") and elen >= 28) {
                const blk = std.mem.readInt(u32, body[4..8], .little);
                const off = std.mem.readInt(u32, body[12..16], .little);
                const clen = std.mem.readInt(u32, body[20..24], .little);
                if (off > block_size or clen > block_size - off) return error.Corrupt;
                try self.region.readAt(@as(u64, blk) * block_size, self.cont);
                // Parse a private copy: recursion would overwrite `cont`.
                var tmp: [block_size]u8 = undefined;
                @memcpy(tmp[0..clen], self.cont[off..][0..clen]);
                try self.parseSystemUse(e, tmp[0..clen], depth + 1);
            }
            p += elen;
        }
    }

    /// Appends the components of one `SL` record to the link target.
    fn appendLink(ino: *Inode, comps: []const u8) Error!void {
        var p: usize = 0;
        while (p + 2 <= comps.len) {
            const cflags = comps[p];
            const clen: usize = comps[p + 1];
            if (p + 2 + clen > comps.len) return error.Corrupt;
            const text = comps[p + 2 ..][0..clen];
            var add: []const u8 = text;
            if (cflags & 0x02 != 0) add = "." else if (cflags & 0x04 != 0) add = ".." else if (cflags & 0x08 != 0) add = "";
            // Separate components with '/', but not after a leading root.
            if (ino.link_len > 0 and ino.link[ino.link_len - 1] != '/' and !(cflags & 0x08 != 0 and add.len == 0)) {
                if (ino.link_len >= ino.link.len) return error.NameTooLong;
                ino.link[ino.link_len] = '/';
                ino.link_len += 1;
            }
            if (cflags & 0x08 != 0 and ino.link_len == 0) {
                ino.link[0] = '/';
                ino.link_len = 1;
            }
            if (ino.link_len + add.len > ino.link.len) return error.NameTooLong;
            @memcpy(ino.link[ino.link_len..][0..add.len], add);
            ino.link_len += @intCast(add.len);
            p += 2 + clen;
        }
    }

    // ---- directories ----------------------------------------------------

    pub const DirEntry = struct { name: []const u8, inode: Inode };

    /// Calls `cb(ctx, entry)` for each entry of `dir` (".", ".." included),
    /// stopping when it returns true. The callback must not call into `Fs`.
    pub fn walkDir(self: *Fs, dir: *const Inode, ctx: anytype, comptime cb: anytype) Error!void {
        if (!dir.is_dir) return error.NotDirectory;
        var pos: u64 = 0;
        while (pos < dir.size) {
            const sec_off = @as(u64, dir.extent) * block_size + pos;
            try self.region.readAt(sec_off, self.sector);
            var p: usize = 0;
            const in_sector = @min(block_size, dir.size - pos);
            while (p < in_sector) {
                const len: usize = self.sector[p];
                if (len == 0) break; // padding to the end of the sector
                if (p + len > block_size) return error.Corrupt;
                // `decode` may read a continuation sector into `cont`, never
                // into `sector`, so `rec` stays valid.
                var rec: [block_size]u8 = undefined;
                @memcpy(rec[0..len], self.sector[p..][0..len]);
                const e = try self.decode(rec[0..len]);
                if (cb(ctx, DirEntry{ .name = e.name[0..e.name_len], .inode = e.inode })) return;
                p += len;
            }
            pos += block_size;
        }
    }

    const Find = struct { name: []const u8, found: ?Inode = null };
    fn findCb(f: *Find, e: DirEntry) bool {
        if (std.mem.eql(u8, e.name, f.name) or std.ascii.eqlIgnoreCase(e.name, f.name)) {
            f.found = e.inode;
            return true;
        }
        return false;
    }

    pub fn lookupIn(self: *Fs, dir: *const Inode, name: []const u8) Error!Inode {
        var f = Find{ .name = name };
        try self.walkDir(dir, &f, findCb);
        return f.found orelse error.NotFound;
    }

    pub fn lookup(self: *Fs, path: []const u8) Error!Inode {
        var links: u32 = 0;
        return self.resolveFrom(self.root, self.root, path, &links);
    }

    fn resolveFrom(self: *Fs, top: Inode, start: Inode, path: []const u8, links: *u32) Error!Inode {
        var cur = start;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |comp| {
            if (comp.len > 255) return error.NameTooLong;
            if (!cur.is_dir) return error.NotDirectory;
            if (std.mem.eql(u8, comp, ".")) continue;
            const next = try self.lookupIn(&cur, comp);
            if (!next.is_symlink) {
                cur = next;
                continue;
            }
            links.* += 1;
            if (links.* > max_symlinks) return error.TooManyLinks;
            const target = next.link[0..next.link_len];
            const base = if (target.len > 0 and target[0] == '/') top else cur;
            cur = try self.resolveFrom(top, base, target, links);
        }
        return cur;
    }

    /// Reads up to `buf.len` bytes of the file at `offset`.
    pub fn readAt(self: *Fs, ino: *const Inode, offset: u64, buf: []u8) Error!usize {
        if (ino.is_dir) return error.IsDirectory;
        if (offset >= ino.size) return 0;
        const n: usize = @intCast(@min(@as(u64, buf.len), ino.size - offset));
        try self.region.readAt(@as(u64, ino.extent) * block_size + offset, buf[0..n]);
        return n;
    }
};

/// Quick check used when scanning disks: is there an ISO 9660 volume
/// descriptor at logical block 16 of `region`?
pub fn isIso(region: blockdev.Region) bool {
    var d: [8]u8 = undefined;
    region.readAt(16 * block_size, &d) catch return false;
    return std.mem.eql(u8, d[1..6], "CD001");
}
