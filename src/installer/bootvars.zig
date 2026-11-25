//! The UEFI boot variables, as Linux's efivarfs presents them: one file per
//! variable, holding a 4-byte attribute word and then the value. Everything
//! works on a directory the caller opened, so tests can use a temporary one.

const std = @import("std");
const Io = std.Io;

const boot_guid = "8be4df61-93ca-11d2-aa0d-00e098032b8c";

const order_name = "BootOrder-" ++ boot_guid;

/// The most we read of one variable. Real ones are a few hundred bytes; this
/// is far above what firmware has room for.
const max_variable = 64 * 1024;

/// The number of a `Boot####` variable's file name, or null for other names.
fn bootNumber(name: []const u8) ?u16 {
    const suffix = "-" ++ boot_guid;
    if (name.len != 8 + suffix.len or !std.mem.startsWith(u8, name, "Boot")) return null;
    if (!std.mem.eql(u8, name[8..], suffix)) return null;
    for (name[4..8]) |c| if (!std.ascii.isHex(c)) return null;
    return std.fmt.parseInt(u16, name[4..8], 16) catch null;
}

/// What identifies "our entry for this installation" in an `EFI_LOAD_OPTION`
/// as `plan.buildLoadOption` lays it out: the description, the partition
/// (number, GPT GUID or MBR signature) and the loader's path. The partition's
/// start and size are left out, so resizing it does not make a second entry.
const Identity = struct {
    description: []const u8,
    number: []const u8,
    signature: []const u8,
    loader: []const u8,

    fn of(bytes: []const u8) ?Identity {
        // attributes (4), path list length (2), UTF-16 description, paths.
        var end: usize = 6;
        while (end + 2 <= bytes.len and !(bytes[end] == 0 and bytes[end + 1] == 0)) end += 2;
        end += 2;
        // The 42-byte hard drive node, then the file path node and the rest.
        if (end + 42 > bytes.len) return null;
        const node = bytes[end..][0..42];
        if (node[0] != 4 or node[1] != 1) return null;
        return .{
            .description = bytes[6..end],
            .number = node[4..8],
            .signature = node[24..42],
            .loader = bytes[end + 42 ..],
        };
    }

    fn eql(a: Identity, b: Identity) bool {
        return std.mem.eql(u8, a.description, b.description) and
            std.mem.eql(u8, a.number, b.number) and
            std.mem.eql(u8, a.signature, b.signature) and
            std.mem.eql(u8, a.loader, b.loader);
    }
};

/// Creates (or updates) our Boot#### variable, puts it first in BootOrder and
/// returns its number. `load_option` comes from `plan.buildLoadOption`.
///
/// A variable that exists but cannot be read is an error, never a free slot or
/// an empty boot order: both would destroy what the firmware had. Everything
/// is read before the first write.
pub fn install(io: Io, gpa: std.mem.Allocator, dir: Io.Dir, load_option: []const u8) !u16 {
    const attrs = [4]u8{ 7, 0, 0, 0 }; // non-volatile | boot service | runtime
    const want = Identity.of(load_option) orelse return error.BadLoadOption;

    // The directory listing says which numbers are taken.
    var used: std.StaticBitSet(0x10000) = .empty;
    var reuse: ?u16 = null;
    var reuse_name: [64]u8 = undefined;
    var reuse_len: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const number = bootNumber(entry.name) orelse continue;
        used.set(number);
        const data = try dir.readFileAlloc(io, entry.name, gpa, .limited(max_variable));
        defer gpa.free(data);
        if (data.len < 4) continue;
        const have = Identity.of(data[4..]) orelse continue;
        // With several matches, the lowest number, whatever the listing order.
        if (want.eql(have) and (reuse == null or number < reuse.?)) {
            reuse = number;
            // Rewrite it under the name it has (the hex may be lower case).
            @memcpy(reuse_name[0..entry.name.len], entry.name);
            reuse_len = entry.name.len;
        }
    }

    const old: ?[]u8 = dir.readFileAlloc(io, order_name, gpa, .limited(max_variable)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
    defer if (old) |o| gpa.free(o);
    if (old) |o| if (o.len < 4 or (o.len - 4) % 2 != 0) return error.BadBootOrder;

    var number: u16 = undefined;
    var name_buf: [64]u8 = undefined;
    var name: []const u8 = undefined;
    if (reuse) |r| {
        number = r;
        name = reuse_name[0..reuse_len];
    } else {
        var free: u32 = 0;
        while (free < used.capacity() and used.isSet(free)) free += 1;
        if (free == used.capacity()) return error.NoFreeBootNumber;
        number = @intCast(free);
        name = std.fmt.bufPrint(&name_buf, "Boot{X:0>4}-" ++ boot_guid, .{number}) catch unreachable;
    }

    // BootOrder: our entry first, the rest in their old order.
    const old_entries: []const u8 = if (old) |o| o[4..] else &.{};
    const order = try gpa.alloc(u8, 2 + old_entries.len);
    defer gpa.free(order);
    std.mem.writeInt(u16, order[0..2], number, .little);
    var order_len: usize = 2;
    var k: usize = 0;
    while (k + 2 <= old_entries.len) : (k += 2) {
        if (std.mem.readInt(u16, old_entries[k..][0..2], .little) == number) continue;
        @memcpy(order[order_len..][0..2], old_entries[k..][0..2]);
        order_len += 2;
    }

    try writeVar(io, gpa, dir, name, &attrs, load_option);
    try writeVar(io, gpa, dir, order_name, &attrs, order[0..order_len]);
    return number;
}

fn writeVar(io: Io, gpa: std.mem.Allocator, dir: Io.Dir, name: []const u8, attrs: []const u8, data: []const u8) !void {
    // efivarfs wants the attributes and the value in a single write().
    const buf = try gpa.alloc(u8, attrs.len + data.len);
    defer gpa.free(buf);
    @memcpy(buf[0..attrs.len], attrs);
    @memcpy(buf[attrs.len..], data);
    try dir.writeFile(io, .{ .sub_path = name, .data = buf });
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const plan = @import("plan.zig");

fn varName(comptime number: []const u8) []const u8 {
    return "Boot" ++ number ++ "-" ++ boot_guid;
}

/// An EFI_LOAD_OPTION for a GPT partition whose GUID bytes are all `sig`.
fn option(buf: []u8, description: []const u8, sig: u8, start_lba: u64) []u8 {
    return plan.buildLoadOption(buf, description, .{
        .number = 1,
        .start_lba = start_lba,
        .sector_count = 1000,
        .signature = @splat(sig),
        .is_gpt = true,
    }, "\\EFI\\dklilo\\dkliloX64.efi");
}

/// Stores a variable as efivarfs shows it: attributes, then the value.
fn put(dir: Io.Dir, name: []const u8, value: []const u8) !void {
    try writeVar(testing.io, testing.allocator, dir, name, &.{ 7, 0, 0, 0 }, value);
}

fn expectVar(dir: Io.Dir, name: []const u8, value: []const u8) !void {
    const data = try dir.readFileAlloc(testing.io, name, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(data);
    try testing.expectEqualSlices(u8, value, data[4..]);
}

fn expectMissing(dir: Io.Dir, name: []const u8) !void {
    try testing.expectError(error.FileNotFound, dir.access(testing.io, name, .{}));
}

fn run(dir: Io.Dir, lo: []const u8) !u16 {
    return install(testing.io, testing.allocator, dir, lo);
}

test "boot entry: takes the lowest unused number and goes first in BootOrder" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    const windows = option(&a, "Windows Boot Manager", 1, 2048);
    const ours = option(&b, "dklilo", 2, 2048);
    try put(tmp.dir, varName("0000"), windows);
    try put(tmp.dir, order_name, &.{ 0, 0 });
    try testing.expectEqual(@as(u16, 1), try run(tmp.dir, ours));
    try expectVar(tmp.dir, varName("0000"), windows);
    try expectVar(tmp.dir, varName("0001"), ours);
    try expectVar(tmp.dir, order_name, &.{ 1, 0, 0, 0 });
}

test "boot entry: with no BootOrder yet, one is created" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var b: [256]u8 = undefined;
    try testing.expectEqual(@as(u16, 0), try run(tmp.dir, option(&b, "dklilo", 2, 2048)));
    try expectVar(tmp.dir, order_name, &.{ 0, 0 });
}

test "boot entry: a large foreign variable is not mistaken for a free slot" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var a: [256]u8 = undefined;
    var big: [6000]u8 = @splat(0x5A); // optional data past the old 4 KiB limit
    const head = option(&a, "Vendor", 1, 2048);
    @memcpy(big[0..head.len], head);
    try put(tmp.dir, varName("0000"), &big);
    var b: [256]u8 = undefined;
    try testing.expectEqual(@as(u16, 1), try run(tmp.dir, option(&b, "dklilo", 2, 2048)));
    try expectVar(tmp.dir, varName("0000"), &big);
}

test "boot entry: an unreadable Boot#### stops the install before any write" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // A directory by that name: reading it fails, also as root.
    try tmp.dir.createDirPath(testing.io, varName("0000"));
    try put(tmp.dir, order_name, &.{ 0, 0 });
    var b: [256]u8 = undefined;
    try testing.expect(std.meta.isError(run(tmp.dir, option(&b, "dklilo", 2, 2048))));
    try expectMissing(tmp.dir, varName("0001"));
    try expectVar(tmp.dir, order_name, &.{ 0, 0 });
}

test "boot entry: an unreadable BootOrder stops the install before any write" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, order_name);
    var b: [256]u8 = undefined;
    try testing.expect(std.meta.isError(run(tmp.dir, option(&b, "dklilo", 2, 2048))));
    try expectMissing(tmp.dir, varName("0000"));
}

test "boot entry: a long BootOrder keeps every entry" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var old: [600]u8 = undefined; // 300 entries
    for (0..300) |i| std.mem.writeInt(u16, old[i * 2 ..][0..2], @intCast(0x1000 + i), .little);
    try put(tmp.dir, order_name, &old);
    var b: [256]u8 = undefined;
    try testing.expectEqual(@as(u16, 0), try run(tmp.dir, option(&b, "dklilo", 2, 2048)));
    var want: [602]u8 = undefined;
    want[0..2].* = .{ 0, 0 };
    @memcpy(want[2..], &old);
    try expectVar(tmp.dir, order_name, &want);
}

test "boot entry: our entry is found past a gap and reused" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    // Same partition and loader; the partition has since been resized.
    try put(tmp.dir, varName("0080"), option(&a, "dklilo", 2, 2048));
    const new = option(&b, "dklilo", 2, 4096);
    try testing.expectEqual(@as(u16, 0x80), try run(tmp.dir, new));
    try expectVar(tmp.dir, varName("0080"), new);
    try expectMissing(tmp.dir, varName("0000"));
}

test "boot entry: another disk's dklilo entry is left alone" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    const other = option(&a, "dklilo", 9, 2048);
    try put(tmp.dir, varName("0000"), other);
    try testing.expectEqual(@as(u16, 1), try run(tmp.dir, option(&b, "dklilo", 2, 2048)));
    try expectVar(tmp.dir, varName("0000"), other);
}
