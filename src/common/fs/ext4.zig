//! Read-only ext2/ext3/ext4 reader.
//!
//! Supports block maps and extents, 64bit, flex_bg, inline data, symlinks and
//! directories of any size (htree directories are read as plain linear ones,
//! which the format allows). With `metadata_csum`, the superblock, group
//! descriptors, inodes, extent blocks and directory leaf blocks are verified
//! and a mismatch is an error, never silently ignored.
//!
//! Not supported (returns `error.Unsupported`): `meta_bg`, compression, an
//! external journal device, inodes larger than 512 bytes. A volume that needs
//! journal recovery is read as it is on disk; `needs_recovery` reports it.
//!
//! Specification: https://www.kernel.org/doc/html/latest/filesystems/ext4/

const std = @import("std");
const blockdev = @import("../blockdev.zig");
const crc = @import("../crc.zig");

pub const Error = error{
    /// Not an ext2/3/4 superblock.
    BadMagic,
    /// A feature this reader does not implement.
    Unsupported,
    /// Structurally invalid metadata.
    Corrupt,
    /// A `metadata_csum` checksum did not match.
    ChecksumMismatch,
    NotFound,
    NotDirectory,
    IsDirectory,
    NameTooLong,
    /// Too many nested symlinks (or a loop).
    TooManyLinks,
    OutOfMemory,
} || blockdev.Error;

/// ext4 superblock, at byte 1024 of the volume. 1024 bytes.
const Superblock = extern struct {
    inodes_count: u32,
    blocks_count_lo: u32,
    r_blocks_count_lo: u32,
    free_blocks_count_lo: u32,
    free_inodes_count: u32,
    first_data_block: u32,
    log_block_size: u32,
    log_cluster_size: u32,
    blocks_per_group: u32,
    clusters_per_group: u32,
    inodes_per_group: u32,
    mtime: u32,
    wtime: u32,
    mnt_count: u16,
    max_mnt_count: u16,
    magic: u16,
    state: u16,
    errors: u16,
    minor_rev_level: u16,
    lastcheck: u32,
    checkinterval: u32,
    creator_os: u32,
    rev_level: u32,
    def_resuid: u16,
    def_resgid: u16,
    first_ino: u32,
    inode_size: u16,
    block_group_nr: u16,
    feature_compat: u32,
    feature_incompat: u32,
    feature_ro_compat: u32,
    uuid: [16]u8,
    volume_name: [16]u8,
    last_mounted: [64]u8,
    algorithm_usage_bitmap: u32,
    prealloc_blocks: u8,
    prealloc_dir_blocks: u8,
    reserved_gdt_blocks: u16,
    journal_uuid: [16]u8,
    journal_inum: u32,
    journal_dev: u32,
    last_orphan: u32,
    hash_seed: [4]u32,
    def_hash_version: u8,
    jnl_backup_type: u8,
    desc_size: u16,
    default_mount_opts: u32,
    first_meta_bg: u32,
    mkfs_time: u32,
    jnl_blocks: [17]u32,
    blocks_count_hi: u32,
    r_blocks_count_hi: u32,
    free_blocks_count_hi: u32,
    min_extra_isize: u16,
    want_extra_isize: u16,
    flags: u32,
    raid_stride: u16,
    mmp_interval: u16,
    mmp_block: u64,
    raid_stripe_width: u32,
    log_groups_per_flex: u8,
    checksum_type: u8,
    encryption_level: u8,
    reserved_pad: u8,
    kbytes_written: u64,
    snapshot_inum: u32,
    snapshot_id: u32,
    snapshot_r_blocks_count: u64,
    snapshot_list: u32,
    error_count: u32,
    first_error_time: u32,
    first_error_ino: u32,
    first_error_block: u64,
    first_error_func: [32]u8,
    first_error_line: u32,
    last_error_time: u32,
    last_error_ino: u32,
    last_error_line: u32,
    last_error_block: u64,
    last_error_func: [32]u8,
    mount_opts: [64]u8,
    usr_quota_inum: u32,
    grp_quota_inum: u32,
    overhead_clusters: u32,
    backup_bgs: [2]u32,
    encrypt_algos: [4]u8,
    encrypt_pw_salt: [16]u8,
    lpf_ino: u32,
    prj_quota_inum: u32,
    checksum_seed: u32,
    times_hi: [6]u8,
    error_codes: [2]u8,
    encoding: u16,
    encoding_flags: u16,
    reserved: [95]u32,
    checksum: u32,
};

/// Group descriptor: the first 32 bytes, plus 32 more with the 64bit feature.
const GroupDesc = extern struct {
    block_bitmap_lo: u32,
    inode_bitmap_lo: u32,
    inode_table_lo: u32,
    free_blocks_count_lo: u16,
    free_inodes_count_lo: u16,
    used_dirs_count_lo: u16,
    flags: u16,
    exclude_bitmap_lo: u32,
    block_bitmap_csum_lo: u16,
    inode_bitmap_csum_lo: u16,
    itable_unused_lo: u16,
    checksum: u16,
    block_bitmap_hi: u32,
    inode_bitmap_hi: u32,
    inode_table_hi: u32,
    free_blocks_count_hi: u16,
    free_inodes_count_hi: u16,
    used_dirs_count_hi: u16,
    itable_unused_hi: u16,
    exclude_bitmap_hi: u32,
    block_bitmap_csum_hi: u16,
    inode_bitmap_csum_hi: u16,
    reserved: u32,
};

/// The 128-byte original inode; ext4 inodes extend it (see `extra_isize`).
const InodeBase = extern struct {
    mode: u16,
    uid: u16,
    size_lo: u32,
    atime: u32,
    ctime: u32,
    mtime: u32,
    dtime: u32,
    gid: u16,
    links_count: u16,
    blocks_lo: u32,
    flags: u32,
    osd1: u32,
    block: [60]u8,
    generation: u32,
    file_acl_lo: u32,
    size_high: u32,
    obso_faddr: u32,
    blocks_high: u16,
    file_acl_high: u16,
    uid_high: u16,
    gid_high: u16,
    checksum_lo: u16,
    reserved: u16,
};

const ExtentHeader = extern struct {
    magic: u16,
    entries: u16,
    max: u16,
    depth: u16,
    generation: u32,
};

const Extent = extern struct {
    block: u32,
    len: u16,
    start_hi: u16,
    start_lo: u32,
};

const ExtentIdx = extern struct {
    block: u32,
    leaf_lo: u32,
    leaf_hi: u16,
    unused: u16,
};

comptime {
    std.debug.assert(@sizeOf(Superblock) == 1024);
    std.debug.assert(@sizeOf(GroupDesc) == 64);
    std.debug.assert(@sizeOf(InodeBase) == 128);
    std.debug.assert(@sizeOf(ExtentHeader) == 12);
    std.debug.assert(@sizeOf(Extent) == 12);
    std.debug.assert(@sizeOf(ExtentIdx) == 12);
}

const magic = 0xEF53;
const extent_magic = 0xF30A;

const incompat_compression = 0x1;
const incompat_recover = 0x4;
const incompat_journal_dev = 0x8;
const incompat_meta_bg = 0x10;
const incompat_extents = 0x40;
const incompat_64bit = 0x80;
const incompat_csum_seed = 0x2000;
const incompat_inline_data = 0x8000;
const ro_compat_metadata_csum = 0x400;

const flag_extents = 0x80000;
const flag_inline_data = 0x10000000;

const mode_type_mask = 0xF000;
pub const mode_dir = 0x4000;
pub const mode_reg = 0x8000;
pub const mode_symlink = 0xA000;

/// Largest inode we keep a raw copy of (inode_size is almost always 256).
const max_inode_size = 512;
pub const root_inode = 2;
const max_symlinks = 8;

/// An inode, with the fields callers need already decoded.
pub const Inode = struct {
    number: u32,
    mode: u16,
    size: u64,
    flags: u32,
    generation: u32,
    raw: [max_inode_size]u8,

    pub fn isDir(self: *const Inode) bool {
        return self.mode & mode_type_mask == mode_dir;
    }
    pub fn isRegular(self: *const Inode) bool {
        return self.mode & mode_type_mask == mode_reg;
    }
    pub fn isSymlink(self: *const Inode) bool {
        return self.mode & mode_type_mask == mode_symlink;
    }
    fn iBlock(self: *const Inode) *const [60]u8 {
        return self.raw[40..100];
    }
};

pub const DirEntry = struct {
    inode: u32,
    /// Valid only until the iteration callback returns.
    name: []const u8,
    /// ext4 `file_type` byte (1 regular, 2 directory, 7 symlink, ...).
    file_type: u8,
};

pub const Fs = struct {
    allocator: std.mem.Allocator,
    region: blockdev.Region,
    block_size: u32,
    blocks_count: u64,
    first_data_block: u32,
    blocks_per_group: u32,
    inodes_per_group: u32,
    inodes_count: u32,
    inode_size: u32,
    desc_size: u32,
    incompat: u32,
    ro_compat: u32,
    csum_seed: u32,
    metadata_csum: bool,
    needs_recovery: bool,
    uuid: [16]u8,
    label_buf: [16]u8,
    /// Scratch for extent-tree nodes, directory blocks and indirect blocks.
    node_buf: []u8,
    /// One-entry cache for block-map indirect blocks.
    ind_buf: []u8,
    ind_block: u64,

    pub fn open(allocator: std.mem.Allocator, region: blockdev.Region) Error!Fs {
        var sb_bytes: [1024]u8 = undefined;
        try region.readAt(1024, &sb_bytes);
        const sb = std.mem.bytesAsValue(Superblock, &sb_bytes).*;
        if (sb.magic != magic) return error.BadMagic;
        if (sb.log_block_size > 6) return error.Corrupt; // up to 64 KiB
        if (sb.feature_incompat & (incompat_compression | incompat_journal_dev | incompat_meta_bg) != 0)
            return error.Unsupported;
        const metadata_csum = sb.feature_ro_compat & ro_compat_metadata_csum != 0;
        if (metadata_csum and crc.crc32cUpdate(0xFFFFFFFF, sb_bytes[0..1020]) != sb.checksum)
            return error.ChecksumMismatch;

        const block_size: u32 = @as(u32, 1024) << @intCast(sb.log_block_size);
        const is64 = sb.feature_incompat & incompat_64bit != 0;
        const desc_size: u32 = if (is64) sb.desc_size else 32;
        if (is64 and (desc_size < 64 or desc_size > block_size)) return error.Corrupt;
        const inode_size: u32 = if (sb.rev_level == 0) 128 else sb.inode_size;
        if (inode_size < 128 or inode_size > max_inode_size or !std.math.isPowerOfTwo(inode_size))
            return error.Unsupported;
        if (sb.blocks_per_group == 0 or sb.inodes_per_group == 0) return error.Corrupt;

        const blocks_count = @as(u64, sb.blocks_count_lo) |
            (if (is64) @as(u64, sb.blocks_count_hi) << 32 else 0);

        const node_buf = try allocator.alloc(u8, block_size);
        errdefer allocator.free(node_buf);
        const ind_buf = try allocator.alloc(u8, block_size);

        return .{
            .allocator = allocator,
            .region = region,
            .block_size = block_size,
            .blocks_count = blocks_count,
            .first_data_block = sb.first_data_block,
            .blocks_per_group = sb.blocks_per_group,
            .inodes_per_group = sb.inodes_per_group,
            .inodes_count = sb.inodes_count,
            .inode_size = inode_size,
            .desc_size = desc_size,
            .incompat = sb.feature_incompat,
            .ro_compat = sb.feature_ro_compat,
            .csum_seed = if (sb.feature_incompat & incompat_csum_seed != 0)
                sb.checksum_seed
            else
                crc.crc32cUpdate(0xFFFFFFFF, &sb.uuid),
            .metadata_csum = metadata_csum,
            .needs_recovery = sb.feature_incompat & incompat_recover != 0,
            .uuid = sb.uuid,
            .label_buf = sb.volume_name,
            .node_buf = node_buf,
            .ind_buf = ind_buf,
            .ind_block = 0,
        };
    }

    pub fn deinit(self: *Fs) void {
        self.allocator.free(self.node_buf);
        self.allocator.free(self.ind_buf);
    }

    /// The volume label, without trailing NULs.
    pub fn label(self: *const Fs) []const u8 {
        return std.mem.sliceTo(&self.label_buf, 0);
    }

    // ---- inodes ---------------------------------------------------------

    fn readGroupDesc(self: *Fs, group: u32) Error!GroupDesc {
        const gdt_block: u64 = @as(u64, self.first_data_block) + 1;
        const off = gdt_block * self.block_size + @as(u64, group) * self.desc_size;
        var raw: [64]u8 = @splat(0);
        try self.region.readAt(off, raw[0..self.desc_size]);
        if (self.metadata_csum) {
            var c = crc.crc32cUpdate(self.csum_seed, std.mem.asBytes(&std.mem.nativeToLittle(u32, group)));
            c = crc.crc32cUpdate(c, raw[0..30]);
            c = crc.crc32cUpdate(c, &[_]u8{ 0, 0 });
            if (self.desc_size > 32) c = crc.crc32cUpdate(c, raw[32..self.desc_size]);
            const stored = std.mem.readInt(u16, raw[30..32], .little);
            if (@as(u16, @truncate(c)) != stored) return error.ChecksumMismatch;
        }
        return std.mem.bytesAsValue(GroupDesc, &raw).*;
    }

    pub fn readInode(self: *Fs, number: u32) Error!Inode {
        if (number == 0 or number > self.inodes_count) return error.Corrupt;
        const group = (number - 1) / self.inodes_per_group;
        const index = (number - 1) % self.inodes_per_group;
        const gd = try self.readGroupDesc(group);
        const table = @as(u64, gd.inode_table_lo) |
            (if (self.desc_size >= 64) @as(u64, gd.inode_table_hi) << 32 else 0);
        const off = table * self.block_size + @as(u64, index) * self.inode_size;

        var ino: Inode = undefined;
        ino.raw = @splat(0);
        try self.region.readAt(off, ino.raw[0..self.inode_size]);
        const base = std.mem.bytesAsValue(InodeBase, ino.raw[0..128]).*;
        ino.number = number;
        ino.mode = base.mode;
        ino.flags = base.flags;
        ino.generation = base.generation;
        ino.size = @as(u64, base.size_lo) | (@as(u64, base.size_high) << 32);
        if (self.metadata_csum) try self.verifyInode(&ino);
        return ino;
    }

    fn inodeSeed(self: *const Fs, ino: *const Inode) u32 {
        const n = std.mem.nativeToLittle(u32, ino.number);
        const g = std.mem.nativeToLittle(u32, ino.generation);
        const c = crc.crc32cUpdate(self.csum_seed, std.mem.asBytes(&n));
        return crc.crc32cUpdate(c, std.mem.asBytes(&g));
    }

    fn verifyInode(self: *const Fs, ino: *const Inode) Error!void {
        var raw = ino.raw;
        const extra: u16 = if (self.inode_size > 128) std.mem.readInt(u16, raw[128..130], .little) else 0;
        const has_hi = self.inode_size > 128 and extra >= 4;
        const stored_lo = std.mem.readInt(u16, raw[124..126], .little);
        const stored_hi: u16 = if (has_hi) std.mem.readInt(u16, raw[130..132], .little) else 0;
        raw[124] = 0;
        raw[125] = 0;
        if (has_hi) {
            raw[130] = 0;
            raw[131] = 0;
        }
        const c = crc.crc32cUpdate(self.inodeSeed(ino), raw[0..self.inode_size]);
        if (@as(u16, @truncate(c)) != stored_lo) return error.ChecksumMismatch;
        if (has_hi and @as(u16, @truncate(c >> 16)) != stored_hi) return error.ChecksumMismatch;
    }

    // ---- mapping logical blocks -----------------------------------------

    /// Result of looking up a logical block: where its run starts on disk and
    /// how many blocks (at least 1) are contiguous from there. `phys == 0`
    /// is a hole, `run` then counts the blocks of hole.
    const Run = struct { phys: u64, run: u64 };

    fn mapExtents(self: *Fs, ino: *const Inode, lblock: u64) Error!Run {
        var node: [60]u8 = undefined;
        @memcpy(&node, ino.iBlock());
        var node_slice: []const u8 = &node;
        var depth_checked = false;
        var expect_depth: u16 = 0;
        while (true) {
            const hdr = std.mem.bytesAsValue(ExtentHeader, node_slice[0..12]).*;
            if (hdr.magic != extent_magic) return error.Corrupt;
            if (!depth_checked) {
                expect_depth = hdr.depth;
                depth_checked = true;
                if (hdr.depth > 5) return error.Corrupt;
            } else if (hdr.depth != expect_depth) return error.Corrupt;
            if (12 + @as(usize, hdr.entries) * 12 > node_slice.len) return error.Corrupt;

            if (hdr.depth == 0) {
                // Leaf: find the last extent starting at or before lblock.
                var next_start: ?u64 = null;
                var found: ?Extent = null;
                for (0..hdr.entries) |i| {
                    const e = std.mem.bytesAsValue(Extent, node_slice[12 + i * 12 ..][0..12]).*;
                    if (e.block <= lblock) {
                        found = e;
                    } else {
                        next_start = e.block;
                        break;
                    }
                }
                if (found) |e| {
                    const len: u64 = if (e.len > 32768) e.len - 32768 else e.len;
                    const uninit = e.len > 32768;
                    if (lblock < @as(u64, e.block) + len) {
                        const within = lblock - e.block;
                        if (uninit) return .{ .phys = 0, .run = len - within };
                        const start = @as(u64, e.start_lo) | (@as(u64, e.start_hi) << 32);
                        return .{ .phys = start + within, .run = len - within };
                    }
                }
                // In a hole: it lasts until the next extent (or forever).
                return .{ .phys = 0, .run = (next_start orelse std.math.maxInt(u32) + 1) - lblock };
            }

            // Index node: descend into the last child starting at or before lblock.
            var child: ?ExtentIdx = null;
            for (0..hdr.entries) |i| {
                const e = std.mem.bytesAsValue(ExtentIdx, node_slice[12 + i * 12 ..][0..12]).*;
                if (e.block <= lblock) child = e else break;
            }
            const c = child orelse return .{ .phys = 0, .run = 1 };
            const blk = @as(u64, c.leaf_lo) | (@as(u64, c.leaf_hi) << 32);
            if (blk >= self.blocks_count) return error.Corrupt;
            try self.region.readAt(blk * self.block_size, self.node_buf);
            if (self.metadata_csum) {
                const h = std.mem.bytesAsValue(ExtentHeader, self.node_buf[0..12]).*;
                const tail = 12 + @as(usize, h.max) * 12;
                if (tail + 4 > self.node_buf.len) return error.Corrupt;
                const stored = std.mem.readInt(u32, self.node_buf[tail..][0..4], .little);
                if (crc.crc32cUpdate(self.inodeSeed(ino), self.node_buf[0..tail]) != stored)
                    return error.ChecksumMismatch;
            }
            node_slice = self.node_buf;
        }
    }

    fn indirectEntry(self: *Fs, block: u64, index: u64) Error!u64 {
        if (block == 0) return 0;
        if (block >= self.blocks_count) return error.Corrupt;
        if (self.ind_block != block) {
            try self.region.readAt(block * self.block_size, self.ind_buf);
            self.ind_block = block;
        }
        return std.mem.readInt(u32, self.ind_buf[index * 4 ..][0..4], .little);
    }

    fn mapBlockMap(self: *Fs, ino: *const Inode, lblock: u64) Error!Run {
        const per: u64 = self.block_size / 4;
        const ib = ino.iBlock();
        const slot = struct {
            fn get(b: *const [60]u8, i: usize) u64 {
                return std.mem.readInt(u32, b[i * 4 ..][0..4], .little);
            }
        }.get;
        var phys: u64 = 0;
        if (lblock < 12) {
            phys = slot(ib, @intCast(lblock));
        } else if (lblock < 12 + per) {
            phys = try self.indirectEntry(slot(ib, 12), lblock - 12);
        } else if (lblock < 12 + per + per * per) {
            const l = lblock - 12 - per;
            const first = try self.indirectEntry(slot(ib, 13), l / per);
            phys = try self.indirectEntry(first, l % per);
        } else {
            const l = lblock - 12 - per - per * per;
            if (l >= per * per * per) return error.Corrupt;
            const a = try self.indirectEntry(slot(ib, 14), l / (per * per));
            const b = try self.indirectEntry(a, (l / per) % per);
            phys = try self.indirectEntry(b, l % per);
        }
        if (phys != 0 and phys >= self.blocks_count) return error.Corrupt;
        return .{ .phys = phys, .run = 1 };
    }

    fn mapBlock(self: *Fs, ino: *const Inode, lblock: u64) Error!Run {
        if (ino.flags & flag_extents != 0) return self.mapExtents(ino, lblock);
        return self.mapBlockMap(ino, lblock);
    }

    // ---- reading file contents ------------------------------------------

    /// Reads up to `buf.len` bytes of the file at `offset`; returns the count
    /// (short only at end of file). Holes read as zeros.
    pub fn readAt(self: *Fs, ino: *const Inode, offset: u64, buf: []u8) Error!usize {
        if (offset >= ino.size) return 0;
        const want: usize = @intCast(@min(@as(u64, buf.len), ino.size - offset));
        if (ino.flags & flag_inline_data != 0) {
            var tmp: [max_inode_size + 64]u8 = undefined;
            const data = try self.inlineData(ino, &tmp);
            if (offset >= data.len) return 0;
            const n = @min(want, data.len - @as(usize, @intCast(offset)));
            @memcpy(buf[0..n], data[@intCast(offset)..][0..n]);
            return n;
        }
        var done: usize = 0;
        while (done < want) {
            const pos = offset + done;
            const lblock = pos / self.block_size;
            const in_block: usize = @intCast(pos % self.block_size);
            const r = try self.mapBlock(ino, lblock);
            const avail: u64 = r.run * self.block_size - in_block;
            const n: usize = @intCast(@min(@as(u64, want - done), avail));
            if (r.phys == 0) {
                @memset(buf[done..][0..n], 0);
            } else if (r.run > 1 or ino.flags & flag_extents != 0) {
                try self.region.readAt(r.phys * self.block_size + in_block, buf[done..][0..n]);
            } else {
                // Block-mapped files return runs of 1; merge physically
                // adjacent blocks so a big file isn't read block by block.
                var blocks: u64 = 1;
                const max_blocks = (in_block + (want - done) + self.block_size - 1) / self.block_size;
                while (blocks < max_blocks) : (blocks += 1) {
                    const nx = try self.mapBlock(ino, lblock + blocks);
                    if (nx.phys != r.phys + blocks) break;
                }
                const m: usize = @intCast(@min(@as(u64, want - done), blocks * self.block_size - in_block));
                try self.region.readAt(r.phys * self.block_size + in_block, buf[done..][0..m]);
                done += m;
                continue;
            }
            done += n;
        }
        return want;
    }

    /// Inline-data files keep the first 60 bytes in `i_block` and the rest in
    /// the in-inode extended attribute `system.data`.
    fn inlineData(self: *const Fs, ino: *const Inode, out: []u8) Error![]const u8 {
        const first = @min(ino.size, 60);
        @memcpy(out[0..first], ino.iBlock()[0..first]);
        if (ino.size <= 60) return out[0..first];

        if (self.inode_size <= 128) return error.Corrupt;
        const extra = std.mem.readInt(u16, ino.raw[128..130], .little);
        const ibody = 128 + @as(usize, extra);
        if (ibody + 4 > self.inode_size) return error.Corrupt;
        if (std.mem.readInt(u32, ino.raw[ibody..][0..4], .little) != 0xEA020000) return error.Corrupt;
        const entries = ibody + 4;
        var p = entries;
        while (p + 16 <= self.inode_size) {
            const name_len = ino.raw[p];
            const name_index = ino.raw[p + 1];
            if (name_len == 0 and name_index == 0) break;
            const value_off = std.mem.readInt(u16, ino.raw[p + 2 ..][0..2], .little);
            const value_size = std.mem.readInt(u32, ino.raw[p + 8 ..][0..4], .little);
            if (p + 16 + name_len > self.inode_size) return error.Corrupt;
            const name = ino.raw[p + 16 ..][0..name_len];
            if (name_index == 7 and std.mem.eql(u8, name, "data")) {
                if (entries + value_off + value_size > self.inode_size) return error.Corrupt;
                const total = first + value_size;
                if (ino.size != total or total > out.len) return error.Corrupt;
                @memcpy(out[first..][0..value_size], ino.raw[entries + value_off ..][0..value_size]);
                return out[0..total];
            }
            p += (16 + name_len + 3) & ~@as(usize, 3);
        }
        return error.Corrupt;
    }

    // ---- directories ----------------------------------------------------

    /// Calls `cb(ctx, entry)` for every live entry in `dir` (including "." and
    /// ".."), stopping early if it returns true.
    pub fn walkDir(self: *Fs, dir: *const Inode, ctx: anytype, comptime cb: anytype) Error!void {
        if (!dir.isDir()) return error.NotDirectory;
        if (dir.flags & flag_inline_data != 0) return self.walkInlineDir(dir, ctx, cb);

        const bs = self.block_size;
        const blocks = (dir.size + bs - 1) / bs;
        var lblock: u64 = 0;
        while (lblock < blocks) : (lblock += 1) {
            const r = try self.mapBlock(dir, lblock);
            if (r.phys == 0) continue;
            const block = self.node_buf;
            try self.region.readAt(r.phys * bs, block);
            if (self.metadata_csum) try self.verifyDirBlock(dir, block);
            if (try walkBlockEntries(block, ctx, cb)) return;
        }
    }

    fn verifyDirBlock(self: *const Fs, dir: *const Inode, block: []const u8) Error!void {
        // Leaf blocks end in a 12-byte tail: inode 0, rec_len 12, type 0xDE.
        // Interior htree blocks have a different tail and are not checked.
        const t = block.len - 12;
        const is_tail = std.mem.readInt(u32, block[t..][0..4], .little) == 0 and
            std.mem.readInt(u16, block[t + 4 ..][0..2], .little) == 12 and
            block[t + 6] == 0 and block[t + 7] == 0xDE;
        if (!is_tail) return;
        const stored = std.mem.readInt(u32, block[t + 8 ..][0..4], .little);
        if (crc.crc32cUpdate(self.inodeSeed(dir), block[0..t]) != stored) return error.ChecksumMismatch;
    }

    /// Returns true if the callback asked to stop.
    fn walkBlockEntries(block: []const u8, ctx: anytype, comptime cb: anytype) Error!bool {
        var p: usize = 0;
        while (p + 8 <= block.len) {
            const inode = std.mem.readInt(u32, block[p..][0..4], .little);
            var rec_len: usize = std.mem.readInt(u16, block[p + 4 ..][0..2], .little);
            if (rec_len == 0 or (rec_len == 65535 and block.len == 65536)) rec_len = block.len;
            const name_len = block[p + 6];
            if (rec_len < 8 or rec_len % 4 != 0 or p + rec_len > block.len or 8 + @as(usize, name_len) > rec_len)
                return error.Corrupt;
            if (inode != 0 and name_len != 0) {
                if (cb(ctx, DirEntry{
                    .inode = inode,
                    .name = block[p + 8 ..][0..name_len],
                    .file_type = block[p + 7],
                })) return true;
            }
            p += rec_len;
        }
        return false;
    }

    fn walkInlineDir(self: *Fs, dir: *const Inode, ctx: anytype, comptime cb: anytype) Error!void {
        var tmp: [max_inode_size + 64]u8 = undefined;
        const data = try self.inlineData(dir, &tmp);
        if (data.len < 4) return error.Corrupt;
        const parent = std.mem.readInt(u32, data[0..4], .little);
        // The format stores "." and ".." implicitly: synthesize them.
        if (cb(ctx, DirEntry{ .inode = dir.number, .name = ".", .file_type = 2 })) return;
        if (cb(ctx, DirEntry{ .inode = parent, .name = "..", .file_type = 2 })) return;
        _ = try walkBlockEntries(data[4..], ctx, cb);
    }

    // ---- path lookup ----------------------------------------------------

    const Find = struct { name: []const u8, found: ?u32 = null };

    fn findCb(f: *Find, e: DirEntry) bool {
        if (std.mem.eql(u8, e.name, f.name)) {
            f.found = e.inode;
            return true;
        }
        return false;
    }

    /// Looks `name` up in `dir` (one path component).
    pub fn lookupIn(self: *Fs, dir: *const Inode, name: []const u8) Error!Inode {
        var f = Find{ .name = name };
        try self.walkDir(dir, &f, findCb);
        return self.readInode(f.found orelse return error.NotFound);
    }

    /// Resolves an absolute path, following symlinks (also in the last
    /// component). Components are matched exactly (case-sensitive).
    pub fn lookup(self: *Fs, path: []const u8) Error!Inode {
        var links: u32 = 0;
        const root = try self.readInode(root_inode);
        return self.resolveFrom(root, path, &links);
    }

    /// Walks `path` starting at directory `start`. A symlink target is
    /// resolved from the directory holding the link, or from the root if the
    /// target is absolute.
    fn resolveFrom(self: *Fs, start: Inode, path: []const u8, links: *u32) Error!Inode {
        var cur = start;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |comp| {
            if (comp.len > 255) return error.NameTooLong;
            if (std.mem.eql(u8, comp, ".")) continue;
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
            const base = if (target.len > 0 and target[0] == '/') try self.readInode(root_inode) else cur;
            cur = try self.resolveFrom(base, target, links);
        }
        return cur;
    }

    /// Reads a symlink's target into `buf`.
    pub fn readLink(self: *Fs, ino: *const Inode, buf: []u8) Error![]const u8 {
        if (!ino.isSymlink()) return error.Corrupt;
        if (ino.size > buf.len) return error.NameTooLong;
        const n = try self.readAtLink(ino, buf[0..@intCast(ino.size)]);
        return buf[0..n];
    }

    fn readAtLink(self: *Fs, ino: *const Inode, buf: []u8) Error!usize {
        // Short ("fast") symlinks keep the target in i_block and own no data
        // blocks, so i_blocks is zero. Everything else reads like a file.
        if (ino.flags & flag_inline_data == 0 and ino.size < 60 and self.isFastSymlink(ino)) {
            @memcpy(buf, ino.iBlock()[0..buf.len]);
            return buf.len;
        }
        return self.readAt(ino, 0, buf);
    }

    fn isFastSymlink(self: *const Fs, ino: *const Inode) bool {
        _ = self;
        // i_blocks_lo at offset 28: zero when the target is stored in i_block.
        // (A fast symlink on a fs with an EA block would count it; rare.)
        return std.mem.readInt(u32, ino.raw[28..32], .little) == 0;
    }
};
