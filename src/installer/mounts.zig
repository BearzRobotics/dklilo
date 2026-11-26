//! `/proc/self/mountinfo`: which filesystem a directory is on, and where in
//! that filesystem it is. Pure parsing, so it can be tested with made-up
//! mount tables. Format: proc_pid_mountinfo(5).

const std = @import("std");

pub const Mount = struct {
    /// The directory the filesystem is mounted on.
    point: []const u8,
    /// The directory of the filesystem that appears there: "/" for the whole
    /// filesystem, more for a btrfs subvolume or a bind mount.
    root: []const u8,
    fstype: []const u8,
    source: []const u8,
    /// The filesystem's own mount options.
    options: []const u8,

    /// The device mounted, if the source names one.
    pub fn device(m: Mount) ?[]const u8 {
        return if (std.mem.startsWith(u8, m.source, "/dev/")) m.source else null;
    }

    /// The btrfs subvolume mounted, without a leading slash, or null for the
    /// top-level one and for other filesystems.
    pub fn subvolume(m: Mount) ?[]const u8 {
        if (!std.mem.eql(u8, m.fstype, "btrfs")) return null;
        var it = std.mem.tokenizeScalar(u8, m.options, ',');
        while (it.next()) |option| {
            if (!std.mem.startsWith(u8, option, "subvol=")) continue;
            const name = std.mem.trim(u8, option["subvol=".len..], "/");
            return if (name.len > 0) name else null;
        }
        return null;
    }

    /// Where `dir` (under `point`) is, as the boot loader would name it: from
    /// the top of the filesystem, or of `subvolume()`. "" is that top itself.
    pub fn pathOf(m: Mount, arena: std.mem.Allocator, dir: []const u8) ![]const u8 {
        std.debug.assert(contains(m.point, dir));
        const below = std.mem.trim(u8, dir[m.point.len..], "/");
        const top = std.mem.trim(u8, m.root, "/");
        var full = try std.mem.concat(arena, u8, &.{
            if (top.len > 0) "/" else "",   top,
            if (below.len > 0) "/" else "", below,
        });
        if (m.subvolume()) |sv| {
            if (full.len > sv.len and std.mem.startsWith(u8, full[1..], sv) and
                (full.len == sv.len + 1 or full[sv.len + 1] == '/'))
            {
                full = full[sv.len + 1 ..];
            }
        }
        return full;
    }
};

/// Is `dir` the directory `point`, or inside it?
fn contains(point: []const u8, dir: []const u8) bool {
    if (!std.mem.startsWith(u8, dir, point)) return false;
    return dir.len == point.len or std.mem.endsWith(u8, point, "/") or dir[point.len] == '/';
}

/// Spaces, tabs, newlines and backslashes are written as `\ooo`.
fn unescape(arena: std.mem.Allocator, field: []const u8) ![]const u8 {
    const result = try arena.alloc(u8, field.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < field.len) : (n += 1) {
        if (field[i] == '\\' and field.len - i >= 4) {
            if (std.fmt.parseInt(u8, field[i + 1 ..][0..3], 8)) |byte| {
                result[n] = byte;
                i += 4;
                continue;
            } else |_| {}
        }
        result[n] = field[i];
        i += 1;
    }
    return result[0..n];
}

fn parseLine(arena: std.mem.Allocator, line: []const u8) !?Mount {
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    for (0..3) |_| _ = fields.next() orelse return null; // ids and device number
    const root = fields.next() orelse return null;
    const point = fields.next() orelse return null;
    while (fields.next()) |field| {
        if (std.mem.eql(u8, field, "-")) break;
    }
    const fstype = fields.next() orelse return null;
    const source = fields.next() orelse return null;
    return .{
        .point = try unescape(arena, point),
        .root = try unescape(arena, root),
        .fstype = fstype,
        .source = try unescape(arena, source),
        .options = try unescape(arena, fields.next() orelse ""),
    };
}

/// The mount holding the absolute path `dir`: the one with the longest mount
/// point that contains it, and of equal ones the last (it covers the others).
/// The result refers to `text` and to memory from `arena`.
pub fn find(arena: std.mem.Allocator, text: []const u8, dir: []const u8) !?Mount {
    var best: ?Mount = null;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const m = (try parseLine(arena, line)) orelse continue;
        if (!contains(m.point, dir)) continue;
        if (best == null or m.point.len >= best.?.point.len) best = m;
    }
    return best;
}

const testing = std.testing;

const table =
    \\30 1 0:27 /@ / rw - btrfs /dev/vda2 rw,subvol=/@
    \\31 30 8:1 / /boot rw,relatime shared:1 - ext4 /dev/sda1 rw
    \\32 30 0:28 /@boot /mnt/my\040disk/boot rw - btrfs /dev/vdb1 rw,subvolid=257,subvol=/@boot
    \\33 30 8:2 /isos /srv/isos rw - ext4 /dev/sda2 rw
    \\34 30 0:5 / /run rw - tmpfs tmpfs rw
    \\35 31 8:3 / /boot rw - ext4 /dev/sda3 rw
;

test "the deepest mount containing a directory, whole components only" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    try testing.expectEqualStrings("/dev/sda3", (try find(arena, table, "/boot/efi")).?.source);
    try testing.expectEqualStrings("/dev/vda2", (try find(arena, table, "/bootfiles")).?.source);
    // A tmpfs is the mount, though it has no device: not its parent.
    try testing.expect((try find(arena, table, "/run/x")).?.device() == null);
    try testing.expect((try find(arena, "", "/boot")) == null);
}

test "paths within the filesystem or subvolume" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    for ([_]struct { dir: []const u8, path: []const u8, subvol: ?[]const u8 }{
        .{ .dir = "/boot", .path = "", .subvol = null },
        .{ .dir = "/boot/efi", .path = "/efi", .subvol = null },
        .{ .dir = "/usr/lib", .path = "/usr/lib", .subvol = "@" },
        .{ .dir = "/mnt/my disk/boot", .path = "", .subvol = "@boot" },
        .{ .dir = "/mnt/my disk/boot/x", .path = "/x", .subvol = "@boot" },
        .{ .dir = "/srv/isos/a", .path = "/isos/a", .subvol = null }, // a bind mount
    }) |case| {
        const m = (try find(arena, table, case.dir)).?;
        try testing.expectEqualStrings(case.path, try m.pathOf(arena, case.dir));
        try testing.expectEqualDeep(case.subvol, m.subvolume());
    }
}
