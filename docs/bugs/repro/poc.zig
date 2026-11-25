const std = @import("std");
const blockdev = @import("blockdev.zig");
const devio = @import("devio.zig");
const volumes = @import("volumes.zig");
const config = @import("config.zig");
const part = @import("part.zig");
const fsread = @import("fsread");
const gpa = std.testing.allocator;
const io = std.testing.io;

fn load(name: []const u8) ![]u8 {
    var b: [512]u8 = undefined;
    const p = try std.fmt.bufPrint(&b, "{s}/{s}", .{ @import("poc_opts").dir, name });
    return std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(200 << 20));
}

test "poc-extent-leaf-hole" {
    const img = try load("sparse.img");
    defer gpa.free(img);
    const want = try load("sparse.bin");
    defer gpa.free(want);
    var d = blockdev.MemDisk{ .data = img };
    var bd = d.blockDev();
    var fs = try fsread.fs.Fs.open(gpa, devio.fromRegion(&bd, bd.whole()));
    defer fs.deinit();
    const f = try fs.lookup("/sparse");
    const got = try gpa.alloc(u8, @intCast(f.size));
    defer gpa.free(got);
    const n = try fs.readAt(&f, 0, got);
    const bad = std.mem.indexOfDiff(u8, want, got);
    std.debug.print("size want={d} read={d} no-error, first wrong byte={?d}, root extent depth={d}\n", .{ want.len, n, bad, std.mem.readInt(u16, f.impl.ext4.raw[46..48], .little) });
    try std.testing.expect(bad == null);
}

test "poc-btrfs-cache" {
    const img = try load("btrfs.img");
    defer gpa.free(img);
    var d = blockdev.MemDisk{ .data = img };
    var bd = d.blockDev();
    var fs = try fsread.fs.Fs.open(gpa, devio.fromRegion(&bd, bd.whole()));
    defer fs.deinit();
    const big = try fs.lookup("/big.txt");
    const small = try fs.lookup("/small.txt");
    var a: [4096]u8 = undefined;
    var s: [1500]u8 = undefined;
    var b: [4096]u8 = undefined;
    _ = try fs.readAt(&big, 0, &a);
    const before = fs.btrfs.debug_decompressed;
    _ = try fs.readAt(&small, 0, &s);
    std.debug.print("inline file decompressed: {}\n", .{fs.btrfs.debug_decompressed > before});
    _ = try fs.readAt(&big, 0, &b);
    std.debug.print("1st read: '{s}'\n2nd read: '{s}'\n", .{ a[0..24], b[0..24] });
    try std.testing.expectEqualSlices(u8, &a, &b);
}

test "poc-fat-superfloppy" {
    const img = try load("super.img");
    defer gpa.free(img);
    var d = blockdev.MemDisk{ .data = img };
    var set = volumes.Set.init(gpa);
    defer set.deinit();
    _ = try set.addDisk(d.blockDev());
    std.debug.print("volumes found on whole-disk FAT: {d}\n", .{set.vols.items.len});
    try std.testing.expect(set.vols.items.len == 1);
}

fn fatWalk(img: []u8) !void {
    var d = blockdev.MemDisk{ .data = img };
    var bd = d.blockDev();
    var fs = try fsread.fat.Fs.open(gpa, devio.fromRegion(&bd, bd.whole()));
    defer fs.deinit();
    _ = try fs.lookup("/dir/nope");
}
/// Offsets of the FAT16 "DIR" root entry and the first cluster it names.
fn findDir(img: []u8) struct { ent: usize, cluster: u16 } {
    const bps: usize = std.mem.readInt(u16, img[11..13], .little);
    const root = (std.mem.readInt(u16, img[14..16], .little) + img[16] * @as(usize, std.mem.readInt(u16, img[22..24], .little))) * bps;
    var o = root;
    while (!std.mem.eql(u8, img[o..][0..11], "DIR        ")) o += 32;
    return .{ .ent = o, .cluster = std.mem.readInt(u16, img[o + 26 ..][0..2], .little) };
}
test "poc-fat-cycle" {
    const img = try load("fat16.img");
    defer gpa.free(img);
    const e = findDir(img);
    const bps: usize = std.mem.readInt(u16, img[11..13], .little);
    const reserved: usize = std.mem.readInt(u16, img[14..16], .little);
    const fatsz: usize = std.mem.readInt(u16, img[22..24], .little);
    // chain of the directory points back at itself
    std.mem.writeInt(u16, img[reserved * bps + e.cluster * 2 ..][0..2], e.cluster, .little);
    // fill the directory cluster with deleted entries: no 0x00 terminator
    const data = (reserved + img[16] * fatsz + 32) * bps;
    const csize = img[13] * bps;
    var o = data + (e.cluster - 2) * csize;
    const end = o + csize;
    while (o < end) : (o += 32) img[o] = 0xE5;
    std.debug.print("walking cyclic directory...\n", .{});
    try fatWalk(img);
}
test "poc-fat-cluster1" {
    const img = try load("fat16.img");
    defer gpa.free(img);
    const e = findDir(img);
    std.mem.writeInt(u16, img[e.ent + 26 ..][0..2], 1, .little);
    try fatWalk(img);
}
test "poc-fat-bpb-overflow" {
    var img: [4096]u8 = @splat(0);
    img[510] = 0x55;
    img[511] = 0xAA;
    std.mem.writeInt(u16, img[11..13], 512, .little);
    img[13] = 1;
    std.mem.writeInt(u16, img[14..16], 1, .little);
    img[16] = 2;
    std.mem.writeInt(u16, img[19..21], 100, .little);
    std.mem.writeInt(u32, img[36..40], 0x8000_0000, .little);
    var d = blockdev.MemDisk{ .data = &img };
    var bd = d.blockDev();
    _ = fsread.fat.Fs.open(gpa, devio.fromRegion(&bd, bd.whole())) catch {};
}

test "poc-ext4-descsize" {
    const img = try load("desc.img");
    defer gpa.free(img);
    std.mem.writeInt(u16, img[1024 + 254 ..][0..2], 128, .little);
    var d = blockdev.MemDisk{ .data = img };
    var bd = d.blockDev();
    var fs = try fsread.fs.Fs.open(gpa, devio.fromRegion(&bd, bd.whole()));
    defer fs.deinit();
    _ = try fs.lookup("/f");
}

test "poc-ext4-table-overflow" {
    const img = try load("desc.img");
    defer gpa.free(img);
    // 4 KiB blocks: group descriptor 0 starts at block 1; set inode_table_hi.
    std.mem.writeInt(u32, img[4096 + 40 ..][0..4], 0xFFFF_FFFF, .little);
    var d = blockdev.MemDisk{ .data = img };
    var bd = d.blockDev();
    var fs = try fsread.fs.Fs.open(gpa, devio.fromRegion(&bd, bd.whole()));
    defer fs.deinit();
    _ = fs.lookup("/f") catch {};
}

test "poc-config-leak" {
    try std.testing.expectError(error.UnknownKey, config.parse(gpa, "image = /a\ninitrd = /b\nimage = /c\nbogus = 1\n", null));
}

test "poc-gpt-overflow" {
    var img: [64 * 512]u8 = @splat(0);
    img[510] = 0x55;
    img[511] = 0xAA;
    img[446 + 4] = 0xEE;
    const h = img[512..1024];
    @memcpy(h[0..8], "EFI PART");
    std.mem.writeInt(u32, h[12..16], 92, .little);
    std.mem.writeInt(u64, h[72..80], 2, .little);
    std.mem.writeInt(u32, h[80..84], 1, .little);
    std.mem.writeInt(u32, h[84..88], 128, .little);
    const e = img[1024..][0..128];
    e[0] = 1;
    std.mem.writeInt(u64, e[40..48], std.math.maxInt(u64), .little);
    std.mem.writeInt(u32, h[88..92], fsread.crc.crc32(e), .little);
    std.mem.writeInt(u32, h[16..20], fsread.crc.crc32(h[0..92]), .little);
    var d = blockdev.MemDisk{ .data = &img };
    _ = try part.read(d.blockDev());
}
