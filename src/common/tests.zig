//! Tests against images built by the real mkfs and partitioning tools
//! (tests/images/make-fixtures.sh). Every file in each filesystem image is
//! read back through dklilo's reader and compared with the original by
//! SHA-256, using the manifest the script wrote from the source tree.

const std = @import("std");
const blockdev = @import("blockdev.zig");
const part = @import("part.zig");
const devio = @import("devio.zig");
const fsread = @import("fsread");
const ext4 = fsread.ext4;
const fs_mod = fsread.fs;
const btrfs = fsread.btrfs;
const fat = fsread.fat;
const test_options = @import("test_options");

const manifest = @embedFile("manifest.txt");
const manifest_fat = @embedFile("manifest-fat.txt");
const gpa = std.testing.allocator;

fn disk(data: []const u8) blockdev.MemDisk {
    return .{ .data = data };
}

/// Checks every manifest file by hash and size through the generic `fs.Fs`.
fn checkDisk(dev: blockdev.BlockDev) !void {
    var fs = try fs_mod.Fs.open(gpa, devio.fromRegion(&dev, dev.whole()));
    defer fs.deinit();
    try checkFs(&fs, null);
}

/// `prefix` is prepended to manifest paths (for subvolume images).
fn checkFs(fs: *fs_mod.Fs, only_prefix: ?[]const u8) !void {
    return checkFsWith(fs, manifest, only_prefix);
}

fn checkFsWith(fs: *fs_mod.Fs, manifest_text: []const u8, only_prefix: ?[]const u8) !void {
    var lines = std.mem.tokenizeScalar(u8, manifest_text, '\n');
    var count: usize = 0;
    const buf = try gpa.alloc(u8, 6 * 1024 * 1024);
    defer gpa.free(buf);
    while (lines.next()) |line| {
        var f = std.mem.tokenizeSequence(u8, line, "  ");
        const want_hash = f.next().?;
        const want_size = try std.fmt.parseInt(u64, f.next().?, 10);
        const path = f.next().?;
        if (only_prefix) |pre| if (!std.mem.startsWith(u8, path, pre)) continue;

        const file = try fs.lookup(path);
        try std.testing.expect(file.is_regular);
        try std.testing.expectEqual(want_size, file.size);
        const n = try fs.readAt(&file, 0, buf);
        try std.testing.expectEqual(@as(usize, @intCast(want_size)), n);

        var h: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(buf[0..n], &h, .{});
        const hex = std.fmt.bytesToHex(h, .lower);
        std.testing.expectEqualStrings(want_hash, &hex) catch |e| {
            std.debug.print("hash mismatch for {s}\n", .{path});
            return e;
        };
        count += 1;
    }
    try std.testing.expect(count > 1400 or only_prefix != null);
}

fn checkImage(image: []const u8) !void {
    var d = disk(image);
    try checkDisk(d.blockDev());
}

/// Up to 16 byte overwrites, applied to data as it is read.
const Patches = struct {
    off: [16]u64 = undefined,
    val: [16]u8 = undefined,
    n: usize = 0,

    fn apply(self: *const Patches, base: u64, buf: []u8) void {
        for (0..self.n) |i| {
            if (self.off[i] >= base and self.off[i] < base + buf.len) buf[@intCast(self.off[i] - base)] = self.val[i];
        }
    }
};

/// A disk image read from a file, for images too big to embed (sparse btrfs).
const FileDisk = struct {
    file: std.Io.File,
    sectors: u64,
    /// Optional damage: reads covering these offsets get that byte flipped.
    corrupt_at: ?u64 = null,
    corrupt_also: ?u64 = null,
    /// Byte overwrites applied to every read (used by the fuzz tests).
    patches: Patches = .{},
    bd: blockdev.BlockDev = undefined,

    fn open(name: []const u8) !FileDisk {
        var path_buf: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ test_options.fixtures_dir, name });
        const f = std.Io.Dir.cwd().openFile(std.testing.io, path, .{}) catch return error.SkipZigTest;
        return .{ .file = f, .sectors = (try f.length(std.testing.io)) / 512 };
    }
    fn close(self: *FileDisk) void {
        self.file.close(std.testing.io);
    }
    /// The whole image as a filesystem-reader region. `bd` keeps the device at
    /// a stable address for the `Io` the region carries.
    fn whole(self: *FileDisk) fsread.Region {
        self.bd = self.blockDev();
        return devio.fromRegion(&self.bd, self.bd.whole());
    }
    fn blockDev(self: *FileDisk) blockdev.BlockDev {
        return .{ .ctx = self, .readSectorsFn = read, .sector_size = 512, .sector_count = self.sectors };
    }
    fn read(ctx: *anyopaque, lba: u64, buf: []u8) blockdev.Error!void {
        const self: *FileDisk = @ptrCast(@alignCast(ctx));
        const off = lba * 512;
        const n = self.file.readPositionalAll(std.testing.io, buf, off) catch return error.IoError;
        if (n != buf.len) return error.IoError;
        self.patches.apply(off, buf);
        for ([_]?u64{ self.corrupt_at, self.corrupt_also }) |maybe| if (maybe) |c| {
            if (c >= off and c < off + buf.len) buf[@intCast(c - off)] ^= 0xFF;
        };
    }
};

fn checkFileImage(name: []const u8) !void {
    var d = try FileDisk.open(name);
    defer d.close();
    try checkDisk(d.blockDev());
}

test "ext4 4k blocks: every file matches" {
    try checkImage(@embedFile("ext4.img"));
}
test "ext4 1k blocks: every file matches" {
    try checkImage(@embedFile("ext4-1k.img"));
}
test "ext4 64bit: every file matches" {
    try checkImage(@embedFile("ext4-64bit.img"));
}
test "ext3 (block-mapped, journal): every file matches" {
    try checkImage(@embedFile("ext3.img"));
}
test "ext2 1k (block maps, indirect blocks): every file matches" {
    try checkImage(@embedFile("ext2.img"));
}
test "ext4 inline_data: every file matches" {
    try checkImage(@embedFile("ext4-inline.img"));
}

test "ext4: label, features, symlinks, holes, directories" {
    var d = disk(@embedFile("ext4.img"));
    var bd = d.blockDev();
    var fs = try ext4.Fs.open(gpa, devio.fromRegion(&bd, bd.whole()));
    defer fs.deinit();
    try std.testing.expectEqualStrings("dkltest", fs.label());
    try std.testing.expect(fs.metadata_csum);

    // Symlinks: relative, through a directory, absolute.
    const a = try fs.lookup("/boot/link-fast");
    try std.testing.expectEqual(@as(u64, 6), a.size);
    const b = try fs.lookup("/boot/link-dir");
    try std.testing.expectEqual(@as(u64, 7), b.size);
    const c = try fs.lookup("/boot/link-abs");
    try std.testing.expectEqual(@as(u64, 7), c.size);
    try std.testing.expectError(error.NotFound, fs.lookup("/boot/link-slow-dangling"));

    // Dot components and double slashes.
    _ = try fs.lookup("//boot/./sub/../hello.txt");
    try std.testing.expectError(error.NotFound, fs.lookup("/boot/nope"));
    try std.testing.expectError(error.NotDirectory, fs.lookup("/boot/hello.txt/x"));

    // The sparse file reads zeros in the hole.
    const sp = try fs.lookup("/boot/sparse");
    var buf: [4096]u8 = undefined;
    _ = try fs.readAt(&sp, 4096 * 100, &buf);
    try std.testing.expect(std.mem.allEqual(u8, &buf, 0));

    // A short read at the end of the file, and reading past it.
    const hello = try fs.lookup("/boot/hello.txt");
    var tiny: [100]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 6), try fs.readAt(&hello, 0, &tiny));
    try std.testing.expectEqualStrings("hello\n", tiny[0..6]);
    try std.testing.expectEqual(@as(usize, 0), try fs.readAt(&hello, 6, &tiny));

    // The 3000-entry directory lists every entry.
    const many = try fs.lookup("/many");
    var n: usize = 0;
    try fs.walkDir(&many, &n, struct {
        fn cb(cnt: *usize, e: ext4.DirEntry) bool {
            _ = e;
            cnt.* += 1;
            return false;
        }
    }.cb);
    try std.testing.expectEqual(@as(usize, 3002), n); // + "." and ".."
}

test "ext4: holes at the end of an extent-tree leaf don't hide later data" {
    const want = @embedFile("ext4-holes.bin");
    var d = disk(@embedFile("ext4-holes.img"));
    var bd = d.blockDev();
    var fs = try ext4.Fs.open(gpa, devio.fromRegion(&bd, bd.whole()));
    defer fs.deinit();
    const ino = try fs.lookup("/holes");
    try std.testing.expectEqual(@as(u64, want.len), ino.size);
    // The root extent header's depth (i_block is at inode offset 40). With a
    // shallower tree, or the holes filled in, this test would prove nothing.
    try std.testing.expect(std.mem.readInt(u16, ino.raw[46..48], .little) >= 2);

    const got = try gpa.alloc(u8, want.len);
    defer gpa.free(got);
    // The whole file in one call, then in pieces that start and end both in
    // data and in holes. The poison shows any byte that was left unwritten.
    for ([_]usize{ want.len, 7000, 1024 }) |step| {
        @memset(got, 0xAA);
        var off: usize = 0;
        while (off < want.len) : (off += step) {
            const n = @min(step, want.len - off);
            try std.testing.expectEqual(n, try fs.readAt(&ino, off, got[off..][0..n]));
        }
        try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfDiff(u8, want, got));
    }
}

test "ext4: a block past the 32-bit extent range is corrupt, not an endless hole" {
    var d = disk(@embedFile("ext4-holes.img"));
    var bd = d.blockDev();
    var fs = try ext4.Fs.open(gpa, devio.fromRegion(&bd, bd.whole()));
    defer fs.deinit();
    var ino = try fs.lookup("/holes");
    ino.size = std.math.maxInt(u64); // as a damaged i_size would claim
    var buf: [16]u8 = undefined;
    const past = (@as(u64, 1) << 32) * fs.block_size;
    try std.testing.expectError(error.Corrupt, fs.readAt(&ino, past, &buf));
}

test "ext4: corrupting metadata is reported, not ignored" {
    const orig = @embedFile("ext4.img");
    const copy = try gpa.dupe(u8, orig);
    defer gpa.free(copy);

    // Flip a bit in the superblock: checksum mismatch.
    copy[1024 + 100] ^= 1;
    var d = disk(copy);
    var bd = d.blockDev();
    try std.testing.expectError(error.ChecksumMismatch, ext4.Fs.open(gpa, devio.fromRegion(&bd, bd.whole())));
    copy[1024 + 100] ^= 1;

    // Bad magic.
    copy[1024 + 56] ^= 0xFF;
    try std.testing.expectError(error.BadMagic, ext4.Fs.open(gpa, devio.fromRegion(&bd, bd.whole())));
}

test "mbr: primaries, extended and logical partitions" {
    var d = disk(@embedFile("mbr.img"));
    const t = try part.read(d.blockDev());
    try std.testing.expectEqual(part.Kind.mbr, t.kind);
    try std.testing.expectEqual(@as(u32, 0x4a6f8c21), t.disk_signature);
    const p = t.slice();
    // 3 primaries + extended container + 2 logical.
    try std.testing.expectEqual(@as(usize, 6), p.len);
    try std.testing.expectEqual(@as(u8, 1), p[0].number);
    try std.testing.expectEqual(@as(u64, 2048), p[0].start_lba);
    try std.testing.expect(p[0].bootable);
    try std.testing.expectEqual(@as(u8, 0x83), p[0].mbr_type);
    try std.testing.expectEqual(@as(u8, 0x07), p[1].mbr_type);
    try std.testing.expectEqual(@as(u8, 0x0c), p[2].mbr_type);
    try std.testing.expectEqual(@as(u8, 5), p[4].number);
    try std.testing.expectEqual(@as(u8, 6), p[5].number);
    try std.testing.expectEqual(@as(u64, 4096), p[4].sector_count);
}

test "gpt: partitions, GUIDs, checksums" {
    var d = disk(@embedFile("gpt.img"));
    const t = try part.read(d.blockDev());
    try std.testing.expectEqual(part.Kind.gpt, t.kind);
    try std.testing.expectEqual(@as(usize, 2), t.count);
    var s: [36]u8 = undefined;
    part.formatGuid(t.parts[0].part_guid, &s);
    try std.testing.expectEqualStrings("11111111-2222-3333-4444-555555555555", &s);
    part.formatGuid(t.parts[1].type_guid, &s);
    try std.testing.expectEqualStrings("c12a7328-f81f-11d2-ba4b-00a0c93ec93b", &s);
    part.formatGuid(t.disk_guid, &s);
    try std.testing.expectEqualStrings("6a1e7c3e-9a01-4f6c-8b5d-0c2c0fd0a001", &s);
    try std.testing.expectEqual(@as(u64, 2048), t.parts[0].start_lba);
    try std.testing.expectEqual(@as(u64, 8192), t.parts[0].sector_count);
}

test "gpt: a damaged primary falls back to the backup" {
    const copy = try gpa.dupe(u8, @embedFile("gpt.img"));
    defer gpa.free(copy);
    copy[512 + 40] ^= 0xFF; // corrupt the primary header
    var d = disk(copy);
    const t = try part.read(d.blockDev());
    try std.testing.expectEqual(@as(usize, 2), t.count);
    // Corrupt the backup too: now it must fail.
    copy[copy.len - 512 + 40] ^= 0xFF;
    try std.testing.expectError(error.NoPartitionTable, part.read(d.blockDev()));
}

/// Cheap deterministic stand-in for the Zig fuzzer: damage random bytes of
/// the metadata area and walk the filesystem. Any outcome except a crash or
/// hang (errors included) is acceptable: a rescue disk meets damaged disks.
fn mutationRun(image: []const u8, seed: u64, iterations: usize) !void {
    const copy = try gpa.dupe(u8, image);
    defer gpa.free(copy);
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    const buf = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(buf);
    for (0..iterations) |_| {
        // Metadata lives in the first few hundred KiB of these small images.
        var saved: [24]struct { off: usize, val: u8 } = undefined;
        for (&saved) |*s| {
            s.off = rnd.uintLessThan(usize, 600 * 1024);
            s.val = copy[s.off];
            copy[s.off] = rnd.int(u8);
        }
        defer for (saved, 0..) |_, i| {
            const s = saved[saved.len - 1 - i];
            copy[s.off] = s.val;
        };
        var d = disk(copy);
        var bd = d.blockDev();
        var fs = ext4.Fs.open(gpa, devio.fromRegion(&bd, bd.whole())) catch continue;
        defer fs.deinit();
        for ([_][]const u8{ "/boot/hello.txt", "/boot/big.bin", "/boot/sparse", "/many", "/boot/link-dir" }) |path| {
            const ino = fs.lookup(path) catch continue;
            if (ino.isDir()) {
                var n: usize = 0;
                fs.walkDir(&ino, &n, struct {
                    fn cb(c: *usize, e: ext4.DirEntry) bool {
                        _ = e;
                        c.* += 1;
                        return c.* > 10_000;
                    }
                }.cb) catch {};
            } else {
                _ = fs.readAt(&ino, 0, buf) catch {};
            }
        }
    }
}

test "ext4: random metadata damage never crashes (checksummed)" {
    try mutationRun(@embedFile("ext4.img"), 1, 300);
}
test "ext4: random metadata damage never crashes (1k blocks)" {
    try mutationRun(@embedFile("ext4-1k.img"), 2, 300);
}
test "ext2: random metadata damage never crashes (no checksums)" {
    try mutationRun(@embedFile("ext2.img"), 3, 300);
}
test "ext4 inline: random metadata damage never crashes" {
    try mutationRun(@embedFile("ext4-inline.img"), 4, 300);
}

// ---- btrfs ---------------------------------------------------------------

test "btrfs: every file matches (no compression)" {
    try checkFileImage("btrfs.img");
}
test "btrfs: every file matches (zlib)" {
    try checkFileImage("btrfs-zlib.img");
}
test "btrfs: every file matches (lzo)" {
    try checkFileImage("btrfs-lzo.img");
}
test "btrfs: every file matches (zstd)" {
    try checkFileImage("btrfs-zstd.img");
}
test "btrfs: DUP profile" {
    try checkFileImage("btrfs-dup.img");
}

test "btrfs: compression is really in use" {
    // The compressible file must be stored compressed, or the tests above
    // would not exercise the decoders at all.
    for ([_][]const u8{ "btrfs-zlib.img", "btrfs-lzo.img", "btrfs-zstd.img" }) |name| {
        var d = try FileDisk.open(name);
        defer d.close();
        var fs = try btrfs.Fs.open(gpa, d.whole());
        defer fs.deinit();
        const ino = try fs.lookup("/boot/compressible.txt");
        try std.testing.expectEqual(@as(u64, 1000000), ino.size);
        const buf = try gpa.alloc(u8, 1000000);
        defer gpa.free(buf);
        try std.testing.expectEqual(@as(usize, 1000000), try fs.readAt(&ino, 0, buf));
        try std.testing.expect(fs.debug_decompressed > 0);
        try std.testing.expect(std.mem.startsWith(u8, buf, "the quick brown fox"));
    }
}

test "btrfs: reading an inline file doesn't disturb the cached extent" {
    for ([_][]const u8{ "btrfs-zlib.img", "btrfs-lzo.img", "btrfs-zstd.img" }) |name| {
        var d = try FileDisk.open(name);
        defer d.close();
        var fs = try btrfs.Fs.open(gpa, d.whole());
        defer fs.deinit();
        const big = try fs.lookup("/boot/compressible.txt");
        const small = try fs.lookup("/boot/compressible-inline.txt");
        var first: [4096]u8 = undefined;
        var inline_data: [1500]u8 = undefined;
        var again: [4096]u8 = undefined;
        _ = try fs.readAt(&big, 0, &first);
        const before = fs.debug_decompressed;
        _ = try fs.readAt(&small, 0, &inline_data);
        // The small file must be stored inline and compressed.
        try std.testing.expect(fs.debug_decompressed > before);
        _ = try fs.readAt(&big, 0, &again);
        try std.testing.expectEqualStrings(first[0..64], again[0..64]);
        try std.testing.expectEqualSlices(u8, &first, &again);
    }
}

test "btrfs: label, symlinks, dot-dot, holes, big directory" {
    var d = try FileDisk.open("btrfs.img");
    defer d.close();
    var fs = try btrfs.Fs.open(gpa, d.whole());
    defer fs.deinit();
    try std.testing.expectEqualStrings("dklbtrfs", fs.label());

    try std.testing.expectEqual(@as(u64, 6), (try fs.lookup("/boot/link-fast")).size);
    try std.testing.expectEqual(@as(u64, 7), (try fs.lookup("/boot/link-dir")).size);
    try std.testing.expectEqual(@as(u64, 7), (try fs.lookup("/boot/link-abs")).size);
    _ = try fs.lookup("/boot/sub/../hello.txt");
    try std.testing.expectError(error.NotFound, fs.lookup("/boot/nope"));
    try std.testing.expectError(error.NotDirectory, fs.lookup("/boot/hello.txt/x"));

    const sp = try fs.lookup("/boot/sparse");
    var buf: [4096]u8 = undefined;
    _ = try fs.readAt(&sp, 4096 * 100, &buf);
    try std.testing.expect(std.mem.allEqual(u8, &buf, 0));

    const many = try fs.lookup("/many");
    var n: usize = 0;
    try fs.walkDir(&many, &n, struct {
        fn cb(cnt: *usize, e: btrfs.DirEntry) bool {
            _ = e;
            cnt.* += 1;
            return false;
        }
    }.cb);
    try std.testing.expectEqual(@as(usize, 3002), n);
}

test "btrfs: subvolumes (crossing, selecting, default)" {
    {
        var d = try FileDisk.open("btrfs-subvol.img");
        defer d.close();
        var fs = try fs_mod.Fs.open(gpa, d.whole());
        defer fs.deinit();
        // /boot is its own subvolume; paths through it still resolve.
        try checkFs(&fs, "/boot/");
        // Selecting it makes it the root.
        try fs.selectSubvolume("boot");
        const f = try fs.lookup("/hello.txt");
        try std.testing.expectEqual(@as(u64, 6), f.size);
        try std.testing.expectError(error.NotFound, fs.selectSubvolume("nope"));
    }
    {
        // `default:boot` makes the subvolume the default root.
        var d = try FileDisk.open("btrfs-default.img");
        defer d.close();
        var fs = try fs_mod.Fs.open(gpa, d.whole());
        defer fs.deinit();
        const f = try fs.lookup("/hello.txt");
        try std.testing.expectEqual(@as(u64, 6), f.size);
        // The top-level tree is still reachable by selecting it.
        try fs.selectSubvolume("/");
    }
}

test "btrfs: a damaged metadata copy falls back to the DUP mirror" {
    var d = try FileDisk.open("btrfs-dup.img");
    defer d.close();
    var probe = try btrfs.Fs.open(gpa, d.whole());
    var phys: [4]u64 = undefined;
    const copies = try probe.mapLogical(probe.root_tree, probe.nodesize, &phys);
    probe.deinit();
    try std.testing.expect(copies >= 2);

    // Corrupt the first copy of the root tree block.
    d.corrupt_at = phys[0] + 200;
    var fs = try fs_mod.Fs.open(gpa, d.whole());
    defer fs.deinit();
    try checkFs(&fs, "/boot/sub/");

    // Corrupt both copies: opening must fail, not return garbage.
    d.corrupt_at = phys[0] + 200;
    d.corrupt_also = phys[1] + 200;
    try std.testing.expectError(error.ChecksumMismatch, btrfs.Fs.open(gpa, d.whole()));
}

test "btrfs: random metadata damage never crashes" {
    var d = try FileDisk.open("btrfs-zstd.img");
    defer d.close();
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    for (0..40) |_| {
        // Metadata lives in a few small regions of the sparse image; flip a
        // byte in a block the filesystem reads often (the tree blocks).
        d.corrupt_at = 0x10000 + rnd.uintLessThan(u64, 4096); // superblock
        var fs = btrfs.Fs.open(gpa, d.whole()) catch continue;
        fs.deinit();
    }
    d.corrupt_at = null;
    var fs = try btrfs.Fs.open(gpa, d.whole());
    defer fs.deinit();
    const root = fs.root_tree;
    var phys: [4]u64 = undefined;
    _ = try fs.mapLogical(root, fs.nodesize, &phys);
    for (0..60) |_| {
        d.corrupt_at = phys[0] + rnd.uintLessThan(u64, fs.nodesize);
        _ = fs.lookup("/boot/hello.txt") catch {};
        _ = fs.lookup("/many") catch {};
    }
}

// ---- ISO 9660 ------------------------------------------------------------

test "iso9660 + Rock Ridge: every file matches" {
    var d = try FileDisk.open("iso.img");
    defer d.close();
    var dev = d.blockDev();
    dev.sector_size = 512;
    try checkDisk(dev);
}

test "iso9660: label, symlinks, long names, big directory, case" {
    var d = try FileDisk.open("iso.img");
    defer d.close();
    var fs = try fs_mod.Fs.open(gpa, d.whole());
    defer fs.deinit();
    try std.testing.expectEqualStrings("DKLISO", fs.label());
    // Rock Ridge symlinks (relative and absolute) resolve.
    try std.testing.expectEqual(@as(u64, 6), (try fs.lookup("/boot/link-fast")).size);
    try std.testing.expectEqual(@as(u64, 7), (try fs.lookup("/boot/link-dir")).size);
    try std.testing.expectEqual(@as(u64, 7), (try fs.lookup("/boot/link-abs")).size);
    // 255-character name (needs NM continuation) and 3000-entry directory.
    var long: [255]u8 = undefined;
    @memset(&long, 'n');
    var path_buf: [300]u8 = undefined;
    const lp = try std.fmt.bufPrint(&path_buf, "/boot/sub/{s}", .{long});
    try std.testing.expectEqual(@as(u64, 5), (try fs.lookup(lp)).size);
    try std.testing.expectEqual(@as(u64, 5), (try fs.lookup("/many/file-with-a-longish-name-7")).size);
    try std.testing.expectError(error.NotFound, fs.lookup("/boot/nope"));
    try std.testing.expectError(error.NotDirectory, fs.lookup("/boot/hello.txt/x"));
}

// ---- FAT -----------------------------------------------------------------

fn checkFat(name: []const u8, kind: fat.Kind) !void {
    var d = try FileDisk.open(name);
    defer d.close();
    var fs = try fs_mod.Fs.open(gpa, d.whole());
    defer fs.deinit();
    try std.testing.expectEqual(kind, fs.fat.kind);
    try std.testing.expectEqualStrings("DKLFAT", fs.label());
    try checkFsWith(&fs, manifest_fat, null);
}

test "fat12: every file matches (long names, 3000-entry directory)" {
    try checkFat("fat12.img", .fat12);
}
test "fat16: every file matches" {
    try checkFat("fat16.img", .fat16);
}
test "fat32: every file matches" {
    try checkFat("fat32.img", .fat32);
}

test "fat: case-insensitive names, dot-dot, backslashes, and errors" {
    var d = try FileDisk.open("fat16.img");
    defer d.close();
    var fs = try fs_mod.Fs.open(gpa, d.whole());
    defer fs.deinit();
    try std.testing.expectEqual(@as(u64, 6), (try fs.lookup("/BOOT/HELLO.TXT")).size);
    try std.testing.expectEqual(@as(u64, 6), (try fs.lookup("\\boot\\sub\\..\\hello.txt")).size);
    try std.testing.expectEqual(@as(u64, 7), (try fs.lookup("/boot/sub/deeper/file")).size);
    try std.testing.expectError(error.NotFound, fs.lookup("/boot/nope"));
    try std.testing.expectError(error.NotDirectory, fs.lookup("/boot/hello.txt/x"));
    // The sparse file's hole is real zeros on FAT.
    const sp = try fs.lookup("/boot/sparse");
    var buf: [4096]u8 = undefined;
    _ = try fs.readAt(&sp, 4096 * 100, &buf);
    try std.testing.expect(std.mem.allEqual(u8, &buf, 0));
}

test "fat: random damage to the boot sector and directories never crashes" {
    var d = try FileDisk.open("fat32.img");
    defer d.close();
    var prng = std.Random.DefaultPrng.init(11);
    const rnd = prng.random();
    for (0..60) |_| {
        d.corrupt_at = rnd.uintLessThan(u64, 64 * 1024);
        var fs = fs_mod.Fs.open(gpa, d.whole()) catch continue;
        defer fs.deinit();
        _ = fs.lookup("/boot/hello.txt") catch {};
        if (fs.lookup("/many")) |m| {
            var n: usize = 0;
            switch (fs) {
                .fat => |*f| f.walkDir(&m.impl.fat, &n, struct {
                    fn cb(c: *usize, e: fat.DirEntry) bool {
                        _ = e;
                        c.* += 1;
                        return c.* > 5000;
                    }
                }.cb) catch {},
                else => {},
            }
        } else |_| {}
    }
}

// ---- damaged and hostile metadata (docs/bugs FS-03 to FS-07) ----------------
//
// Each test changes a value on a good image. The reader must return an error:
// never crash, loop, or hand back bytes from outside the filesystem. The whole
// file also runs as a 32-bit build (see build.zig), like the BIOS loader.

/// A fixture image loaded into memory, so that a test can damage it.
fn loadFixture(name: []const u8) ![]u8 {
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ test_options.fixtures_dir, name });
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(200 << 20)) catch |e| switch (e) {
        error.FileNotFound => error.SkipZigTest, // the optional btrfs images
        else => e,
    };
}

fn put(comptime T: type, bytes: []u8, off: usize, value: T) void {
    std.mem.writeInt(T, bytes[off..][0..@sizeOf(T)], value, .little);
}

fn get(comptime T: type, bytes: []const u8, off: usize) T {
    return std.mem.readInt(T, bytes[off..][0..@sizeOf(T)], .little);
}

test "ext4: 128-byte group descriptors are read, and checksummed whole" {
    const img = try loadFixture("ext4-desc128.img");
    defer gpa.free(img);
    try std.testing.expectEqual(@as(u16, 128), get(u16, img, 1024 + 254)); // s_desc_size
    try checkImage(img);
    // Damage the second half of descriptor 0 (block 1): the checksum covers it.
    img[4096 + 100] ^= 1;
    var d = disk(img);
    var bd = d.blockDev();
    var fs = try ext4.Fs.open(gpa, devio.fromRegion(&bd, bd.whole()));
    defer fs.deinit();
    try std.testing.expectError(error.ChecksumMismatch, fs.readInode(ext4.root_inode));
}

test "ext4: a descriptor size larger than the descriptor doesn't overflow" {
    const img = try loadFixture("ext4-nocsum.img");
    defer gpa.free(img);
    put(u16, img, 1024 + 254, 4096); // the largest value the format allows
    var d = disk(img);
    var bd = d.blockDev();
    var fs = try ext4.Fs.open(gpa, devio.fromRegion(&bd, bd.whole()));
    defer fs.deinit();
    // Descriptor 0 still starts where it did, so the volume stays readable.
    try std.testing.expectEqual(@as(u64, 20000), (try fs.lookup("/f")).size);
}

test "ext4: an inode table far outside the volume is corrupt" {
    const img = try loadFixture("ext4-nocsum.img");
    defer gpa.free(img);
    put(u32, img, 4096 + 40, 0xFFFF_FFFF); // bg_inode_table_hi of group 0
    var d = disk(img);
    var bd = d.blockDev();
    var fs = try ext4.Fs.open(gpa, devio.fromRegion(&bd, bd.whole()));
    defer fs.deinit();
    try std.testing.expectError(error.Corrupt, fs.lookup("/f"));
}

test "ext4: a block count too large to address is corrupt" {
    const img = try loadFixture("ext4-nocsum.img");
    defer gpa.free(img);
    put(u32, img, 1024 + 0x150, 0xFFFF_FFFF); // s_blocks_count_hi
    var d = disk(img);
    var bd = d.blockDev();
    try std.testing.expectError(error.Corrupt, ext4.Fs.open(gpa, devio.fromRegion(&bd, bd.whole())));
}

test "ext4: an extent pointing outside the filesystem is corrupt" {
    const img = try loadFixture("ext4-nocsum.img");
    defer gpa.free(img);
    // A partition bigger than the filesystem in it, as after a shrink: the
    // blocks past the end can be read, but they are not the file's.
    const bigger = try gpa.alloc(u8, img.len + (1 << 20));
    defer gpa.free(bigger);
    @memset(bigger, 0x5A);
    @memcpy(bigger[0..img.len], img);
    var d = disk(bigger);
    var bd = d.blockDev();
    var fs = try ext4.Fs.open(gpa, devio.fromRegion(&bd, bd.whole()));
    defer fs.deinit();
    const good = try fs.lookup("/f");
    var buf: [4096]u8 = undefined;
    // The first extent in the inode: i_block + 12 byte header, then
    // block(4) len(2) start_hi(2) start_lo(4).
    for ([_]struct { hi: u16, lo: u32 }{
        .{ .hi = 0, .lo = @intCast(fs.blocks_count) }, // just past the end
        .{ .hi = 0, .lo = @intCast(fs.blocks_count - 1) }, // runs past the end
        .{ .hi = 0xFFFF, .lo = 0 }, // far past it
        .{ .hi = 0, .lo = 0 }, // an allocated extent at block 0
    }) |start| {
        var ino = good;
        put(u16, &ino.raw, 40 + 12 + 6, start.hi);
        put(u32, &ino.raw, 40 + 12 + 8, start.lo);
        try std.testing.expectError(error.Corrupt, fs.readAt(&ino, 0, &buf));
    }
}

test "ext4: an impossible directory size is corrupt" {
    const img = try loadFixture("ext4-nocsum.img");
    defer gpa.free(img);
    var d = disk(img);
    var bd = d.blockDev();
    var fs = try ext4.Fs.open(gpa, devio.fromRegion(&bd, bd.whole()));
    defer fs.deinit();
    var dir = try fs.lookup("/");
    dir.size = std.math.maxInt(u64);
    try std.testing.expectError(error.Corrupt, fs.lookupIn(&dir, "absent"));
}

test "ext4: an inline-data length that overflows is corrupt" {
    const img = try loadFixture("ext4-inline.img");
    defer gpa.free(img);
    var d = disk(img);
    var bd = d.blockDev();
    var fs = try ext4.Fs.open(gpa, devio.fromRegion(&bd, bd.whole()));
    defer fs.deinit();
    // Over 60 bytes, so part of it is in the `system.data` attribute.
    var ino = try fs.lookup("/boot/sub/deeper/file");
    ino.size = 100;
    const entries = 128 + @as(usize, get(u16, &ino.raw, 128)) + 4;
    put(u32, &ino.raw, entries - 4, 0xEA020000);
    ino.raw[entries] = 4; // name_len
    ino.raw[entries + 1] = 7; // name index "system."
    put(u16, &ino.raw, entries + 2, 20); // value offset
    put(u32, &ino.raw, entries + 8, 0xFFFF_FFF0); // value size
    @memcpy(ino.raw[entries + 16 ..][0..4], "data");
    var buf: [256]u8 = undefined;
    try std.testing.expectError(error.Corrupt, fs.readAt(&ino, 0, &buf));
}

test "a file too big for the address space is an error, not a crash" {
    // Only a 32-bit build can't hold the size in a `usize`.
    if (@sizeOf(usize) > 4) return error.SkipZigTest;
    const img = try loadFixture("ext4-huge.img");
    defer gpa.free(img);
    var d = disk(img);
    var set = @import("volumes.zig").Set.init(gpa);
    defer set.deinit();
    const vol = try set.addDisk(d.blockDev());
    _ = vol;
    try std.testing.expectError(error.OutOfMemory, set.readFile(&set.vols.items[0], "/huge"));
}

/// Applies `change` to every btrfs tree block it accepts and fixes that
/// block's checksum, so the reader believes the new contents. Every copy of a
/// block (DUP) is changed the same way.
fn patchBtrfs(img: []u8, context: anytype, comptime change: anytype) !void {
    const nodesize = get(u32, img, 0x10000 + 0x94);
    var fsid: [16]u8 = undefined;
    @memcpy(&fsid, img[0x10000 + 0x20 ..][0..16]);
    var changed: usize = 0;
    var off: usize = 0x20000;
    while (off + nodesize <= img.len) : (off += 4096) {
        const block = img[off..][0..nodesize];
        if (!std.mem.eql(u8, block[32..48], &fsid)) continue;
        if (~fsread.crc.crc32cUpdate(0xFFFFFFFF, block[32..]) != get(u32, block, 0)) continue;
        if (!change(context, block)) continue;
        put(u32, block, 0, ~fsread.crc.crc32cUpdate(0xFFFFFFFF, block[32..]));
        changed += 1;
    }
    try std.testing.expect(changed > 0);
}

const btrfs_nritems = 96;
const btrfs_level = 100;
const btrfs_header = 101;
const btrfs_item = 25; // key (17), data offset (4), data size (4)

/// One field of every item of type `kind` belonging to inode `ino`.
const ItemPatch = struct {
    ino: u64,
    kind: u8,
    /// Which file offset's item (the key offset); null for any.
    at: ?u64 = null,
    /// Byte offset in the item's data of a u64 to overwrite.
    field: usize = 0,
    value: u64 = 0,
    /// Instead of the data, replace the item's own data offset and size.
    location: ?struct { offset: u32, size: u32 } = null,

    fn apply(p: ItemPatch, block: []u8) bool {
        if (block[btrfs_level] != 0) return false;
        var hit = false;
        for (0..get(u32, block, btrfs_nritems)) |i| {
            const it = btrfs_header + i * btrfs_item;
            if (it + btrfs_item > block.len) break;
            if (get(u64, block, it) != p.ino or block[it + 8] != p.kind) continue;
            if (p.at) |at| if (get(u64, block, it + 9) != at) continue;
            if (p.location) |l| {
                put(u32, block, it + 17, l.offset);
                put(u32, block, it + 21, l.size);
            } else put(u64, block, btrfs_header + get(u32, block, it + 17) + p.field, p.value);
            hit = true;
        }
        return hit;
    }
};

const extent_data = 108;

/// Damages one item of `path` in a copy of `image`, then reads the file at
/// `offset` and expects `error.Corrupt`.
fn expectBadItem(image: []const u8, path: []const u8, patch_in: ItemPatch, offset: u64) !void {
    const img = try loadFixture(image);
    defer gpa.free(img);
    var d = disk(img);
    var bd = d.blockDev();
    var patch = patch_in;
    {
        var fs = try btrfs.Fs.open(gpa, devio.fromRegion(&bd, bd.whole()));
        defer fs.deinit();
        patch.ino = (try fs.lookup(path)).ino;
    }
    try patchBtrfs(img, patch, ItemPatch.apply);
    var fs = try btrfs.Fs.open(gpa, devio.fromRegion(&bd, bd.whole()));
    defer fs.deinit();
    const result = blk: {
        const ino = fs.lookup(path) catch |e| break :blk e;
        var buf: [8192]u8 = undefined;
        break :blk fs.readAt(&ino, offset, &buf);
    };
    try std.testing.expectError(error.Corrupt, result);
}

test "btrfs: an extent length that overflows is corrupt" {
    // The second extent of the 5 MB file starts at 1 MiB.
    const at = 1 << 20;
    try expectBadItem("btrfs.img", "/boot/big.bin", .{
        .ino = 0,
        .kind = extent_data,
        .at = at,
        .field = 45, // num_bytes
        .value = std.math.maxInt(u64),
    }, at);
}

test "btrfs: an extent address that overflows is corrupt" {
    try expectBadItem("btrfs.img", "/boot/medium.bin", .{
        .ino = 0,
        .kind = extent_data,
        .field = 21, // disk_bytenr
        .value = std.math.maxInt(u64) - 10,
    }, 100);
}

test "btrfs: an offset into a compressed extent that overflows is corrupt" {
    for ([_]u64{ std.math.maxInt(u64), 1 << 32, 0xFFFF_FF00 }) |value| {
        try expectBadItem("btrfs-zstd.img", "/boot/compressible.txt", .{
            .ino = 0,
            .kind = extent_data,
            .at = 0,
            .field = 37, // offset within the extent
            .value = value,
        }, 100);
    }
}

test "btrfs: item data outside its leaf is corrupt" {
    // On 32 bits, header + offset + size wraps around to something small.
    try expectBadItem("btrfs.img", "/boot/medium.bin", .{
        .ino = 0,
        .kind = extent_data,
        .location = .{ .offset = 0xFFFF_F000, .size = 0x2000 },
    }, 0);
    try expectBadItem("btrfs.img", "/boot/medium.bin", .{
        .ino = 0,
        .kind = 1, // the inode item
        .location = .{ .offset = 0xFFFF_F000, .size = 0x2000 },
    }, 0);
}

/// Gives every block at `leaf` level (or above it) an item count whose byte
/// length wraps to a few bytes in 32 bits.
fn hugeCount(leaf: bool, block: []u8) bool {
    if ((block[btrfs_level] == 0) != leaf) return false;
    // 25 * 0x0A3D70A4 = 2^32 + 4, and 33 * 0x07C1F07D = 2^32 + 29.
    put(u32, block, btrfs_nritems, if (leaf) 0x0A3D70A4 else 0x07C1F07D);
    return true;
}

test "btrfs: an impossible item count is corrupt" {
    for ([_]bool{ true, false }) |leaf| {
        const img = try loadFixture("btrfs.img");
        defer gpa.free(img);
        try patchBtrfs(img, leaf, hugeCount);
        var d = disk(img);
        var bd = d.blockDev();
        const result = blk: {
            var fs = btrfs.Fs.open(gpa, devio.fromRegion(&bd, bd.whole())) catch |e| break :blk e;
            defer fs.deinit();
            break :blk if (fs.lookup("/many/file-with-a-longish-name-7")) |_| {} else |e| e;
        };
        try std.testing.expectError(error.Corrupt, result);
    }
}

test "btrfs: chunk addresses that overflow don't crash" {
    const img = try loadFixture("btrfs.img");
    defer gpa.free(img);
    var d = disk(img);
    var bd = d.blockDev();
    var fs = try btrfs.Fs.open(gpa, devio.fromRegion(&bd, bd.whole()));
    defer fs.deinit();
    const chunk = &fs.chunks[fs.chunks.len - 1];
    var out: [4]u64 = undefined;
    chunk.length = std.math.maxInt(u64);
    _ = try fs.mapLogical(chunk.logical + 4096, 4096, &out);
    for (fs.stripes) |*s| s.offset = std.math.maxInt(u64);
    try std.testing.expectError(error.Corrupt, fs.mapLogical(chunk.logical + 4096, 4096, &out));
}

test "fat: a boot sector whose sizes overflow is rejected" {
    var img: [4096]u8 = @splat(0);
    img[510] = 0x55;
    img[511] = 0xAA;
    put(u16, &img, 11, 512); // bytes per sector
    img[13] = 1; // sectors per cluster
    put(u16, &img, 14, 1); // reserved sectors
    img[16] = 2; // two FATs of 2^31 sectors each
    put(u16, &img, 19, 100);
    put(u32, &img, 36, 0x8000_0000);
    var d = disk(&img);
    var bd = d.blockDev();
    try std.testing.expectError(error.BadMagic, fat.Fs.open(gpa, devio.fromRegion(&bd, bd.whole())));
}

/// Where a FAT volume keeps things, read from its boot sector.
const FatLayout = struct {
    fat: usize,
    fat_bytes: usize,
    fats: usize,
    data: usize,
    cluster: usize,

    fn of(img: []const u8) FatLayout {
        const bps: usize = get(u16, img, 11);
        const short: usize = get(u16, img, 22);
        const sectors: usize = if (short != 0) short else get(u32, img, 36);
        const first = @as(usize, get(u16, img, 14)) * bps;
        const root = (@as(usize, get(u16, img, 17)) * 32 + bps - 1) / bps * bps;
        return .{
            .fat = first,
            .fat_bytes = sectors * bps,
            .fats = img[16],
            .data = first + img[16] * sectors * bps + root,
            .cluster = @as(usize, img[13]) * bps,
        };
    }

    /// Makes directory cluster `c` its own successor, with no end marker.
    fn loop(l: FatLayout, img: []u8, c: u32, wide: bool) void {
        for (0..l.fats) |n| {
            const table = l.fat + n * l.fat_bytes;
            if (wide) put(u32, img, table + c * 4, c) else put(u16, img, table + c * 2, @intCast(c));
        }
        var e = l.data + (c - 2) * l.cluster;
        const end = e + l.cluster;
        while (e < end) : (e += 32) img[e] = 0xE5; // deleted: keep reading
    }
};

test "fat: a directory whose cluster chain loops is corrupt, not a hang" {
    for ([_][]const u8{ "fat16.img", "fat32.img" }, [_]bool{ false, true }) |name, wide| {
        const img = try loadFixture(name);
        defer gpa.free(img);
        var d = disk(img);
        var bd = d.blockDev();
        var fs = try fat.Fs.open(gpa, devio.fromRegion(&bd, bd.whole()));
        defer fs.deinit();
        const dir = try fs.lookup("/boot/sub/deeper");
        FatLayout.of(img).loop(img, dir.cluster, wide);
        try std.testing.expectError(error.Corrupt, fs.lookup("/boot/sub/deeper/absent"));
    }
}

test "fat: an out-of-range first cluster is corrupt" {
    for ([_][]const u8{ "fat16.img", "fat32.img" }) |name| {
        const img = try loadFixture(name);
        defer gpa.free(img);
        var d = disk(img);
        var bd = d.blockDev();
        var fs = try fat.Fs.open(gpa, devio.fromRegion(&bd, bd.whole()));
        defer fs.deinit();
        for ([_]u32{ 1, fs.cluster_count + 2, 0x0FFF_FFF0 }) |cluster| {
            var dir = try fs.lookup("/boot/sub");
            dir.cluster = cluster;
            try std.testing.expectError(error.Corrupt, fs.lookupIn(&dir, "deeper"));
        }
    }
}

test "fat32: an out-of-range root cluster is corrupt" {
    const img = try loadFixture("fat32.img");
    defer gpa.free(img);
    put(u32, img, 44, 1);
    var d = disk(img);
    var bd = d.blockDev();
    var fs = try fat.Fs.open(gpa, devio.fromRegion(&bd, bd.whole()));
    defer fs.deinit();
    try std.testing.expectError(error.Corrupt, fs.lookup("/boot"));
}

// ---- fuzzing -----------------------------------------------------------------
//
// Run with `zig build test --fuzz=100K` for a real session. In an ordinary
// `zig build test` each target runs once, as a smoke test. The properties:
// whatever bytes are on the disk (or in the input), the readers return an
// error or valid data. They never crash, hang, read out of bounds or leak.

const fuzz_config = @import("config.zig");
const lzo = fsread.lzo;

fn fuzzConfig(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [1024]u8 = undefined;
    const n = smith.slice(&buf);
    var cfg = fuzz_config.parse(std.testing.allocator, buf[0..n], null) catch return;
    cfg.deinit();
}

test "fuzz: config parser" {
    try std.testing.fuzz({}, fuzzConfig, .{ .corpus = &.{
        "timeout = 50\nimage = /boot/vmlinuz\n  label = a\n  append = \"ro quiet\"\n",
        "other = windows\n  label = w\n",
    } });
}

fn fuzzLzo(_: void, smith: *std.testing.Smith) anyerror!void {
    var in: [512]u8 = undefined;
    const n = smith.slice(&in);
    var out: [8192]u8 = undefined;
    _ = lzo.decompress(in[0..n], &out) catch return;
}

test "fuzz: lzo decoder" {
    try std.testing.fuzz({}, fuzzLzo, .{});
}

const FuzzTarget = struct {
    disk: FileDisk,
    name: []const u8,
};

/// Fills `d.patches` from the fuzzer: a few byte overwrites, mostly in the
/// first megabytes where metadata lives.
fn fuzzPatches(d: *FileDisk, smith: *std.testing.Smith) void {
    d.patches.n = smith.valueRangeAtMost(u8, 0, 16);
    for (0..d.patches.n) |i| {
        d.patches.off[i] = smith.valueRangeLessThan(u32, 0, 4 * 1024 * 1024);
        d.patches.val[i] = smith.value(u8);
    }
}

fn exerciseFs(fs: *fs_mod.Fs) void {
    const paths = [_][]const u8{ "/boot/hello.txt", "/boot/big.bin", "/boot/link-dir", "/many/file-with-a-longish-name-7", "/boot/sparse" };
    var buf: [16 * 1024]u8 = undefined;
    for (paths) |p| {
        const f = fs.lookup(p) catch continue;
        _ = fs.readAt(&f, 0, &buf) catch {};
        _ = fs.readAt(&f, f.size / 2, &buf) catch {};
    }
    const dir = fs.lookup("/many") catch return;
    var count: usize = 0;
    const Counter = struct {
        fn stop(c: *usize) bool {
            c.* += 1;
            return c.* > 3000;
        }
    };
    switch (fs.*) {
        .ext4 => |*f| f.walkDir(&dir.impl.ext4, &count, struct {
            fn cb(c: *usize, e: ext4.DirEntry) bool {
                _ = e;
                return Counter.stop(c);
            }
        }.cb) catch {},
        .btrfs => |*f| f.walkDir(&dir.impl.btrfs, &count, struct {
            fn cb(c: *usize, e: btrfs.DirEntry) bool {
                _ = e;
                return Counter.stop(c);
            }
        }.cb) catch {},
        .fat => |*f| f.walkDir(&dir.impl.fat, &count, struct {
            fn cb(c: *usize, e: fat.DirEntry) bool {
                _ = e;
                return Counter.stop(c);
            }
        }.cb) catch {},
        .iso9660 => |*f| f.walkDir(&dir.impl.iso9660, &count, struct {
            fn cb(c: *usize, e: fsread.iso9660.Fs.DirEntry) bool {
                _ = e;
                return Counter.stop(c);
            }
        }.cb) catch {},
    }
}

fn fuzzFs(target: *FileDisk, smith: *std.testing.Smith) anyerror!void {
    fuzzPatches(target, smith);
    var fs = fs_mod.Fs.open(gpa, target.whole()) catch return;
    defer fs.deinit();
    exerciseFs(&fs);
}

fn fuzzFsImage(comptime name: []const u8) !void {
    var d = try FileDisk.open(name);
    defer d.close();
    try std.testing.fuzz(&d, fuzzFs, .{});
}

test "fuzz: ext4" {
    try fuzzFsImage("ext4.img");
}
test "fuzz: ext2 (block maps)" {
    try fuzzFsImage("ext2.img");
}
test "fuzz: ext4 inline data" {
    try fuzzFsImage("ext4-inline.img");
}
test "fuzz: btrfs (zstd)" {
    try fuzzFsImage("btrfs-zstd.img");
}
test "fuzz: btrfs (lzo)" {
    try fuzzFsImage("btrfs-lzo.img");
}
test "fuzz: fat16" {
    try fuzzFsImage("fat16.img");
}
test "fuzz: fat32" {
    try fuzzFsImage("fat32.img");
}
test "fuzz: iso9660" {
    try fuzzFsImage("iso.img");
}

fn fuzzPartitions(target: *FileDisk, smith: *std.testing.Smith) anyerror!void {
    fuzzPatches(target, smith);
    // Partition tables live in the first sectors: concentrate there.
    for (0..target.patches.n) |i| target.patches.off[i] %= 64 * 1024;
    const t = part.read(target.blockDev()) catch return;
    for (t.slice()) |p| _ = p.region(target.blockDev());
}

test "fuzz: MBR partition table" {
    var d = try FileDisk.open("mbr.img");
    defer d.close();
    try std.testing.fuzz(&d, fuzzPartitions, .{});
}
test "fuzz: GPT partition table" {
    var d = try FileDisk.open("gpt.img");
    defer d.close();
    try std.testing.fuzz(&d, fuzzPartitions, .{});
}
