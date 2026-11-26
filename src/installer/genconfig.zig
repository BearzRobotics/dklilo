//! `dklilo config`: builds a first dklilo.conf from what is on the system.
//! This file is pure (no I/O) so it can be unit-tested; main.zig gathers the
//! file names, the root device and the Windows facts and prints the result.

const std = @import("std");

pub const Kernel = struct {
    /// File name in the boot directory, e.g. `vmlinuz-6.19-dkrescue`.
    image: []const u8,
    /// Version suffix after the first `-`, or "" for an unversioned `vmlinuz`.
    version: []const u8,
    /// Matching initramfs file name, if one was found.
    initrd: ?[]const u8 = null,
};

pub const Options = struct {
    /// Directory prefix of kernel paths inside the filesystem the config is
    /// read from: "/boot" when /boot is part of the root filesystem, "" when
    /// /boot is its own partition.
    prefix: []const u8 = "/boot",
    /// Value for `root=`, e.g. `PARTUUID=…` or `/dev/sda2`.
    root: ?[]const u8 = null,
    append: []const u8 = "ro quiet",
    timeout: u32 = 50,
    windows: bool = false,
    serial: ?[]const u8 = null,
    /// btrfs subvolume holding the kernels, if not the default one.
    subvol: ?[]const u8 = null,
    /// CPU microcode images, loaded ahead of each entry's initramfs.
    microcode: []const []const u8 = &.{},
};

/// The names distributions give separate CPU microcode images.
const microcode_names = [_][]const u8{ "amd-ucode.img", "intel-ucode.img" };

/// The microcode images present in a boot directory listing.
pub fn findMicrocode(names: []const []const u8, buf: *[microcode_names.len][]const u8) []const []const u8 {
    var n: usize = 0;
    for (microcode_names) |wanted| for (names) |name| {
        if (!std.mem.eql(u8, name, wanted)) continue;
        buf[n] = name;
        n += 1;
        break;
    };
    return buf[0..n];
}

/// Whether a file name can be written in a configuration at all.
fn writable(name: []const u8) bool {
    return std.mem.indexOfAny(u8, name, "\"\r\n") == null;
}

fn isKernelName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "vmlinuz") or std.mem.startsWith(u8, name, "bzImage");
}

fn versionOf(name: []const u8) []const u8 {
    const i = std.mem.indexOfScalar(u8, name, '-') orelse return "";
    return name[i + 1 ..];
}

/// How good a match `name` is as the initramfs of kernel `version`: lower is
/// better, null is none. initrd.img-VER, initramfs-VER.img, initrd-VER.img,
/// initramfs-VER, initrd-VER
fn initrdRank(name: []const u8, version: []const u8) ?usize {
    const prefixes = [_][]const u8{ "initrd.img", "initramfs", "initrd" };
    for (prefixes, 0..) |p, rank| {
        if (!std.mem.startsWith(u8, name, p)) continue;
        const rest = name[p.len..];
        if (version.len == 0) {
            if (rest.len == 0 or std.mem.eql(u8, rest, ".img") or std.mem.eql(u8, rest, ".gz")) return rank;
            continue;
        }
        if (rest.len < 1 + version.len or rest[0] != '-') continue;
        const tail = rest[1 + version.len ..];
        if (!std.mem.startsWith(u8, rest[1..], version)) continue;
        if (tail.len == 0 or std.mem.eql(u8, tail, ".img") or std.mem.eql(u8, tail, ".gz")) return rank;
    }
    return null;
}

/// The best initramfs for `version`; the same one whatever order the
/// directory was listed in.
fn findInitrd(names: []const []const u8, version: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_rank: usize = 0;
    for (names) |name| {
        const rank = initrdRank(name, version) orelse continue;
        if (!writable(name)) continue;
        if (best == null or rank < best_rank or (rank == best_rank and std.mem.lessThan(u8, name, best.?))) {
            best = name;
            best_rank = rank;
        }
    }
    return best;
}

/// Natural order: digit runs compare as numbers, so 6.9 < 6.10.
fn versionLess(_: void, a: Kernel, b: Kernel) bool {
    return switch (versionCmp(a.version, b.version)) {
        .gt => true, // newest first
        .lt => false,
        .eq => std.mem.lessThan(u8, a.image, b.image),
    };
}

/// A release candidate or other pre-release marker.
fn isPreRelease(rest: []const u8) bool {
    return std.mem.startsWith(u8, rest, "-rc") or std.mem.startsWith(u8, rest, "~");
}

fn versionCmp(a: []const u8, b: []const u8) std.math.Order {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len or j < b.len) {
        // 6.10-rc1 comes before 6.10, which is where the other one has ended.
        const a_pre = isPreRelease(a[i..]);
        const b_pre = isPreRelease(b[j..]);
        if (a_pre != b_pre) return if (a_pre) .lt else .gt;
        if (i >= a.len or j >= b.len) break;
        if (std.ascii.isDigit(a[i]) and std.ascii.isDigit(b[j])) {
            var ie = i;
            while (ie < a.len and std.ascii.isDigit(a[ie])) ie += 1;
            var je = j;
            while (je < b.len and std.ascii.isDigit(b[je])) je += 1;
            const na = std.fmt.parseInt(u64, a[i..ie], 10) catch 0;
            const nb = std.fmt.parseInt(u64, b[j..je], 10) catch 0;
            if (na != nb) return std.math.order(na, nb);
            i = ie;
            j = je;
        } else {
            if (a[i] != b[j]) return std.math.order(a[i], b[j]);
            i += 1;
            j += 1;
        }
    }
    return std.math.order(a.len - i, b.len - j);
}

/// Picks the kernels out of a directory listing, newest first, each paired
/// with its initramfs. Names are borrowed from `names`.
pub fn findKernels(allocator: std.mem.Allocator, names: []const []const u8) ![]Kernel {
    var list: std.ArrayList(Kernel) = .empty;
    errdefer list.deinit(allocator);
    for (names) |n| {
        if (!isKernelName(n) or !writable(n)) continue;
        if (std.mem.endsWith(u8, n, ".sig") or std.mem.endsWith(u8, n, ".old")) continue;
        const v = versionOf(n);
        try list.append(allocator, .{ .image = n, .version = v, .initrd = findInitrd(names, v) });
    }
    std.mem.sort(Kernel, list.items, {}, versionLess);
    return list.toOwnedSlice(allocator);
}

/// The label of kernel `index`, before it is made unique.
fn baseLabel(buf: []u8, index: usize, k: Kernel) []const u8 {
    if (index == 0) return "linux";
    if (k.version.len == 0) return std.fmt.bufPrint(buf, "linux-{d}", .{index}) catch unreachable;
    // Labels are free text but keep them to safe characters.
    const prefix = "linux-";
    @memcpy(buf[0..prefix.len], prefix);
    const n = @min(k.version.len, buf.len - prefix.len);
    for (k.version[0..n], buf[prefix.len..][0..n]) |c, *to| {
        to.* = if (std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_') c else '_';
    }
    return buf[0 .. prefix.len + n];
}

/// Writes `prefix/name` as a value, quoted if reading it back needs that.
fn writePath(w: *std.Io.Writer, prefix: []const u8, name: []const u8) !void {
    const quote = for ([_][]const u8{ prefix, name }) |part| {
        if (std.mem.indexOfAny(u8, part, "# \t") != null) break true;
    } else false;
    const q: []const u8 = if (quote) "\"" else "";
    try w.print("{s}{s}/{s}{s}\n", .{ q, prefix, name, q });
}

/// Writes the configuration text. `arena` holds the labels while it works.
pub fn render(arena: std.mem.Allocator, w: *std.Io.Writer, kernels: []const Kernel, opt: Options) !void {
    try w.writeAll("# dklilo.conf, generated by `dklilo config`. Edit freely; nothing to reinstall.\n");
    try w.print("timeout = {d}\n", .{opt.timeout});
    try w.writeAll("default = linux\n");
    if (opt.serial) |s| try w.print("serial  = {s}\n", .{s});
    var used: std.StringHashMapUnmanaged(void) = .empty;
    for (kernels, 0..) |k, idx| {
        var buf: [96]u8 = undefined;
        const base = baseLabel(&buf, idx, k);
        // Two kernel files can have the same version.
        var label = try arena.dupe(u8, base);
        var n: u32 = 2;
        while (used.contains(label)) : (n += 1) label = try std.fmt.allocPrint(arena, "{s}-{d}", .{ base, n });
        try used.put(arena, label, {});

        try w.writeAll("\nimage  = ");
        try writePath(w, opt.prefix, k.image);
        try w.print("    label  = {s}\n", .{label});
        if (opt.subvol) |sv| try w.print("    subvol = {s}\n", .{sv});
        if (opt.root) |r| try w.print("    root   = {s}\n", .{r});
        if (opt.append.len > 0) try w.print("    append = \"{s}\"\n", .{opt.append});
        for (opt.microcode) |image| {
            try w.writeAll("    initrd = ");
            try writePath(w, opt.prefix, image);
        }
        if (k.initrd) |ir| {
            try w.writeAll("    initrd = ");
            try writePath(w, opt.prefix, ir);
        }
    }
    if (opt.windows) try w.writeAll("\nother  = windows\n    label  = Windows\n");
}

const testing = std.testing;

test "kernels are paired with initramfs files and sorted newest first" {
    const names = [_][]const u8{
        "vmlinuz-6.9.1",     "initramfs-6.9.1.img", "vmlinuz-6.10.2",     "initrd.img-6.10.2",
        "System.map-6.10.2", "config-6.10.2",       "vmlinuz-6.10.2.old",
    };
    const ks = try findKernels(testing.allocator, &names);
    defer testing.allocator.free(ks);
    try testing.expectEqual(@as(usize, 2), ks.len);
    try testing.expectEqualStrings("vmlinuz-6.10.2", ks[0].image);
    try testing.expectEqualStrings("initrd.img-6.10.2", ks[0].initrd.?);
    try testing.expectEqualStrings("initramfs-6.9.1.img", ks[1].initrd.?);
}

test "an unversioned vmlinuz takes initrd.img but not a versioned one" {
    const names = [_][]const u8{ "vmlinuz", "initrd.img", "initrd.img-1.0" };
    const ks = try findKernels(testing.allocator, &names);
    defer testing.allocator.free(ks);
    try testing.expectEqual(@as(usize, 1), ks.len);
    try testing.expectEqualStrings("initrd.img", ks[0].initrd.?);
}

test "btrfs subvolume is written to every entry and parses" {
    const config = @import("common").config;
    const names = [_][]const u8{ "vmlinuz-1", "vmlinuz-2" };
    const ks = try findKernels(testing.allocator, &names);
    defer testing.allocator.free(ks);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try render(arena.allocator(), &aw.writer, ks, .{ .subvol = "@boot", .append = "ro rootflags=subvol=@" });
    var diag = config.Diagnostic{};
    var c = try config.parse(testing.allocator, aw.written(), &diag);
    defer c.deinit();
    try testing.expectEqualStrings("@boot", c.entries[1].subvol.?);
}

test "rendered config parses and has the right entries" {
    const config = @import("common").config;
    const names = [_][]const u8{ "vmlinuz-6.19-dkrescue", "initramfs-6.19-dkrescue.img", "vmlinuz-6.18", "weird name" };
    const ks = try findKernels(testing.allocator, &names);
    defer testing.allocator.free(ks);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try render(arena.allocator(), &aw.writer, ks, .{ .root = "PARTUUID=abcd-02", .windows = true });
    var diag = config.Diagnostic{};
    var c = try config.parse(testing.allocator, aw.written(), &diag);
    defer c.deinit();
    try testing.expectEqual(@as(usize, 3), c.entries.len);
    try testing.expectEqualStrings("linux", c.entries[0].label);
    try testing.expectEqualStrings("/boot/vmlinuz-6.19-dkrescue", c.entries[0].target);
    try testing.expectEqualStrings("Windows", c.entries[2].label);
    try testing.expectEqual(@as(usize, 1), c.entries[0].initrds.len);
}

test "release candidates sort below their release" {
    const names = [_][]const u8{ "vmlinuz-6.10-rc2", "vmlinuz-6.10", "vmlinuz-6.10.1-rc1", "vmlinuz-6.10-rc10", "vmlinuz-6.10-1-amd64" };
    const ks = try findKernels(testing.allocator, &names);
    defer testing.allocator.free(ks);
    for ([_][]const u8{ "6.10.1-rc1", "6.10-1-amd64", "6.10", "6.10-rc10", "6.10-rc2" }, ks) |want, got| {
        try testing.expectEqualStrings(want, got.version);
    }
}

test "the initramfs does not depend on the order of the directory" {
    for ([_][]const []const u8{
        &.{ "vmlinuz-1", "initrd-1.img", "initramfs-1.img", "initrd.img-1" },
        &.{ "initrd.img-1", "initramfs-1.img", "initrd-1.img", "vmlinuz-1" },
    }) |names| {
        const ks = try findKernels(testing.allocator, names);
        defer testing.allocator.free(ks);
        try testing.expectEqualStrings("initrd.img-1", ks[0].initrd.?);
    }
}
