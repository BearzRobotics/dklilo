//! Partition tables: MBR (including extended partitions) and GPT.
//!
//! Specifications:
//! - MBR: the classic layout, 4 entries at offset 446, signature 0x55AA.
//! - GPT: UEFI Specification 2.10, section 5.3.

const std = @import("std");
const blockdev = @import("blockdev.zig");
const crc = @import("fsread").crc;

pub const Error = error{
    /// No valid MBR signature, or GPT headers that fail validation.
    NoPartitionTable,
} || blockdev.Error;

pub const max_partitions = 128;

pub const Kind = enum { mbr, gpt };

pub const Partition = struct {
    /// 1-based, as Linux numbers them (logical MBR partitions start at 5).
    number: u8,
    start_lba: u64,
    sector_count: u64,
    /// MBR partition type byte (0 for GPT).
    mbr_type: u8 = 0,
    /// GPT partition type GUID, in on-disk (mixed-endian) byte order.
    type_guid: [16]u8 = @splat(0),
    /// GPT unique partition GUID, in on-disk byte order.
    part_guid: [16]u8 = @splat(0),
    /// MBR active flag.
    bootable: bool = false,

    pub fn region(self: Partition, dev: blockdev.BlockDev) blockdev.Region {
        return .{
            .dev = dev,
            .start = self.start_lba * dev.sector_size,
            .len = self.sector_count * dev.sector_size,
        };
    }
};

pub const Table = struct {
    kind: Kind,
    /// MBR disk signature (0 for GPT).
    disk_signature: u32 = 0,
    /// GPT disk GUID in on-disk byte order.
    disk_guid: [16]u8 = @splat(0),
    parts: [max_partitions]Partition = undefined,
    count: usize = 0,

    pub fn slice(self: *const Table) []const Partition {
        return self.parts[0..self.count];
    }

    fn add(self: *Table, p: Partition) void {
        if (self.count < max_partitions) {
            self.parts[self.count] = p;
            self.count += 1;
        }
    }
};

/// MBR partition entry, 16 bytes at offset 446 + 16 * n.
const MbrEntry = extern struct {
    status: u8,
    chs_first: [3]u8,
    type: u8,
    chs_last: [3]u8,
    lba: u32 align(1),
    sectors: u32 align(1),
};

/// GPT header (UEFI 2.10, table 5.5). Only the first 92 bytes are defined.
const GptHeader = extern struct {
    signature: [8]u8,
    revision: u32,
    header_size: u32,
    header_crc32: u32,
    reserved: u32,
    my_lba: u64 align(1),
    alternate_lba: u64 align(1),
    first_usable_lba: u64 align(1),
    last_usable_lba: u64 align(1),
    disk_guid: [16]u8,
    entries_lba: u64 align(1),
    num_entries: u32,
    entry_size: u32,
    entries_crc32: u32,
};

/// GPT partition entry (UEFI 2.10, table 5.6). Real entries may be larger.
const GptEntry = extern struct {
    type_guid: [16]u8,
    part_guid: [16]u8,
    first_lba: u64,
    last_lba: u64,
    attributes: u64,
    name: [72]u8,
};

comptime {
    std.debug.assert(@sizeOf(MbrEntry) == 16);
    std.debug.assert(@sizeOf(GptHeader) == 92);
    std.debug.assert(@sizeOf(GptEntry) == 128);
}

fn readStruct(comptime T: type, bytes: []const u8) T {
    var v: T = undefined;
    @memcpy(std.mem.asBytes(&v), bytes[0..@sizeOf(T)]);
    return v;
}

/// Reads the partition table of `dev`. A protective MBR leads to GPT.
pub fn read(dev: blockdev.BlockDev) Error!Table {
    var sector: [blockdev.max_sector_size]u8 = undefined;
    const ss = dev.sector_size;
    try dev.readSectors(0, sector[0..ss]);
    if (sector[510] != 0x55 or sector[511] != 0xAA) return error.NoPartitionTable;

    var entries: [4]MbrEntry = undefined;
    for (&entries, 0..) |*e, i| e.* = readStruct(MbrEntry, sector[446 + 16 * i ..]);
    for (entries) |e| {
        if (e.type == 0xEE) return readGpt(dev);
    }
    return readMbr(dev, sector[0..ss], entries);
}

fn isExtended(t: u8) bool {
    return t == 0x05 or t == 0x0F or t == 0x85;
}

fn readMbr(dev: blockdev.BlockDev, sector0: []const u8, entries: [4]MbrEntry) Error!Table {
    var t = Table{ .kind = .mbr, .disk_signature = std.mem.readInt(u32, sector0[440..][0..4], .little) };
    var ext_start: u64 = 0;
    for (entries, 0..) |e, i| {
        if (e.type == 0 or e.sectors == 0) continue;
        if (isExtended(e.type)) {
            ext_start = e.lba;
            t.add(.{ .number = @intCast(i + 1), .start_lba = e.lba, .sector_count = e.sectors, .mbr_type = e.type });
            continue;
        }
        t.add(.{
            .number = @intCast(i + 1),
            .start_lba = e.lba,
            .sector_count = e.sectors,
            .mbr_type = e.type,
            .bootable = e.status == 0x80,
        });
    }

    // Walk the chain of extended boot records. Each EBR's first entry is a
    // logical partition relative to that EBR; its second links to the next
    // EBR relative to the start of the extended partition. The cap stops a
    // corrupt (looping) chain.
    if (ext_start != 0) {
        var ebr_lba: u64 = ext_start;
        var number: u8 = 5;
        var sec: [blockdev.max_sector_size]u8 = undefined;
        var hops: usize = 0;
        while (hops < 64) : (hops += 1) {
            dev.readSectors(ebr_lba, sec[0..dev.sector_size]) catch break;
            if (sec[510] != 0x55 or sec[511] != 0xAA) break;
            const logical = readStruct(MbrEntry, sec[446..]);
            const link = readStruct(MbrEntry, sec[462..]);
            if (logical.type != 0 and logical.sectors != 0) {
                t.add(.{
                    .number = number,
                    .start_lba = ebr_lba + logical.lba,
                    .sector_count = logical.sectors,
                    .mbr_type = logical.type,
                    .bootable = logical.status == 0x80,
                });
                number +|= 1;
            }
            if (!isExtended(link.type) or link.lba == 0) break;
            ebr_lba = ext_start + link.lba;
        }
    }
    return t;
}

fn readGpt(dev: blockdev.BlockDev) Error!Table {
    // Try the primary header, then the backup in the last sector, as the
    // spec asks: a disk with a damaged primary must still boot.
    return readGptAt(dev, 1) catch |primary| {
        if (dev.sector_count < 2) return primary;
        return readGptAt(dev, dev.sector_count - 1) catch primary;
    };
}

fn readGptAt(dev: blockdev.BlockDev, lba: u64) Error!Table {
    var sector: [blockdev.max_sector_size]u8 = undefined;
    try dev.readSectors(lba, sector[0..dev.sector_size]);
    const h = readStruct(GptHeader, &sector);
    if (!std.mem.eql(u8, &h.signature, "EFI PART")) return error.NoPartitionTable;
    if (h.header_size < @sizeOf(GptHeader) or h.header_size > dev.sector_size) return error.NoPartitionTable;

    const stored_crc = h.header_crc32;
    std.mem.writeInt(u32, sector[16..20], 0, .little);
    if (crc.crc32(sector[0..h.header_size]) != stored_crc) return error.NoPartitionTable;

    if (h.entry_size < @sizeOf(GptEntry) or h.entry_size > 4096 or h.num_entries == 0 or h.num_entries > 4096)
        return error.NoPartitionTable;

    var t = Table{ .kind = .gpt, .disk_guid = h.disk_guid };
    // Entries are checksummed as one array; stream them while accumulating
    // the CRC so no allocation is needed.
    var running: u32 = 0xFFFFFFFF;
    var i: u32 = 0;
    var buf: [4096]u8 = undefined;
    const table_off = h.entries_lba * dev.sector_size;
    while (i < h.num_entries) : (i += 1) {
        const e_buf = buf[0..h.entry_size];
        try dev.readBytes(table_off + @as(u64, i) * h.entry_size, e_buf);
        running = crcUpdateIeee(running, e_buf);
        const e = readStruct(GptEntry, e_buf);
        if (std.mem.allEqual(u8, &e.type_guid, 0)) continue;
        if (e.last_lba < e.first_lba) continue;
        if (i >= max_partitions) continue; // still checksummed, just not listed
        t.add(.{
            .number = @intCast(i + 1),
            .start_lba = e.first_lba,
            .sector_count = e.last_lba - e.first_lba + 1,
            .type_guid = e.type_guid,
            .part_guid = e.part_guid,
        });
    }
    if (~running != h.entries_crc32) return error.NoPartitionTable;
    return t;
}

fn crcUpdateIeee(state: u32, data: []const u8) u32 {
    // crc.crc32 is one-shot; continue it by feeding the running (inverted) state.
    // crc32(x) = ~update(~0, x), so chaining stores the pre-inversion state.
    var c = state;
    for (data) |b| {
        c ^= b;
        for (0..8) |_| c = if (c & 1 != 0) (c >> 1) ^ 0xEDB88320 else c >> 1;
    }
    return c;
}

/// Formats a GUID from its on-disk mixed-endian bytes as the usual
/// 8-4-4-4-12 lowercase string (36 bytes).
pub fn formatGuid(guid: [16]u8, out: *[36]u8) void {
    const hex = "0123456789abcdef";
    const order = [16]u8{ 3, 2, 1, 0, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13, 14, 15 };
    var o: usize = 0;
    for (order, 0..) |src, n| {
        if (n == 4 or n == 6 or n == 8 or n == 10) {
            out[o] = '-';
            o += 1;
        }
        out[o] = hex[guid[src] >> 4];
        out[o + 1] = hex[guid[src] & 0xF];
        o += 2;
    }
}
