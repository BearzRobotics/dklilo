//! Read-only btrfs reader.
//!
//! Supports the superblock and system chunk array, the chunk tree, the root
//! tree, subvolumes (including the default one and crossing into subvolumes
//! while resolving a path), inline and regular extents, sparse files, and zlib,
//! LZO and zstd compression. Chunk profiles: single, DUP, RAID1/1C3/1C4 (every
//! tree block is read from the first mirror whose checksum is good, falling
//! back to the others). RAID0/10/5/6 return `error.Unsupported`.
//!
//! Tree blocks are always checksum-verified. File *data* is not verified (the
//! checksum tree is not consulted), so a corrupt data copy is not detected.
//!
//! Callbacks given to `walkDir` must not call back into the `Fs`: tree walking
//! reuses per-level buffers.
//!
//! Specification: https://btrfs.readthedocs.io/en/latest/dev/On-disk-format.html

const std = @import("std");
const blockdev = @import("../blockdev.zig");
const crc = @import("../crc.zig");
const lzo = @import("../compress/lzo.zig");

pub const Error = error{
    BadMagic,
    Unsupported,
    Corrupt,
    ChecksumMismatch,
    NotFound,
    NotDirectory,
    IsDirectory,
    NameTooLong,
    TooManyLinks,
    OutOfMemory,
} || blockdev.Error;

/// Key identifying every item in every tree (17 bytes on disk).
pub const Key = extern struct {
    objectid: u64 align(1),
    kind: u8,
    offset: u64 align(1),

    fn make(objectid: u64, kind: u8, offset: u64) Key {
        return .{ .objectid = objectid, .kind = kind, .offset = offset };
    }
    fn order(a: Key, b: Key) std.math.Order {
        const o = std.math.order(a.objectid, b.objectid);
        if (o != .eq) return o;
        const t = std.math.order(a.kind, b.kind);
        if (t != .eq) return t;
        return std.math.order(a.offset, b.offset);
    }
};

/// `struct btrfs_super_block`, up to and including the system chunk array.
const Superblock = extern struct {
    csum: [32]u8,
    fsid: [16]u8,
    bytenr: u64 align(1),
    flags: u64 align(1),
    magic: [8]u8,
    generation: u64 align(1),
    root: u64 align(1),
    chunk_root: u64 align(1),
    log_root: u64 align(1),
    log_root_transid: u64 align(1),
    total_bytes: u64 align(1),
    bytes_used: u64 align(1),
    root_dir_objectid: u64 align(1),
    num_devices: u64 align(1),
    sectorsize: u32 align(1),
    nodesize: u32 align(1),
    leafsize: u32 align(1),
    stripesize: u32 align(1),
    sys_chunk_array_size: u32 align(1),
    chunk_root_generation: u64 align(1),
    compat_flags: u64 align(1),
    compat_ro_flags: u64 align(1),
    incompat_flags: u64 align(1),
    csum_type: u16 align(1),
    root_level: u8,
    chunk_root_level: u8,
    log_root_level: u8,
    dev_item: DevItem,
    label: [256]u8,
    cache_generation: u64 align(1),
    uuid_tree_generation: u64 align(1),
    metadata_uuid: [16]u8,
    nr_global_roots: u64 align(1),
    reserved: [216]u8,
    sys_chunk_array: [2048]u8,
};

const DevItem = extern struct {
    devid: u64 align(1),
    total_bytes: u64 align(1),
    bytes_used: u64 align(1),
    io_align: u32 align(1),
    io_width: u32 align(1),
    sector_size: u32 align(1),
    kind: u64 align(1),
    generation: u64 align(1),
    start_offset: u64 align(1),
    dev_group: u32 align(1),
    seek_speed: u8,
    bandwidth: u8,
    uuid: [16]u8,
    fsid: [16]u8,
};

/// `struct btrfs_header`, at the start of every tree block.
const NodeHeader = extern struct {
    csum: [32]u8,
    fsid: [16]u8,
    bytenr: u64 align(1),
    flags: u64 align(1),
    chunk_tree_uuid: [16]u8,
    generation: u64 align(1),
    owner: u64 align(1),
    nritems: u32 align(1),
    level: u8,
};

const Item = extern struct { key: Key, offset: u32 align(1), size: u32 align(1) };
const KeyPtr = extern struct { key: Key, blockptr: u64 align(1), generation: u64 align(1) };

const ChunkItem = extern struct {
    length: u64 align(1),
    owner: u64 align(1),
    stripe_len: u64 align(1),
    kind: u64 align(1),
    io_align: u32 align(1),
    io_width: u32 align(1),
    sector_size: u32 align(1),
    num_stripes: u16 align(1),
    sub_stripes: u16 align(1),
};
const StripeRaw = extern struct { devid: u64 align(1), offset: u64 align(1), dev_uuid: [16]u8 };

const DirItemHdr = extern struct {
    location: Key,
    transid: u64 align(1),
    data_len: u16 align(1),
    name_len: u16 align(1),
    kind: u8,
};

comptime {
    std.debug.assert(@sizeOf(Key) == 17);
    std.debug.assert(@sizeOf(DevItem) == 98);
    std.debug.assert(@sizeOf(Superblock) == 0xB2B);
    std.debug.assert(@sizeOf(NodeHeader) == 101);
    std.debug.assert(@sizeOf(Item) == 25);
    std.debug.assert(@sizeOf(KeyPtr) == 33);
    std.debug.assert(@sizeOf(ChunkItem) == 48);
    std.debug.assert(@sizeOf(StripeRaw) == 32);
    std.debug.assert(@sizeOf(DirItemHdr) == 30);
    std.debug.assert(@offsetOf(Superblock, "magic") == 0x40);
    std.debug.assert(@offsetOf(Superblock, "sectorsize") == 0x90);
    std.debug.assert(@offsetOf(Superblock, "label") == 0x12B);
    std.debug.assert(@offsetOf(Superblock, "sys_chunk_array") == 0x32B);
}

const sb_offset = 0x10000;
const magic = "_BHRfS_M";

// Key types.
const k_inode_item = 1;
const k_inode_ref = 12;
const k_dir_item = 84;
const k_dir_index = 96;
const k_extent_data = 108;
const k_root_item = 132;
const k_chunk_item = 228;

// Well-known objectids.
const root_tree_dir_objectid = 6;
const fs_tree_objectid = 5;
const chunk_tree_objectid = 3;
const first_free_objectid = 256;
const first_chunk_tree_objectid = 256;

// Chunk type flags.
const bg_raid0 = 0x08;
const bg_raid1 = 0x10;
const bg_dup = 0x20;
const bg_raid10 = 0x40;
const bg_raid5 = 0x80;
const bg_raid6 = 0x100;

const max_levels = 8;
const max_symlinks = 8;
const max_compressed_extent = 128 * 1024;

pub const mode_type_mask = 0o170000;
pub const mode_dir = 0o040000;
pub const mode_reg = 0o100000;
pub const mode_symlink = 0o120000;

pub const Inode = struct {
    ino: u64,
    /// Subvolume id and the logical address of that subvolume's tree root.
    subvol: u64,
    root: u64,
    mode: u32,
    size: u64,

    pub fn isDir(self: *const Inode) bool {
        return self.mode & mode_type_mask == mode_dir;
    }
    pub fn isRegular(self: *const Inode) bool {
        return self.mode & mode_type_mask == mode_reg;
    }
    pub fn isSymlink(self: *const Inode) bool {
        return self.mode & mode_type_mask == mode_symlink;
    }
};

pub const DirEntry = struct {
    /// Inode number within its subvolume (0 for a subvolume link).
    inode: u64,
    name: []const u8,
    /// ext4-compatible file type (1 regular, 2 directory, 7 symlink...).
    file_type: u8,
};

const Chunk = struct { logical: u64, length: u64, kind: u64, stripe_start: u32, num_stripes: u16 };
const Stripe = struct { devid: u64, offset: u64 };

pub const Fs = struct {
    allocator: std.mem.Allocator,
    region: blockdev.Region,
    sectorsize: u32,
    nodesize: u32,
    devid: u64,
    fsid: [16]u8,
    label_buf: [256]u8,
    chunks: []Chunk,
    stripes: []Stripe,
    root_tree: u64,
    default_subvol: u64,
    /// Selected subvolume (see `useSubvolume`); 0 means the default one.
    subvol: u64 = 0,
    bufs: [max_levels + 1][]u8,
    comp_buf: []u8,
    ram_buf: []u8,
    cache_extent: u64 = 0,
    cache_len: usize = 0,
    /// Number of extents decompressed so far (tests check compression is used).
    debug_decompressed: usize = 0,

    pub fn open(allocator: std.mem.Allocator, region: blockdev.Region) Error!Fs {
        var raw: [4096]u8 = undefined;
        try region.readAt(sb_offset, &raw);
        const sb = std.mem.bytesAsValue(Superblock, raw[0..@sizeOf(Superblock)]).*;
        if (!std.mem.eql(u8, &sb.magic, magic)) return error.BadMagic;
        if (sb.csum_type != 0) return error.Unsupported; // only crc32c
        if (~crc.crc32cUpdate(0xFFFFFFFF, raw[32..]) != std.mem.readInt(u32, raw[0..4], .little))
            return error.ChecksumMismatch;
        if (sb.nodesize < 4096 or sb.nodesize > 65536 or !std.math.isPowerOfTwo(sb.nodesize)) return error.Corrupt;
        if (sb.sectorsize < 512 or sb.sectorsize > 65536 or !std.math.isPowerOfTwo(sb.sectorsize)) return error.Corrupt;
        if (sb.sys_chunk_array_size > 2048) return error.Corrupt;

        var self = Fs{
            .allocator = allocator,
            .region = region,
            .sectorsize = sb.sectorsize,
            .nodesize = sb.nodesize,
            .devid = sb.dev_item.devid,
            .fsid = sb.fsid,
            .label_buf = sb.label,
            .chunks = &.{},
            .stripes = &.{},
            .root_tree = sb.root,
            .default_subvol = fs_tree_objectid,
            .bufs = undefined,
            .comp_buf = &.{},
            .ram_buf = &.{},
        };
        var allocated: usize = 0;
        errdefer {
            for (self.bufs[0..allocated]) |b| allocator.free(b);
            allocator.free(self.chunks);
            allocator.free(self.stripes);
            allocator.free(self.comp_buf);
            allocator.free(self.ram_buf);
        }
        for (&self.bufs) |*b| {
            b.* = try allocator.alloc(u8, self.nodesize);
            allocated += 1;
        }
        self.comp_buf = try allocator.alloc(u8, max_compressed_extent + 4096);
        self.ram_buf = try allocator.alloc(u8, 2 * max_compressed_extent);

        // 1. Bootstrap the logical->physical map from the superblock.
        try self.parseSysChunks(sb.sys_chunk_array[0..sb.sys_chunk_array_size]);
        // 2. Read the full chunk tree through it.
        try self.loadChunkTree(sb.chunk_root);
        // 3. The default subvolume.
        self.default_subvol = try self.findDefaultSubvolume();
        return self;
    }

    pub fn deinit(self: *Fs) void {
        for (self.bufs) |b| self.allocator.free(b);
        self.allocator.free(self.chunks);
        self.allocator.free(self.stripes);
        self.allocator.free(self.comp_buf);
        self.allocator.free(self.ram_buf);
    }

    pub fn label(self: *const Fs) []const u8 {
        return std.mem.sliceTo(&self.label_buf, 0);
    }

    pub fn uuid(self: *const Fs) [16]u8 {
        return self.fsid;
    }

    // ---- chunk map --------------------------------------------------------

    fn parseSysChunks(self: *Fs, array: []const u8) Error!void {
        var chunks: std.ArrayList(Chunk) = .empty;
        var stripes: std.ArrayList(Stripe) = .empty;
        errdefer {
            chunks.deinit(self.allocator);
            stripes.deinit(self.allocator);
        }
        var p: usize = 0;
        while (p < array.len) {
            if (p + @sizeOf(Key) + @sizeOf(ChunkItem) > array.len) return error.Corrupt;
            const key = std.mem.bytesAsValue(Key, array[p..][0..17]).*;
            p += 17;
            const used = try addChunk(self.allocator, &chunks, &stripes, key.offset, array[p..]);
            p += used;
        }
        self.allocator.free(self.chunks);
        self.allocator.free(self.stripes);
        self.chunks = try chunks.toOwnedSlice(self.allocator);
        self.stripes = try stripes.toOwnedSlice(self.allocator);
    }

    /// Parses one chunk item at the start of `data`; returns its byte length.
    fn addChunk(
        allocator: std.mem.Allocator,
        chunks: *std.ArrayList(Chunk),
        stripes: *std.ArrayList(Stripe),
        logical: u64,
        data: []const u8,
    ) Error!usize {
        if (data.len < @sizeOf(ChunkItem)) return error.Corrupt;
        const ci = std.mem.bytesAsValue(ChunkItem, data[0..@sizeOf(ChunkItem)]).*;
        const total = @sizeOf(ChunkItem) + @as(usize, ci.num_stripes) * @sizeOf(StripeRaw);
        if (ci.num_stripes == 0 or data.len < total) return error.Corrupt;
        try chunks.append(allocator, .{
            .logical = logical,
            .length = ci.length,
            .kind = ci.kind,
            .stripe_start = @intCast(stripes.items.len),
            .num_stripes = ci.num_stripes,
        });
        for (0..ci.num_stripes) |i| {
            const s = std.mem.bytesAsValue(StripeRaw, data[@sizeOf(ChunkItem) + i * @sizeOf(StripeRaw) ..][0..@sizeOf(StripeRaw)]).*;
            try stripes.append(allocator, .{ .devid = s.devid, .offset = s.offset });
        }
        return total;
    }

    const ChunkLoad = struct {
        fs: *Fs,
        chunks: *std.ArrayList(Chunk),
        stripes: *std.ArrayList(Stripe),
        err: ?Error = null,
    };

    fn chunkCb(c: *ChunkLoad, key: Key, data: []const u8) bool {
        if (key.kind != k_chunk_item) return false;
        _ = addChunk(c.fs.allocator, c.chunks, c.stripes, key.offset, data) catch |e| {
            c.err = e;
            return true;
        };
        return false;
    }

    fn loadChunkTree(self: *Fs, chunk_root: u64) Error!void {
        var chunks: std.ArrayList(Chunk) = .empty;
        var stripes: std.ArrayList(Stripe) = .empty;
        errdefer {
            chunks.deinit(self.allocator);
            stripes.deinit(self.allocator);
        }
        var ctx = ChunkLoad{ .fs = self, .chunks = &chunks, .stripes = &stripes };
        try self.walk(
            chunk_root,
            Key.make(first_chunk_tree_objectid, k_chunk_item, 0),
            Key.make(first_chunk_tree_objectid, k_chunk_item, std.math.maxInt(u64)),
            &ctx,
            chunkCb,
        );
        if (ctx.err) |e| return e;
        self.allocator.free(self.chunks);
        self.allocator.free(self.stripes);
        self.chunks = try chunks.toOwnedSlice(self.allocator);
        self.stripes = try stripes.toOwnedSlice(self.allocator);
    }

    /// Physical byte offsets on our device that hold `len` bytes starting at
    /// logical address `logical`: one per usable mirror, best first.
    pub fn mapLogical(self: *const Fs, logical: u64, len: u64, out: *[4]u64) Error!usize {
        for (self.chunks) |c| {
            if (logical < c.logical or logical >= c.logical + c.length) continue;
            if (len > c.logical + c.length - logical) return error.Corrupt;
            if (c.kind & (bg_raid0 | bg_raid10 | bg_raid5 | bg_raid6) != 0) return error.Unsupported;
            var n: usize = 0;
            for (self.stripes[c.stripe_start..][0..c.num_stripes]) |s| {
                if (s.devid != self.devid) continue; // a mirror on another device
                if (n < out.len) {
                    out[n] = s.offset + (logical - c.logical);
                    n += 1;
                }
            }
            if (n == 0) return error.Unsupported;
            return n;
        }
        return error.Corrupt;
    }

    // ---- tree blocks ------------------------------------------------------

    /// Reads and verifies the tree block at `bytenr`, trying each mirror.
    fn readNode(self: *const Fs, bytenr: u64, buf: []u8) Error!void {
        var phys: [4]u64 = undefined;
        const n = try self.mapLogical(bytenr, self.nodesize, &phys);
        var last: Error = error.Corrupt;
        for (phys[0..n]) |p| {
            self.region.readAt(p, buf) catch |e| {
                last = e;
                continue;
            };
            const hdr = std.mem.bytesAsValue(NodeHeader, buf[0..@sizeOf(NodeHeader)]);
            if (hdr.bytenr != bytenr) {
                last = error.Corrupt;
                continue;
            }
            if (~crc.crc32cUpdate(0xFFFFFFFF, buf[32..]) != std.mem.readInt(u32, buf[0..4], .little)) {
                last = error.ChecksumMismatch;
                continue;
            }
            if (hdr.level > max_levels) {
                last = error.Corrupt;
                continue;
            }
            return;
        }
        return last;
    }

    fn keyAt(buf: []const u8, off: usize) Key {
        return std.mem.bytesAsValue(Key, buf[off..][0..17]).*;
    }

    /// Calls `cb(ctx, key, data)` for every item with `min <= key <= max` in
    /// the tree rooted at `root`, in key order, until it returns true.
    fn walk(self: *Fs, root: u64, min: Key, max: Key, ctx: anytype, comptime cb: anytype) Error!void {
        _ = try self.walkNode(root, 0, min, max, ctx, cb);
    }

    /// Returns true when the walk should stop (callback asked, or past `max`).
    fn walkNode(self: *Fs, bytenr: u64, depth: usize, min: Key, max: Key, ctx: anytype, comptime cb: anytype) Error!bool {
        if (depth > max_levels) return error.Corrupt;
        const buf = self.bufs[depth];
        try self.readNode(bytenr, buf);
        const hdr = std.mem.bytesAsValue(NodeHeader, buf[0..@sizeOf(NodeHeader)]).*;
        const n = hdr.nritems;
        const base = @sizeOf(NodeHeader);

        if (hdr.level == 0) {
            if (base + @as(usize, n) * @sizeOf(Item) > buf.len) return error.Corrupt;
            for (0..n) |i| {
                const it = std.mem.bytesAsValue(Item, buf[base + i * @sizeOf(Item) ..][0..@sizeOf(Item)]).*;
                if (Key.order(it.key, min) == .lt) continue;
                if (Key.order(it.key, max) == .gt) return true;
                const start = base + @as(usize, it.offset);
                if (start + it.size > buf.len) return error.Corrupt;
                if (cb(ctx, it.key, buf[start..][0..it.size])) return true;
            }
            return false;
        }

        if (base + @as(usize, n) * @sizeOf(KeyPtr) > buf.len) return error.Corrupt;
        for (0..n) |i| {
            const kp = std.mem.bytesAsValue(KeyPtr, buf[base + i * @sizeOf(KeyPtr) ..][0..@sizeOf(KeyPtr)]).*;
            if (Key.order(kp.key, max) == .gt) return true;
            // Skip children that end before `min`.
            if (i + 1 < n) {
                const next = keyAt(buf, base + (i + 1) * @sizeOf(KeyPtr));
                if (Key.order(next, min) != .gt) continue;
            }
            if (try self.walkNode(kp.blockptr, depth + 1, min, max, ctx, cb)) return true;
        }
        return false;
    }

    const Found = struct { key: Key, data: []const u8 };

    /// The item with the greatest key <= `target`, or null. The returned data
    /// points into a tree buffer and is valid until the next tree access.
    fn searchLe(self: *Fs, root: u64, target: Key) Error!?Found {
        return self.searchNode(root, 0, target);
    }

    fn searchNode(self: *Fs, bytenr: u64, depth: usize, target: Key) Error!?Found {
        if (depth > max_levels) return error.Corrupt;
        const buf = self.bufs[depth];
        try self.readNode(bytenr, buf);
        const hdr = std.mem.bytesAsValue(NodeHeader, buf[0..@sizeOf(NodeHeader)]).*;
        const n: usize = hdr.nritems;
        const base = @sizeOf(NodeHeader);
        if (hdr.level == 0) {
            if (base + n * @sizeOf(Item) > buf.len) return error.Corrupt;
            var i = n;
            while (i > 0) {
                i -= 1;
                const it = std.mem.bytesAsValue(Item, buf[base + i * @sizeOf(Item) ..][0..@sizeOf(Item)]).*;
                if (Key.order(it.key, target) != .gt) {
                    const start = base + @as(usize, it.offset);
                    if (start + it.size > buf.len) return error.Corrupt;
                    return .{ .key = it.key, .data = buf[start..][0..it.size] };
                }
            }
            return null;
        }
        if (base + n * @sizeOf(KeyPtr) > buf.len) return error.Corrupt;
        var i = n;
        while (i > 0) {
            i -= 1;
            const kp = std.mem.bytesAsValue(KeyPtr, buf[base + i * @sizeOf(KeyPtr) ..][0..@sizeOf(KeyPtr)]).*;
            if (Key.order(kp.key, target) == .gt) continue;
            // If this child has nothing <= target, the answer is the previous
            // child's last item, which the loop reaches next.
            if (try self.searchNode(kp.blockptr, depth + 1, target)) |f| return f;
        }
        return null;
    }

    // ---- subvolumes -------------------------------------------------------

    const Once = struct { found: bool = false, data: [256]u8 = undefined, len: usize = 0 };

    fn onceCb(o: *Once, _: Key, data: []const u8) bool {
        o.found = true;
        o.len = @min(data.len, o.data.len);
        @memcpy(o.data[0..o.len], data[0..o.len]);
        return true;
    }

    fn findDefaultSubvolume(self: *Fs) Error!u64 {
        const hash = nameHash("default");
        var o = Once{};
        const k = Key.make(root_tree_dir_objectid, k_dir_item, hash);
        try self.walk(self.root_tree, k, k, &o, onceCb);
        if (!o.found or o.len < @sizeOf(DirItemHdr)) return fs_tree_objectid;
        const d = std.mem.bytesAsValue(DirItemHdr, o.data[0..@sizeOf(DirItemHdr)]).*;
        return d.location.objectid;
    }

    /// Logical address of the root of tree `id` (a subvolume id).
    fn treeRoot(self: *Fs, id: u64) Error!u64 {
        if (id == 1) return self.root_tree;
        const f = (try self.searchLe(self.root_tree, Key.make(id, k_root_item, std.math.maxInt(u64)))) orelse
            return error.NotFound;
        if (f.key.objectid != id or f.key.kind != k_root_item or f.data.len < 239) return error.NotFound;
        return std.mem.readInt(u64, f.data[176..184], .little);
    }

    fn currentSubvol(self: *const Fs) u64 {
        return if (self.subvol != 0) self.subvol else self.default_subvol;
    }

    /// Selects the subvolume that later lookups start in: `path` is relative
    /// to the top-level subvolume (like the `subvol=` mount option). `null`
    /// selects the filesystem's default subvolume.
    pub fn useSubvolume(self: *Fs, path: ?[]const u8) Error!void {
        const p = path orelse {
            self.subvol = 0;
            return;
        };
        self.subvol = 0;
        const saved = self.default_subvol;
        self.default_subvol = fs_tree_objectid;
        defer self.default_subvol = saved;
        const ino = self.lookup(p) catch |e| return e;
        if (ino.ino != first_free_objectid) return error.NotFound; // not a subvolume root
        self.subvol = ino.subvol;
    }

    // ---- inodes ----------------------------------------------------------

    fn readInode(self: *Fs, subvol: u64, root: u64, ino: u64) Error!Inode {
        const f = (try self.searchLe(root, Key.make(ino, k_inode_item, 0))) orelse return error.NotFound;
        if (f.key.objectid != ino or f.key.kind != k_inode_item or f.data.len < 160) return error.NotFound;
        return .{
            .ino = ino,
            .subvol = subvol,
            .root = root,
            .size = std.mem.readInt(u64, f.data[16..24], .little),
            .mode = std.mem.readInt(u32, f.data[52..56], .little),
        };
    }

    fn rootInode(self: *Fs) Error!Inode {
        const id = self.currentSubvol();
        const root = try self.treeRoot(id);
        return self.readInode(id, root, first_free_objectid);
    }

    // ---- directories ------------------------------------------------------

    /// The hash btrfs keys `DIR_ITEM`s by: crc32c of the name, seeded `~1`.
    fn nameHash(name: []const u8) u64 {
        return crc.crc32cUpdate(0xFFFFFFFE, name);
    }

    const Find = struct {
        name: []const u8,
        found: bool = false,
        loc: Key = undefined,
    };

    fn findCb(f: *Find, _: Key, data: []const u8) bool {
        var p: usize = 0;
        while (p + @sizeOf(DirItemHdr) <= data.len) {
            const d = std.mem.bytesAsValue(DirItemHdr, data[p..][0..@sizeOf(DirItemHdr)]).*;
            const end = p + @sizeOf(DirItemHdr) + d.name_len + d.data_len;
            if (end > data.len) return true;
            const name = data[p + @sizeOf(DirItemHdr) ..][0..d.name_len];
            if (std.mem.eql(u8, name, f.name)) {
                f.found = true;
                f.loc = d.location;
                return true;
            }
            p = end;
        }
        return false;
    }

    pub fn lookupIn(self: *Fs, dir: *const Inode, name: []const u8) Error!Inode {
        if (!dir.isDir()) return error.NotDirectory;
        if (std.mem.eql(u8, name, ".")) return dir.*;
        if (std.mem.eql(u8, name, "..")) return self.parentOf(dir);
        var f = Find{ .name = name };
        const k = Key.make(dir.ino, k_dir_item, nameHash(name));
        try self.walk(dir.root, k, k, &f, findCb);
        if (!f.found) return error.NotFound;
        if (f.loc.kind == k_root_item) {
            // The entry is a subvolume: continue in its tree.
            const root = try self.treeRoot(f.loc.objectid);
            return self.readInode(f.loc.objectid, root, first_free_objectid);
        }
        return self.readInode(dir.subvol, dir.root, f.loc.objectid);
    }

    fn parentOf(self: *Fs, dir: *const Inode) Error!Inode {
        if (dir.ino == first_free_objectid) return dir.*; // subvolume root
        const f = (try self.searchLe(dir.root, Key.make(dir.ino, k_inode_ref, std.math.maxInt(u64)))) orelse
            return error.NotFound;
        if (f.key.objectid != dir.ino or f.key.kind != k_inode_ref) return error.NotFound;
        return self.readInode(dir.subvol, dir.root, f.key.offset);
    }

    const WalkCtx = struct {
        user: *anyopaque,
        cb: *const fn (*anyopaque, DirEntry) bool,
    };

    /// Calls `cb(ctx, entry)` for every entry of `dir` (including "." and
    /// ".."), stopping early if it returns true. Subvolume links report
    /// `inode == 0`.
    pub fn walkDir(self: *Fs, dir: *const Inode, ctx: anytype, comptime cb: anytype) Error!void {
        if (!dir.isDir()) return error.NotDirectory;
        if (cb(ctx, DirEntry{ .inode = dir.ino, .name = ".", .file_type = 2 })) return;
        if (cb(ctx, DirEntry{ .inode = dir.ino, .name = "..", .file_type = 2 })) return;
        const Wrap = struct {
            user: @TypeOf(ctx),
            fn each(w: *@This(), _: Key, data: []const u8) bool {
                var p: usize = 0;
                while (p + @sizeOf(DirItemHdr) <= data.len) {
                    const d = std.mem.bytesAsValue(DirItemHdr, data[p..][0..@sizeOf(DirItemHdr)]).*;
                    const end = p + @sizeOf(DirItemHdr) + d.name_len + d.data_len;
                    if (end > data.len) return true;
                    const e = DirEntry{
                        .inode = if (d.location.kind == k_inode_item) d.location.objectid else 0,
                        .name = data[p + @sizeOf(DirItemHdr) ..][0..d.name_len],
                        .file_type = d.kind,
                    };
                    if (cb(w.user, e)) return true;
                    p = end;
                }
                return false;
            }
        };
        var w = Wrap{ .user = ctx };
        try self.walk(
            dir.root,
            Key.make(dir.ino, k_dir_index, 0),
            Key.make(dir.ino, k_dir_index, std.math.maxInt(u64)),
            &w,
            Wrap.each,
        );
    }

    // ---- path lookup ------------------------------------------------------

    /// Resolves an absolute path in the selected (or default) subvolume,
    /// following symlinks. Crossing into a nested subvolume works.
    pub fn lookup(self: *Fs, path: []const u8) Error!Inode {
        var links: u32 = 0;
        const root = try self.rootInode();
        return self.resolveFrom(root, root, path, &links);
    }

    fn resolveFrom(self: *Fs, top: Inode, start: Inode, path: []const u8, links: *u32) Error!Inode {
        var cur = start;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |comp| {
            if (comp.len > 255) return error.NameTooLong;
            if (!cur.isDir()) return error.NotDirectory;
            const next = try self.lookupIn(&cur, comp);
            if (!next.isSymlink()) {
                cur = next;
                continue;
            }
            links.* += 1;
            if (links.* > max_symlinks) return error.TooManyLinks;
            var tbuf: [1024]u8 = undefined;
            const target = try self.readLink(&next, &tbuf);
            const base = if (target.len > 0 and target[0] == '/') top else cur;
            cur = try self.resolveFrom(top, base, target, links);
        }
        return cur;
    }

    pub fn readLink(self: *Fs, ino: *const Inode, buf: []u8) Error![]const u8 {
        if (!ino.isSymlink()) return error.Corrupt;
        if (ino.size > buf.len) return error.NameTooLong;
        const n = try self.readAt(ino, 0, buf[0..@intCast(ino.size)]);
        return buf[0..n];
    }

    // ---- file contents ----------------------------------------------------

    const Compression = enum(u8) { none = 0, zlib = 1, lzo = 2, zstd = 3, _ };

    /// Reads up to `buf.len` bytes of the file at `offset`; holes read as zeros.
    pub fn readAt(self: *Fs, ino: *const Inode, offset: u64, buf: []u8) Error!usize {
        if (offset >= ino.size) return 0;
        const want: usize = @intCast(@min(@as(u64, buf.len), ino.size - offset));
        var done: usize = 0;
        while (done < want) {
            const pos = offset + done;
            const left = want - done;
            const f = try self.searchLe(ino.root, Key.make(ino.ino, k_extent_data, pos));
            // No extent at or before `pos` (or it belongs to another file): hole.
            if (f == null or f.?.key.objectid != ino.ino or f.?.key.kind != k_extent_data) {
                const next = try self.nextExtentStart(ino, pos);
                const n: usize = @intCast(@min(@as(u64, left), next -| pos));
                @memset(buf[done..][0..n], 0);
                done += @max(n, 1);
                continue;
            }
            const fe = f.?;
            if (fe.data.len < 21) return error.Corrupt;
            const file_off = fe.key.offset;
            const compression: Compression = @fromBackingInt(@intCast(fe.data[16]));
            const kind = fe.data[20];
            if (fe.data[17] != 0) return error.Unsupported; // encryption

            if (kind == 0) {
                // Inline extent: the data follows the 21-byte header.
                const ram = std.mem.readInt(u64, fe.data[8..16], .little);
                const inline_data = fe.data[21..];
                var plain: []const u8 = inline_data;
                if (compression != .none) {
                    if (ram > self.ram_buf.len) return error.Corrupt;
                    const got = try self.decompress(compression, inline_data, @intCast(ram));
                    plain = got;
                }
                const rel: usize = @intCast(pos - file_off);
                if (rel >= plain.len) {
                    // Inline data shorter than the file size: zero tail.
                    const n = left;
                    @memset(buf[done..][0..n], 0);
                    done += n;
                    continue;
                }
                const n = @min(left, plain.len - rel);
                @memcpy(buf[done..][0..n], plain[rel..][0..n]);
                done += n;
                continue;
            }

            if (fe.data.len < 53) return error.Corrupt;
            const disk_bytenr = std.mem.readInt(u64, fe.data[21..29], .little);
            const disk_num = std.mem.readInt(u64, fe.data[29..37], .little);
            const ext_off = std.mem.readInt(u64, fe.data[37..45], .little);
            const num_bytes = std.mem.readInt(u64, fe.data[45..53], .little);
            const ram_bytes = std.mem.readInt(u64, fe.data[8..16], .little);
            if (pos >= file_off + num_bytes) {
                // `pos` lies in a gap after this extent.
                const next = try self.nextExtentStart(ino, pos);
                const n: usize = @intCast(@min(@as(u64, left), next -| pos));
                @memset(buf[done..][0..n], 0);
                done += @max(n, 1);
                continue;
            }
            const within = pos - file_off;
            const n: usize = @intCast(@min(@as(u64, left), num_bytes - within));
            if (kind == 2 or disk_bytenr == 0) {
                @memset(buf[done..][0..n], 0); // preallocated or sparse extent
            } else if (compression == .none) {
                try self.readLogical(disk_bytenr + ext_off + within, buf[done..][0..n]);
            } else {
                const plain = try self.loadCompressed(compression, disk_bytenr, disk_num, ram_bytes);
                const rel: usize = @intCast(ext_off + within);
                if (rel + n > plain.len) return error.Corrupt;
                @memcpy(buf[done..][0..n], plain[rel..][0..n]);
            }
            done += n;
        }
        return want;
    }

    const NextCtx = struct { start: u64 = std.math.maxInt(u64) };
    fn nextCb(c: *NextCtx, key: Key, _: []const u8) bool {
        c.start = key.offset;
        return true;
    }

    /// File offset where the next extent after `pos` starts (or "never").
    fn nextExtentStart(self: *Fs, ino: *const Inode, pos: u64) Error!u64 {
        var c = NextCtx{};
        try self.walk(
            ino.root,
            Key.make(ino.ino, k_extent_data, pos + 1),
            Key.make(ino.ino, k_extent_data, std.math.maxInt(u64)),
            &c,
            nextCb,
        );
        return c.start;
    }

    /// Reads data at a logical address (data extents don't cross chunks).
    fn readLogical(self: *Fs, logical: u64, buf: []u8) Error!void {
        var done: usize = 0;
        while (done < buf.len) {
            var phys: [4]u64 = undefined;
            // Map in sector-sized pieces only as far as the chunk allows.
            var piece: usize = buf.len - done;
            const n = while (true) {
                if (self.mapLogical(logical + done, piece, &phys)) |count| break count else |e| {
                    if (e != error.Corrupt or piece <= self.sectorsize) return e;
                    piece = @max(self.sectorsize, piece / 2);
                }
            };
            try self.region.readAt(phys[0], buf[done..][0..piece]);
            _ = n;
            done += piece;
        }
    }

    /// Returns the decompressed bytes of the extent at `disk_bytenr`.
    fn loadCompressed(self: *Fs, c: Compression, disk_bytenr: u64, disk_num: u64, ram_bytes: u64) Error![]const u8 {
        if (self.cache_extent == disk_bytenr and self.cache_len == ram_bytes) return self.ram_buf[0..self.cache_len];
        if (disk_num > self.comp_buf.len or ram_bytes > max_compressed_extent) return error.Corrupt;
        try self.readLogical(disk_bytenr, self.comp_buf[0..@intCast(disk_num)]);
        self.cache_extent = 0;
        const out = try self.decompress(c, self.comp_buf[0..@intCast(disk_num)], @intCast(ram_bytes));
        self.cache_extent = disk_bytenr;
        self.cache_len = out.len;
        return out;
    }

    /// Decompresses `in` into `ram_buf`; the result must be `expect` bytes.
    fn decompress(self: *Fs, c: Compression, in: []const u8, expect: usize) Error![]const u8 {
        const out = self.ram_buf;
        self.debug_decompressed += 1;
        const n: usize = switch (c) {
            .none => unreachable,
            .zlib => blk: {
                var r = std.Io.Reader.fixed(in);
                var w = std.Io.Writer.fixed(out);
                var d = std.compress.flate.Decompress.init(&r, .zlib, &.{});
                _ = d.reader.streamRemaining(&w) catch return error.Corrupt;
                break :blk w.end;
            },
            .zstd => blk: {
                var r = std.Io.Reader.fixed(in);
                var w = std.Io.Writer.fixed(out);
                var d = std.compress.zstd.Decompress.init(&r, &.{}, .{ .window_len = max_compressed_extent });
                // The extent is padded with zeros to a sector after the one zstd
                // frame, and the decoder reads on into that padding as a second
                // frame ("bad magic"). The frame itself is already decoded.
                _ = d.reader.streamRemaining(&w) catch {
                    const bad_magic = if (d.err) |de| de == error.BadMagic else false;
                    if (!bad_magic or w.end == 0) return error.Corrupt;
                };
                break :blk w.end;
            },
            .lzo => try self.decompressLzo(in, out),
            _ => return error.Unsupported,
        };
        // The last extent of a file is rounded up to a sector, but only the
        // real data is compressed: the tail reads as zeros.
        if (n > expect or expect > out.len) return error.Corrupt;
        @memset(out[n..expect], 0);
        return out[0..expect];
    }

    /// btrfs LZO framing: u32 total length, then segments of
    /// (u32 length, LZO1X stream); a segment header never straddles a sector.
    fn decompressLzo(self: *Fs, in: []const u8, out: []u8) Error!usize {
        if (in.len < 4) return error.Corrupt;
        const total = std.mem.readInt(u32, in[0..4], .little);
        if (total > in.len) return error.Corrupt;
        var pos: usize = 4;
        var op: usize = 0;
        while (pos < total) {
            const in_sector = self.sectorsize - (pos % self.sectorsize);
            if (in_sector < 4) {
                pos += in_sector;
                continue;
            }
            if (pos + 4 > total) return error.Corrupt;
            const seg = std.mem.readInt(u32, in[pos..][0..4], .little);
            pos += 4;
            if (seg > total - pos) return error.Corrupt;
            const dst = out[op..@min(out.len, op + self.sectorsize)];
            const n = lzo.decompress(in[pos..][0..seg], dst) catch return error.Corrupt;
            op += n;
            pos += seg;
        }
        return op;
    }
};
