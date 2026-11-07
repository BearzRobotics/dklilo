//! CRC routines for on-disk structures.
//!
//! Both are table-driven and allocation-free. The tables are built at compile
//! time so the loaders carry no start-up cost.

const std = @import("std");

fn makeTable(comptime poly: u32) [256]u32 {
    @setEvalBranchQuota(10_000);
    var t: [256]u32 = undefined;
    for (&t, 0..) |*e, i| {
        var c: u32 = @intCast(i);
        for (0..8) |_| c = if (c & 1 != 0) (c >> 1) ^ poly else c >> 1;
        e.* = c;
    }
    return t;
}

const table_ieee = makeTable(0xEDB88320);
const table_c = makeTable(0x82F63B78);

/// CRC-32 (IEEE 802.3), the checksum GPT uses. Standard form: initial value
/// and final XOR of 0xFFFFFFFF are applied inside.
pub fn crc32(data: []const u8) u32 {
    var c: u32 = 0xFFFFFFFF;
    for (data) |b| c = table_ieee[(c ^ b) & 0xFF] ^ (c >> 8);
    return ~c;
}

/// CRC-32C (Castagnoli) as ext4 and btrfs use it: *raw* update with no
/// initial/final inversion, so calls chain by passing the previous result as
/// `seed`. ext4 starts chains from `0xFFFFFFFF` (`~0`).
pub fn crc32cUpdate(seed: u32, data: []const u8) u32 {
    var c: u32 = seed;
    for (data) |b| c = table_c[(c ^ b) & 0xFF] ^ (c >> 8);
    return c;
}

test "crc32 check value" {
    try std.testing.expectEqual(@as(u32, 0xCBF43926), crc32("123456789"));
}

test "crc32c check value" {
    // Standard CRC-32C is the raw update with ~0 seed, inverted at the end.
    try std.testing.expectEqual(@as(u32, 0xE3069283), ~crc32cUpdate(0xFFFFFFFF, "123456789"));
}
