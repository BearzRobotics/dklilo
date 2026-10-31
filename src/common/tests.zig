//! Tests against images built by the real mkfs and partitioning tools
//! (tests/images/make-fixtures.sh). Every file in each filesystem image is
//! read back through dklilo's reader and compared with the original by
//! SHA-256, using the manifest the script wrote from the source tree.

const std = @import("std");
const blockdev = @import("blockdev.zig");
const part = @import("part.zig");
const ext4 = @import("fs/ext4.zig");
const fs_mod = @import("fs/fs.zig");
const btrfs = @import("fs/btrfs.zig");
const test_options = @import("test_options");

const manifest = @embedFile("manifest.txt");
const gpa = std.testing.allocator;

fn disk(data: []const u8) blockdev.MemDisk {
    return .{ .data = data };
}

/// Checks every manifest file by hash and size through the generic `fs.Fs`.
fn checkDisk(dev: blockdev.BlockDev) !void {
    var fs = try fs_mod.Fs.open(gpa, dev.whole());
    defer fs.deinit();
    try checkFs(&fs, null);
}

/// `prefix` is prepended to manifest paths (for subvolume images).
fn checkFs(fs: *fs_mod.Fs, only_prefix: ?[]const u8) !void {
    var lines = std.mem.tokenizeScalar(u8, manifest, '\n');
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
    try std.testing.expect(count > 3000 or only_prefix != null);
}

fn checkImage(image: []const u8) !void {
    var d = disk(image);
    try checkDisk(d.blockDev());
}

/// A disk image read from a file, for images too big to embed (sparse btrfs).
const FileDisk = struct {
    file: std.Io.File,
    sectors: u64,
    /// Optional damage: reads covering these offsets get that byte flipped.
    corrupt_at: ?u64 = null,
    corrupt_also: ?u64 = null,

    fn open(name: []const u8) !FileDisk {
        var path_buf: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ test_options.fixtures_dir, name });
        const f = std.Io.Dir.cwd().openFile(std.testing.io, path, .{}) catch return error.SkipZigTest;
        return .{ .file = f, .sectors = (try f.length(std.testing.io)) / 512 };
    }
    fn close(self: *FileDisk) void {
        self.file.close(std.testing.io);
    }
    fn blockDev(self: *FileDisk) blockdev.BlockDev {
        return .{ .ctx = self, .readSectorsFn = read, .sector_size = 512, .sector_count = self.sectors };
    }
    fn read(ctx: *anyopaque, lba: u64, buf: []u8) blockdev.Error!void {
        const self: *FileDisk = @ptrCast(@alignCast(ctx));
        const off = lba * 512;
        const n = self.file.readPositionalAll(std.testing.io, buf, off) catch return error.IoError;
        if (n != buf.len) return error.IoError;
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
    var fs = try ext4.Fs.open(gpa, d.blockDev().whole());
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

test "ext4: corrupting metadata is reported, not ignored" {
    const orig = @embedFile("ext4.img");
    const copy = try gpa.dupe(u8, orig);
    defer gpa.free(copy);

    // Flip a bit in the superblock: checksum mismatch.
    copy[1024 + 100] ^= 1;
    var d = disk(copy);
    try std.testing.expectError(error.ChecksumMismatch, ext4.Fs.open(gpa, d.blockDev().whole()));
    copy[1024 + 100] ^= 1;

    // Bad magic.
    copy[1024 + 56] ^= 0xFF;
    try std.testing.expectError(error.BadMagic, ext4.Fs.open(gpa, d.blockDev().whole()));
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
        var fs = ext4.Fs.open(gpa, d.blockDev().whole()) catch continue;
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
        var fs = try btrfs.Fs.open(gpa, d.blockDev().whole());
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

test "btrfs: label, symlinks, dot-dot, holes, big directory" {
    var d = try FileDisk.open("btrfs.img");
    defer d.close();
    var fs = try btrfs.Fs.open(gpa, d.blockDev().whole());
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
        var fs = try fs_mod.Fs.open(gpa, d.blockDev().whole());
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
        var fs = try fs_mod.Fs.open(gpa, d.blockDev().whole());
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
    var probe = try btrfs.Fs.open(gpa, d.blockDev().whole());
    var phys: [4]u64 = undefined;
    const copies = try probe.mapLogical(probe.root_tree, probe.nodesize, &phys);
    probe.deinit();
    try std.testing.expect(copies >= 2);

    // Corrupt the first copy of the root tree block.
    d.corrupt_at = phys[0] + 200;
    var fs = try fs_mod.Fs.open(gpa, d.blockDev().whole());
    defer fs.deinit();
    try checkFs(&fs, "/boot/sub/");

    // Corrupt both copies: opening must fail, not return garbage.
    d.corrupt_at = phys[0] + 200;
    d.corrupt_also = phys[1] + 200;
    try std.testing.expectError(error.ChecksumMismatch, btrfs.Fs.open(gpa, d.blockDev().whole()));
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
        var fs = btrfs.Fs.open(gpa, d.blockDev().whole()) catch continue;
        fs.deinit();
    }
    d.corrupt_at = null;
    var fs = try btrfs.Fs.open(gpa, d.blockDev().whole());
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
