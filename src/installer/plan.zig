//! What the installer will write, worked out from the disk's current contents
//! without touching it. Pure functions over byte buffers, so the safety rules
//! (never clobber a foreign boot loader's data) are unit-tested.

const std = @import("std");
const common = @import("common");

pub const sector_size = 512;
/// Stage 1 lives in the first 440 bytes of the MBR; the block list sits at 424.
pub const mbr_code_size = 440;
pub const blocklist_offset = 424;
/// Magic at offset 2 of an installed stage 2 (after a 2-byte jump).
pub const stage2_magic = "DKLILOS2";

pub const Error = error{
    /// The disk has no recognisable MBR (no 0x55AA signature).
    NoPartitionTable,
    /// The gap after the MBR is too small for stage 2.
    NoRoom,
    /// GPT disk without a BIOS boot partition to hold stage 2.
    NoBiosBootPartition,
    /// The space for stage 2 holds data that is not zeros or an older dklilo.
    ForeignData,
    /// A stage 1/2 image that does not look like ours.
    BadImage,
};

/// One write the installer will perform.
pub const Write = struct {
    /// Byte offset on the disk.
    offset: u64,
    data: []const u8,
    what: []const u8,
};

pub const BiosPlan = struct {
    stage2_lba: u64,
    stage2_sectors: u32,
    /// The new first sector: stage 1 over the old one's partition table.
    mbr: [sector_size]u8,
    /// True if the old MBR held boot code that will be replaced.
    replaces_boot_code: bool,
    /// Stage 2 padded to whole sectors (lives in the caller's buffer).
    stage2_padded: []const u8,

    /// The writes to perform, in order. The slices point into `self`, so the
    /// plan must not be copied between calling this and using the result.
    pub fn writes(self: *const BiosPlan) [2]Write {
        return .{
            .{ .offset = self.stage2_lba * sector_size, .data = self.stage2_padded, .what = "stage 2" },
            // The MBR goes last, so an interrupted install never leaves stage 1
            // pointing at a stage 2 that is not there yet.
            .{ .offset = 0, .data = &self.mbr, .what = "stage 1 (MBR boot code, partition table kept)" },
        };
    }
};

/// GPT type GUID of a BIOS boot partition, in on-disk byte order.
const bios_boot_guid = [16]u8{ 0x48, 0x61, 0x68, 0x21, 0x49, 0x64, 0x6F, 0x6E, 0x74, 0x4E, 0x65, 0x65, 0x64, 0x45, 0x46, 0x49 };

fn isZero(b: []const u8) bool {
    return std.mem.allEqual(u8, b, 0);
}

/// Plans `install-bios`. `head` is the start of the disk (at least up to the
/// first partition, 1 MiB is plenty); `stage1`/`stage2` are the images to
/// install. `stage2_buf` receives the sector-padded stage 2 and must outlive
/// the plan.
pub fn planBios(
    head: []const u8,
    stage1: []const u8,
    stage2: []const u8,
    stage2_buf: []u8,
    allocator: std.mem.Allocator,
) Error!BiosPlan {
    _ = allocator;
    if (head.len < sector_size * 2 or head[510] != 0x55 or head[511] != 0xAA) return error.NoPartitionTable;
    if (stage1.len < mbr_code_size or !std.mem.eql(u8, stage2[2..10], stage2_magic)) return error.BadImage;

    const sectors: u32 = @intCast((stage2.len + sector_size - 1) / sector_size);
    if (stage2_buf.len < sectors * sector_size) return error.NoRoom;
    @memset(stage2_buf[0 .. sectors * sector_size], 0);
    @memcpy(stage2_buf[0..stage2.len], stage2);

    var disk = common.blockdev.MemDisk{ .data = head };
    const table = common.part.read(disk.blockDev()) catch return error.NoPartitionTable;

    var lba: u64 = 1;
    var room: u64 = 0; // sectors available at `lba`
    switch (table.kind) {
        .mbr => {
            // The gap runs from LBA 1 to the first partition.
            var first: u64 = std.math.maxInt(u64);
            for (table.slice()) |p| first = @min(first, p.start_lba);
            if (first == std.math.maxInt(u64)) first = head.len / sector_size;
            room = first -| 1;
        },
        .gpt => {
            for (table.slice()) |p| {
                if (std.mem.eql(u8, &p.type_guid, &bios_boot_guid)) {
                    lba = p.start_lba;
                    room = p.sector_count;
                    break;
                }
            } else return error.NoBiosBootPartition;
        },
    }
    if (room < sectors) return error.NoRoom;
    if ((lba + sectors) * sector_size > head.len) return error.NoRoom;

    // Only zeros or an older dklilo stage 2 may be overwritten.
    const target = head[lba * sector_size ..][0 .. sectors * sector_size];
    const ours = std.mem.eql(u8, target[2..10], stage2_magic);
    if (!ours and !isZero(target)) return error.ForeignData;

    var mbr: [sector_size]u8 = undefined;
    @memcpy(&mbr, head[0..sector_size]);
    const replaces = !isZero(mbr[0..mbr_code_size]) and !std.mem.eql(u8, mbr[0..mbr_code_size], stage1[0..mbr_code_size]) and
        !looksLikeStage1(mbr[0..mbr_code_size]);
    @memcpy(mbr[0..mbr_code_size], stage1[0..mbr_code_size]);
    std.mem.writeInt(u64, mbr[blocklist_offset..][0..8], lba, .little);
    std.mem.writeInt(u16, mbr[blocklist_offset + 8 ..][0..2], @intCast(sectors), .little);

    return .{
        .stage2_lba = lba,
        .stage2_sectors = sectors,
        .mbr = mbr,
        .replaces_boot_code = replaces,
        .stage2_padded = stage2_buf[0 .. sectors * sector_size],
    };
}

/// Does this MBR code area start the way our stage 1 does (cli; xor ax,ax...)?
fn looksLikeStage1(code: []const u8) bool {
    return code.len > 8 and std.mem.eql(u8, code[0..5], &[_]u8{ 0xFA, 0x31, 0xC0, 0x8E, 0xD8 });
}

// ---- UEFI boot entry -----------------------------------------------------

pub const PartitionInfo = struct {
    number: u32,
    start_lba: u64,
    sector_count: u64,
    /// GPT partition GUID (on-disk order) or, for MBR, the 4-byte disk
    /// signature followed by zeros.
    signature: [16]u8,
    is_gpt: bool,
};

/// Builds an `EFI_LOAD_OPTION` (UEFI spec 3.1.3) that boots `file_path` (with
/// backslashes) from the given partition. Returns the bytes written into
/// `out`. This is also the payload `--entry-file` emits.
pub fn buildLoadOption(out: []u8, description: []const u8, part: PartitionInfo, file_path: []const u8) []u8 {
    var n: usize = 0;
    std.mem.writeInt(u32, out[n..][0..4], 1, .little); // LOAD_OPTION_ACTIVE
    n += 4;
    const len_pos = n; // FilePathListLength, patched below
    n += 2;
    for (description) |c| {
        std.mem.writeInt(u16, out[n..][0..2], c, .little);
        n += 2;
    }
    std.mem.writeInt(u16, out[n..][0..2], 0, .little);
    n += 2;

    const path_start = n;
    // Hard drive media device path node.
    out[n] = 4; // media
    out[n + 1] = 1; // hard drive
    std.mem.writeInt(u16, out[n + 2 ..][0..2], 42, .little);
    std.mem.writeInt(u32, out[n + 4 ..][0..4], part.number, .little);
    std.mem.writeInt(u64, out[n + 8 ..][0..8], part.start_lba, .little);
    std.mem.writeInt(u64, out[n + 16 ..][0..8], part.sector_count, .little);
    @memcpy(out[n + 24 ..][0..16], &part.signature);
    out[n + 40] = if (part.is_gpt) 2 else 1; // partition format
    out[n + 41] = if (part.is_gpt) 2 else 1; // signature type: GUID / MBR
    n += 42;
    // File path node.
    out[n] = 4;
    out[n + 1] = 4;
    const node_len: u16 = @intCast(4 + 2 * (file_path.len + 1));
    std.mem.writeInt(u16, out[n + 2 ..][0..2], node_len, .little);
    n += 4;
    for (file_path) |c| {
        std.mem.writeInt(u16, out[n..][0..2], c, .little);
        n += 2;
    }
    std.mem.writeInt(u16, out[n..][0..2], 0, .little);
    n += 2;
    // End of device path.
    out[n] = 0x7F;
    out[n + 1] = 0xFF;
    std.mem.writeInt(u16, out[n + 2 ..][0..2], 4, .little);
    n += 4;

    std.mem.writeInt(u16, out[len_pos..][0..2], @intCast(n - path_start), .little);
    return out[0..n];
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

fn fakeStage1() [512]u8 {
    var s = std.mem.zeroes([512]u8);
    @memcpy(s[0..5], &[_]u8{ 0xFA, 0x31, 0xC0, 0x8E, 0xD8 });
    s[100] = 0x99;
    return s;
}

fn fakeStage2(len: usize, buf: []u8) []u8 {
    @memset(buf[0..len], 0x90);
    buf[0] = 0xEB;
    buf[1] = 0x08;
    @memcpy(buf[2..10], stage2_magic);
    return buf[0..len];
}

/// A blank 1 MiB disk with an MBR partition table starting at LBA `first`.
fn mbrDisk(first: u32) [1024 * 1024]u8 {
    var d = std.mem.zeroes([1024 * 1024]u8);
    d[510] = 0x55;
    d[511] = 0xAA;
    std.mem.writeInt(u32, d[440..444], 0xCAFEBABE, .little); // disk signature
    d[446 + 4] = 0x83;
    std.mem.writeInt(u32, d[446 + 8 ..][0..4], first, .little);
    std.mem.writeInt(u32, d[446 + 12 ..][0..4], 1000, .little);
    return d;
}

test "mbr: stage 2 goes at LBA 1, the partition table survives" {
    var disk = mbrDisk(2048);
    var s2buf: [4096]u8 = undefined;
    var padded: [4096]u8 = undefined;
    const s2 = fakeStage2(1500, &s2buf);
    const s1 = fakeStage1();
    const plan = try planBios(&disk, &s1, s2, &padded, testing.allocator);
    try testing.expectEqual(@as(u64, 1), plan.stage2_lba);
    try testing.expectEqual(@as(u32, 3), plan.stage2_sectors);
    // Block list.
    try testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, plan.mbr[424..432], .little));
    try testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, plan.mbr[432..434], .little));
    // Disk signature, partition table and 0x55AA are untouched.
    try testing.expectEqualSlices(u8, disk[440..512], plan.mbr[440..512]);
    try testing.expectEqual(@as(u8, 0x99), plan.mbr[100]);
    try testing.expect(!plan.replaces_boot_code);
    // The MBR is written last.
    try testing.expectEqual(@as(u64, 0), plan.writes()[1].offset);
    try testing.expectEqualSlices(u8, &plan.mbr, plan.writes()[1].data);
}

test "mbr: the gap too small for stage 2 is refused" {
    var disk = mbrDisk(2); // only LBA 1 free
    var s2buf: [4096]u8 = undefined;
    var padded: [4096]u8 = undefined;
    const s2 = fakeStage2(1500, &s2buf);
    const s1 = fakeStage1();
    try testing.expectError(error.NoRoom, planBios(&disk, &s1, s2, &padded, testing.allocator));
}

test "foreign data in the gap is never overwritten; an older dklilo is" {
    var disk = mbrDisk(2048);
    var s2buf: [4096]u8 = undefined;
    var padded: [4096]u8 = undefined;
    const s2 = fakeStage2(1500, &s2buf);
    const s1 = fakeStage1();

    // Another boot loader's core image at LBA 1.
    @memcpy(disk[512..][0..16], "GRUB core image!");
    try testing.expectError(error.ForeignData, planBios(&disk, &s1, s2, &padded, testing.allocator));

    // Foreign data in a *later* sector of the range is caught too.
    disk = mbrDisk(2048);
    disk[512 * 3 - 1] = 0x42;
    try testing.expectError(error.ForeignData, planBios(&disk, &s1, s2, &padded, testing.allocator));

    // An older dklilo stage 2 is replaced.
    disk = mbrDisk(2048);
    _ = fakeStage2(900, disk[512..]);
    const plan = try planBios(&disk, &s1, s2, &padded, testing.allocator);
    try testing.expectEqual(@as(u64, 1), plan.stage2_lba);
}

test "other boot code in the MBR is reported as replaced" {
    var disk = mbrDisk(2048);
    @memset(disk[0..100], 0xEA); // some other loader's code
    var s2buf: [4096]u8 = undefined;
    var padded: [4096]u8 = undefined;
    const s2 = fakeStage2(600, &s2buf);
    const s1 = fakeStage1();
    const plan = try planBios(&disk, &s1, s2, &padded, testing.allocator);
    try testing.expect(plan.replaces_boot_code);
}

test "a disk without an MBR signature is refused" {
    var disk = mbrDisk(2048);
    disk[511] = 0;
    var s2buf: [4096]u8 = undefined;
    var padded: [4096]u8 = undefined;
    const s2 = fakeStage2(600, &s2buf);
    const s1 = fakeStage1();
    try testing.expectError(error.NoPartitionTable, planBios(&disk, &s1, s2, &padded, testing.allocator));
}

test "EFI_LOAD_OPTION layout" {
    var buf: [512]u8 = undefined;
    const sig = [16]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const lo = buildLoadOption(&buf, "dklilo", .{
        .number = 1,
        .start_lba = 2048,
        .sector_count = 524288,
        .signature = sig,
        .is_gpt = true,
    }, "\\EFI\\dklilo\\dkliloX64.efi");
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, lo[0..4], .little));
    const path_len = std.mem.readInt(u16, lo[4..6], .little);
    // description "dklilo\0" = 14 bytes
    try testing.expectEqual(@as(u16, 'd'), std.mem.readInt(u16, lo[6..8], .little));
    const path = lo[6 + 14 ..];
    try testing.expectEqual(@as(usize, path_len), path.len);
    try testing.expectEqual(@as(u8, 4), path[0]); // media
    try testing.expectEqual(@as(u8, 1), path[1]); // hard drive
    try testing.expectEqual(@as(u16, 42), std.mem.readInt(u16, path[2..4], .little));
    try testing.expectEqual(@as(u64, 2048), std.mem.readInt(u64, path[8..16], .little));
    try testing.expectEqualSlices(u8, &sig, path[24..40]);
    try testing.expectEqual(@as(u8, 2), path[41]); // GUID signature
    try testing.expectEqual(@as(u8, 4), path[42]); // file path node
    try testing.expectEqual(@as(u8, 4), path[43]);
    try testing.expectEqual(@as(u8, 0x7F), path[path.len - 4]); // end node
}
