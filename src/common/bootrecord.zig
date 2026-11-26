//! Where `dklilo.conf` is, as `install-bios` records it for the BIOS loader
//! (SPEC 5.3): the partition's GPT GUID, or the MBR disk signature and the
//! partition number.
//!
//! The record lives inside stage 2, at a fixed offset after its signature,
//! where the installer fills it in. (The MBR has too little room left for a
//! GUID.) Layout, 24 bytes:
//!
//!   0   "CFG1"
//!   4   kind: 0 none, 1 GPT, 2 MBR
//!   5   MBR partition number
//!   6   zero
//!   8   GPT: the partition's unique GUID, on-disk byte order
//!       MBR: the disk signature, little-endian, then zeros

const std = @import("std");
const volumes = @import("volumes.zig");

/// Offset in the stage 2 image: past its two-byte jump and 8-byte signature.
pub const offset = 10;
pub const size = 24;
const magic = "CFG1";

pub const Record = union(enum) {
    /// Nothing recorded: the loader searches.
    none,
    gpt: [16]u8,
    mbr: struct { signature: u32, number: u8 },

    /// The record that names `volume`; `.none` for a whole disk, which has no
    /// partition to name.
    pub fn of(volume: *const volumes.Volume) Record {
        if (volume.number == 0) return .none;
        if (volume.part_guid) |guid| return .{ .gpt = guid };
        if (volume.mbr_signature) |signature| return .{ .mbr = .{ .signature = signature, .number = volume.number } };
        return .none;
    }

    pub fn matches(record: Record, volume: *const volumes.Volume) bool {
        return record != .none and std.meta.eql(record, of(volume));
    }

    pub fn encode(record: Record, out: *[size]u8) void {
        out.* = @splat(0);
        @memcpy(out[0..4], magic);
        switch (record) {
            .none => {},
            .gpt => |guid| {
                out[4] = 1;
                @memcpy(out[8..24], &guid);
            },
            .mbr => |m| {
                out[4] = 2;
                out[5] = m.number;
                std.mem.writeInt(u32, out[8..12], m.signature, .little);
            },
        }
    }

    /// Anything that isn't a record, such as the code an older stage 2 has at
    /// this offset, is `.none`.
    pub fn decode(bytes: *const [size]u8) Record {
        if (!std.mem.eql(u8, bytes[0..4], magic)) return .none;
        return switch (bytes[4]) {
            1 => .{ .gpt = bytes[8..24].* },
            2 => .{ .mbr = .{ .signature = std.mem.readInt(u32, bytes[8..12], .little), .number = bytes[5] } },
            else => .none,
        };
    }
};

test "a record survives encoding; other bytes are no record" {
    for ([_]Record{
        .none,
        .{ .gpt = "0123456789abcdef".* },
        .{ .mbr = .{ .signature = 0xCAFEBABE, .number = 5 } },
        .{ .mbr = .{ .signature = 0, .number = 1 } },
    }) |record| {
        var bytes: [size]u8 = undefined;
        record.encode(&bytes);
        try std.testing.expectEqualDeep(record, Record.decode(&bytes));
    }
    const code: [size]u8 = @splat(0xFA);
    try std.testing.expect(Record.decode(&code) == .none);
}
