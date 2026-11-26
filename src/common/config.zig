//! Parser for `dklilo.conf`, which follows LILO's syntax: `key = value`, one
//! per line, `#` starts a comment, values may be double-quoted, and `image` or
//! `other` starts a new boot entry that the following keys belong to.
//! See SPEC.md section 5.2 for the keys.
//!
//! Strings in the result point into the input text (nothing is copied), so the
//! input must outlive the `Config`.

const std = @import("std");

pub const Error = error{
    /// A line that isn't `key = value`, a bad number, or a bad quote.
    Syntax,
    UnknownKey,
    /// An entry-only key before any `image`/`other`, or a key that does not
    /// apply to this kind of entry.
    MisplacedKey,
    DuplicateLabel,
    /// `default` names a label that doesn't exist.
    UnknownDefault,
    /// An entry with no `image`/`other` value or an empty label.
    MissingValue,
    OutOfMemory,
};

pub const Diagnostic = struct {
    /// 1-based line number of the problem (0 when it isn't about one line).
    line: usize = 0,
    /// Things that are accepted but probably not meant, for `dklilo check`:
    /// the loader ignores them, so that they never stop a boot.
    warnings: [8]Warning = undefined,
    warning_count: usize = 0,

    pub const Warning = struct { line: usize, key: []const u8, kind: enum { repeated, ignored_value } };

    fn warn(self: ?*Diagnostic, w: Warning) void {
        const d = self orelse return;
        if (d.warning_count == d.warnings.len) return;
        d.warnings[d.warning_count] = w;
        d.warning_count += 1;
    }

    pub fn warningSlice(self: *const Diagnostic) []const Warning {
        return self.warnings[0..self.warning_count];
    }
};

pub const EntryKind = enum { linux, chain };

pub const Serial = struct { port: u8, baud: u32 };

pub const Entry = struct {
    kind: EntryKind,
    /// `image` path for Linux, the `other` target for chainload entries.
    target: []const u8,
    label: []const u8,
    root: ?[]const u8 = null,
    append: ?[]const u8 = null,
    initrds: []const []const u8 = &.{},
    subvol: ?[]const u8 = null,
    /// `iso =`: an ISO file (on the entry's volume) that `image` and `initrd`
    /// are read from. The kernel is told where the file is.
    iso: ?[]const u8 = null,
    restricted: bool = false,
    /// Line of the `image`/`other` that started the entry, for diagnostics.
    line: usize = 0,
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    /// Tenths of a second; null waits forever.
    timeout: ?u32 = null,
    default: ?[]const u8 = null,
    prompt: bool = false,
    serial: ?Serial = null,
    /// Lowercase hex SHA-256 of the editing password.
    password: ?[]const u8 = null,
    entries: []Entry = &.{},

    pub fn deinit(self: *Config) void {
        for (self.entries) |e| self.allocator.free(e.initrds);
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    /// Index of the entry to boot by default: `default`, else the first.
    pub fn defaultIndex(self: *const Config) usize {
        if (self.default) |d| for (self.entries, 0..) |e, i| {
            if (std.mem.eql(u8, e.label, d)) return i;
        };
        return 0;
    }

    /// Whether `password` is 64 hex digits. The parser only checks the
    /// length: a loader that rejected such a file would drop to the manual
    /// prompt with no password at all, whereas one that can never be matched
    /// keeps everything it guards locked. `dklilo check` reports it.
    pub fn passwordUsable(self: *const Config) bool {
        const p = self.password orelse return true;
        for (p) |c| if (!std.ascii.isHex(c)) return false;
        return true;
    }

    pub fn find(self: *const Config, label: []const u8) ?usize {
        for (self.entries, 0..) |e, i| if (std.mem.eql(u8, e.label, label)) return i;
        return null;
    }
};

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

/// Removes a comment and surrounding quotes. A `#` inside quotes is text.
fn cleanValue(raw: []const u8) Error![]const u8 {
    var in_quote = false;
    var end = raw.len;
    for (raw, 0..) |c, i| {
        if (c == '"') in_quote = !in_quote;
        if (c == '#' and !in_quote) {
            end = i;
            break;
        }
    }
    if (in_quote) return error.Syntax;
    const v = trim(raw[0..end]);
    if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') return v[1 .. v.len - 1];
    if (std.mem.indexOfScalar(u8, v, '"') != null) return error.Syntax;
    return v;
}

fn parseNum(comptime T: type, s: []const u8) Error!T {
    return std.fmt.parseInt(T, s, 10) catch error.Syntax;
}

/// Whether a flag written as `key` or `key = value` is on: it is, unless the
/// value says no. (It used to be on whatever the value said.)
fn flag(diag: ?*Diagnostic, line: usize, key: []const u8, value: []const u8) bool {
    for ([_][]const u8{ "no", "false", "off", "0" }) |no| {
        if (std.ascii.eqlIgnoreCase(value, no)) return false;
    }
    const known = value.len == 0 or for ([_][]const u8{ "yes", "true", "on", "1" }) |yes| {
        if (std.ascii.eqlIgnoreCase(value, yes)) break true;
    } else false;
    if (!known) Diagnostic.warn(diag, .{ .line = line, .key = key, .kind = .ignored_value });
    return true;
}

/// Keys that may be given once, globally or once per entry.
const single_keys = [_][]const u8{ "timeout", "default", "password", "serial", "label", "root", "append", "subvol", "iso" };

/// Parses `text`. On error, `diag` (if given) gets the offending line.
pub fn parse(allocator: std.mem.Allocator, text: []const u8, diag: ?*Diagnostic) Error!Config {
    var cfg = Config{ .allocator = allocator };
    errdefer cfg.deinit();

    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |e| allocator.free(e.initrds);
        entries.deinit(allocator);
    }
    var initrds: std.ArrayList([]const u8) = .empty;
    defer initrds.deinit(allocator);

    var seen: u32 = 0; // `single_keys` already given in this part of the file
    var line_no: usize = 0;
    const body = if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text[3..] else text;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line_raw| {
        line_no += 1;
        errdefer if (diag) |d| {
            d.line = line_no;
        };
        const line = trim(line_raw);
        if (line.len == 0 or line[0] == '#') continue;

        const eq = std.mem.indexOfScalar(u8, line, '=');
        const key = trim(if (eq) |i| line[0..i] else line);
        const value = if (eq) |i| try cleanValue(line[i + 1 ..]) else "";
        const has_value = eq != null;

        // Flags need no value.
        if (std.mem.eql(u8, key, "prompt")) {
            cfg.prompt = flag(diag, line_no, key, value);
            continue;
        }
        if (std.mem.eql(u8, key, "restricted")) {
            if (entries.items.len == 0) return error.MisplacedKey;
            entries.items[entries.items.len - 1].restricted = flag(diag, line_no, key, value);
            continue;
        }
        if (!has_value) return error.Syntax;

        for (single_keys, 0..) |name, bit| {
            if (!std.mem.eql(u8, key, name)) continue;
            const mask = @as(u32, 1) << @intCast(bit);
            if (seen & mask != 0) Diagnostic.warn(diag, .{ .line = line_no, .key = key, .kind = .repeated });
            seen |= mask;
        }

        if (std.mem.eql(u8, key, "image") or std.mem.eql(u8, key, "other")) {
            if (value.len == 0) return error.MissingValue;
            try finishEntry(allocator, &entries, &initrds);
            const kind: EntryKind = if (key[0] == 'i') .linux else .chain;
            try entries.append(allocator, .{
                .kind = kind,
                .target = value,
                .label = if (kind == .linux) std.fs.path.basename(value) else value,
                .line = line_no,
            });
            seen = 0;
            continue;
        }

        if (entries.items.len == 0) {
            // Global keys.
            if (std.mem.eql(u8, key, "timeout")) {
                cfg.timeout = try parseNum(u32, value);
            } else if (std.mem.eql(u8, key, "default")) {
                cfg.default = value;
            } else if (std.mem.eql(u8, key, "password")) {
                if (value.len != 64) return error.Syntax;
                cfg.password = value;
            } else if (std.mem.eql(u8, key, "serial")) {
                var it = std.mem.splitScalar(u8, value, ',');
                const port = try parseNum(u8, trim(it.next().?));
                const baud = if (it.next()) |b| try parseNum(u32, trim(b)) else 9600;
                if (it.next() != null) Diagnostic.warn(diag, .{ .line = line_no, .key = key, .kind = .ignored_value });
                if (baud == 0 or baud > 115200) return error.Syntax;
                cfg.serial = .{ .port = port, .baud = baud };
            } else if (isEntryKey(key)) {
                return error.MisplacedKey;
            } else return error.UnknownKey;
            continue;
        }

        const e = &entries.items[entries.items.len - 1];
        if (std.mem.eql(u8, key, "label")) {
            if (value.len == 0) return error.MissingValue;
            e.label = value;
        } else if (std.mem.eql(u8, key, "root")) {
            if (e.kind != .linux) return error.MisplacedKey;
            e.root = value;
        } else if (std.mem.eql(u8, key, "append")) {
            if (e.kind != .linux) return error.MisplacedKey;
            e.append = value;
        } else if (std.mem.eql(u8, key, "initrd")) {
            if (e.kind != .linux) return error.MisplacedKey;
            try initrds.append(allocator, value);
        } else if (std.mem.eql(u8, key, "subvol")) {
            if (e.kind != .linux) return error.MisplacedKey;
            e.subvol = value;
        } else if (std.mem.eql(u8, key, "iso")) {
            if (e.kind != .linux) return error.MisplacedKey;
            if (value.len == 0) return error.MissingValue;
            e.iso = value;
        } else if (isGlobalKey(key)) {
            return error.MisplacedKey;
        } else return error.UnknownKey;
    }
    try finishEntry(allocator, &entries, &initrds);

    cfg.entries = try entries.toOwnedSlice(allocator);

    // Labels must be unique, and `default` must name one.
    for (cfg.entries, 0..) |e, i| {
        for (cfg.entries[0..i]) |prev| {
            if (std.mem.eql(u8, prev.label, e.label)) {
                if (diag) |d| d.line = e.line;
                return error.DuplicateLabel;
            }
        }
    }
    if (cfg.default) |d| if (cfg.find(d) == null) return error.UnknownDefault;
    return cfg;
}

/// Attaches the pending `initrd` list to the last entry.
fn finishEntry(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(Entry),
    initrds: *std.ArrayList([]const u8),
) Error!void {
    if (entries.items.len == 0) return;
    entries.items[entries.items.len - 1].initrds = try allocator.dupe([]const u8, initrds.items);
    initrds.clearRetainingCapacity();
}

fn isEntryKey(k: []const u8) bool {
    inline for (.{ "label", "root", "append", "initrd", "subvol", "iso", "restricted" }) |n| {
        if (std.mem.eql(u8, k, n)) return true;
    }
    return false;
}

fn isGlobalKey(k: []const u8) bool {
    inline for (.{ "timeout", "default", "prompt", "serial", "password" }) |n| {
        if (std.mem.eql(u8, k, n)) return true;
    }
    return false;
}

/// A partition of the boot disk, as an `other =` target may name one.
pub const ChainPartition = struct {
    number: u8,
    /// Given as a device name, such as `/dev/sda2`. The BIOS loader can't tell
    /// which disk that means: only the number counts.
    device_name: bool,
};

/// Reads an `other =` target that selects a partition: a number, or a name
/// under `/dev/` ending in one. Null for anything else.
pub fn chainPartition(target: []const u8) ?ChainPartition {
    var start = target.len;
    while (start > 0 and std.ascii.isDigit(target[start - 1])) start -= 1;
    const device_name = std.mem.startsWith(u8, target, "/dev/");
    if (start != 0 and !device_name) return null;
    const number = std.fmt.parseInt(u8, target[start..], 10) catch return null;
    if (number == 0) return null;
    return .{ .number = number, .device_name = device_name };
}

/// The path part of a config path spec: `LABEL=x:/boot/k` -> `/boot/k`;
/// a plain path is returned unchanged.
pub fn specPath(spec: []const u8) []const u8 {
    inline for (.{ "LABEL=", "UUID=", "PARTUUID=" }) |pre| {
        if (std.mem.startsWith(u8, spec, pre)) {
            if (std.mem.indexOfScalar(u8, spec, ':')) |c| return spec[c + 1 ..];
        }
    }
    return spec;
}

const testing = std.testing;

test "iso key and specPath" {
    var c = try parse(testing.allocator, "image = /boot/vmlinuz\n  iso = LABEL=data:/isos/r.iso\n", null);
    defer c.deinit();
    try testing.expectEqualStrings("LABEL=data:/isos/r.iso", c.entries[0].iso.?);
    try testing.expectEqualStrings("/isos/r.iso", specPath(c.entries[0].iso.?));
    try testing.expectEqualStrings("/plain", specPath("/plain"));
    try testing.expectError(error.MisplacedKey, parse(testing.allocator, "other = windows\n  iso = /x.iso\n", null));
}

test "the example from the spec parses" {
    const text =
        \\# /boot/dklilo.conf
        \\timeout = 50                     # tenths of a second, as in LILO
        \\default = dkrescue
        \\serial  = 0,115200
        \\
        \\image   = /boot/vmlinuz-6.19-dkrescue
        \\    label  = dkrescue
        \\    root   = PARTUUID=4a6f8c21-02
        \\    append = "ro quiet"
        \\
        \\image   = /boot/vmlinuz-6.19-dkrescue
        \\    label  = dkrescue-safe
        \\    root   = PARTUUID=4a6f8c21-02
        \\    append = "ro nomodeset"
        \\
        \\other   = windows                # finds Windows automatically
        \\    label  = Windows
    ;
    var c = try parse(testing.allocator, text, null);
    defer c.deinit();
    try testing.expectEqual(@as(?u32, 50), c.timeout);
    try testing.expectEqual(@as(u8, 0), c.serial.?.port);
    try testing.expectEqual(@as(u32, 115200), c.serial.?.baud);
    try testing.expectEqual(@as(usize, 3), c.entries.len);
    try testing.expectEqualStrings("ro quiet", c.entries[0].append.?);
    try testing.expectEqualStrings("PARTUUID=4a6f8c21-02", c.entries[1].root.?);
    try testing.expectEqual(EntryKind.chain, c.entries[2].kind);
    try testing.expectEqualStrings("windows", c.entries[2].target);
    try testing.expectEqual(@as(usize, 0), c.defaultIndex());
}

test "defaults: label from the image name, first entry, several initrds" {
    var c = try parse(testing.allocator,
        \\image = /boot/vmlinuz
        \\initrd = /boot/a.img
        \\initrd = /boot/b.img
        \\image = LABEL=other:/vmlinuz-2
        \\
    , null);
    defer c.deinit();
    try testing.expectEqualStrings("vmlinuz", c.entries[0].label);
    try testing.expectEqual(@as(usize, 2), c.entries[0].initrds.len);
    try testing.expectEqualStrings("/boot/b.img", c.entries[0].initrds[1]);
    try testing.expectEqual(@as(usize, 0), c.entries[1].initrds.len);
    try testing.expectEqual(@as(?u32, null), c.timeout);
}

test "# inside quotes is text; CRLF is fine" {
    var c = try parse(testing.allocator, "image = /k\r\nappend = \"a # b\" # comment\r\n", null);
    defer c.deinit();
    try testing.expectEqualStrings("a # b", c.entries[0].append.?);
}

test "errors carry the line number" {
    var d = Diagnostic{};
    try testing.expectError(error.UnknownKey, parse(testing.allocator, "timeout = 5\nbogus = 1\n", &d));
    try testing.expectEqual(@as(usize, 2), d.line);
    try testing.expectError(error.Syntax, parse(testing.allocator, "timeout = abc\n", &d));
    try testing.expectError(error.Syntax, parse(testing.allocator, "image = /k\nappend = \"oops\n", &d));
    try testing.expectError(error.MisplacedKey, parse(testing.allocator, "label = x\n", &d));
    try testing.expectError(error.MisplacedKey, parse(testing.allocator, "image = /k\ntimeout = 5\n", &d));
    try testing.expectError(error.MisplacedKey, parse(testing.allocator, "other = windows\nroot = x\n", &d));
    try testing.expectError(error.DuplicateLabel, parse(testing.allocator, "image = /a/k\nimage = /b/k\n", &d));
    try testing.expectEqual(@as(usize, 2), d.line);
    try testing.expectError(error.UnknownDefault, parse(testing.allocator, "default = nope\nimage = /k\n", &d));
    try testing.expectError(error.Syntax, parse(testing.allocator, "serial = 0,0\n", &d));
}

test "empty config is valid (the prompt takes over)" {
    var c = try parse(testing.allocator, "# nothing\n", null);
    defer c.deinit();
    try testing.expectEqual(@as(usize, 0), c.entries.len);
}

test "password must be a 64-digit hash" {
    try testing.expectError(error.Syntax, parse(testing.allocator, "password = hunter2\n", null));
    const hash = "abababababababababababababababababababababababababababababababab";
    var c = try parse(testing.allocator, "password = " ++ hash ++ "\nimage = /k\nrestricted\n", null);
    defer c.deinit();
    try testing.expect(c.entries[0].restricted);
    try testing.expect(c.passwordUsable());
    var odd = try parse(testing.allocator, "password = " ++ @as([64]u8, @splat('z')) ++ "\nimage = /k\n", null);
    defer odd.deinit();
    try testing.expect(!odd.passwordUsable());
}

test "a failed parse frees what it had built" {
    try testing.expectError(error.UnknownKey, parse(testing.allocator, "image = /a\ninitrd = /b\nimage = /c\nbogus = 1\n", null));
}

test "a flag set to no is off; a byte order mark is ignored" {
    for ([_][]const u8{ "no", "false", "off", "0" }) |no| {
        var buf: [128]u8 = undefined;
        var c = try parse(testing.allocator, try std.fmt.bufPrint(&buf, "prompt = {s}\nimage = /k\nrestricted = {s}\n", .{ no, no }), null);
        defer c.deinit();
        try testing.expect(!c.prompt);
        try testing.expect(!c.entries[0].restricted);
    }
    var c = try parse(testing.allocator, "prompt\nimage = /k\nrestricted = yes\n", null);
    defer c.deinit();
    try testing.expect(c.prompt and c.entries[0].restricted);
    var bom = try parse(testing.allocator, "\xEF\xBB\xBFtimeout = 5\n", null);
    defer bom.deinit();
    try testing.expectEqual(@as(?u32, 5), bom.timeout);
    try testing.expectError(error.MissingValue, parse(testing.allocator, "image = /k\niso =\n", null));
}

test "repeated keys and ignored values are noted, not refused" {
    var d = Diagnostic{};
    var c = try parse(testing.allocator, "timeout = 1\ntimeout = 2\nserial = 0,9600,8n1\nimage = /k\nlabel = a\nimage = /l\nlabel = b\nroot = x\nroot = y\n", &d);
    defer c.deinit();
    try testing.expectEqual(@as(?u32, 2), c.timeout);
    const w = d.warningSlice();
    try testing.expectEqual(@as(usize, 3), w.len);
    try testing.expectEqual(@as(usize, 2), w[0].line);
    try testing.expectEqualStrings("serial", w[1].key);
    try testing.expectEqualStrings("root", w[2].key);
}

test "chainPartition takes numbers and /dev names, nothing else" {
    try testing.expectEqual(ChainPartition{ .number = 2, .device_name = false }, chainPartition("2").?);
    try testing.expectEqual(ChainPartition{ .number = 12, .device_name = true }, chainPartition("/dev/nvme0n1p12").?);
    for ([_][]const u8{ "windows", "disk2", "/EFI/tools/backup2", "/dev/sda", "0", "", "999" }) |t| {
        try testing.expect(chainPartition(t) == null);
    }
}
