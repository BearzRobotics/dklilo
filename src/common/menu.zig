//! The boot menu: a list of entries with a countdown to the default, and a
//! command-line editor. It only talks to a `Console`, so the same code runs
//! on BIOS, UEFI and in tests.
//!
//! Keys: Up/Down choose, Enter boots, `e` edits the command line (needs the
//! password if one is configured and the entry is `restricted`), any key stops
//! the countdown.

const std = @import("std");
const config = @import("config.zig");
const console = @import("console.zig");
const Console = console.Console;
const Key = console.Key;

pub const Choice = struct {
    index: usize,
    /// Kernel command line (empty for chainload entries); lives in the
    /// buffer passed to `run`.
    cmdline: []const u8,
};

/// Builds the default kernel command line for an entry: `root=`, then
/// `append`, then (for a loopback ISO entry) `iso-scan/filename=` with the
/// path of the ISO file, which distribution initramfs scripts understand.
pub fn buildCmdline(entry: config.Entry, buf: []u8) []const u8 {
    if (entry.kind != .linux) return buf[0..0];
    var n: usize = 0;
    const iso_path: ?[]const u8 = if (entry.iso) |i| config.specPath(i) else null;
    const parts = [_]?[]const u8{
        if (entry.root != null) "root=" else null,
        entry.root,
        if (entry.root != null and (entry.append != null or iso_path != null)) " " else null,
        entry.append,
        if (entry.append != null and iso_path != null) " " else null,
        if (iso_path != null) "iso-scan/filename=" else null,
        iso_path,
    };
    for (parts) |maybe| if (maybe) |p| {
        const take = @min(p.len, buf.len - n);
        @memcpy(buf[n..][0..take], p[0..take]);
        n += take;
    };
    return buf[0..n];
}

pub const EditResult = enum { accepted, cancelled };

/// A one-line editor at (row, col). `buf[0..len.*]` is the initial text and
/// the result. With `mask`, characters are shown as `*` (password entry).
pub fn editLine(con: Console, row: u16, col: u16, buf: []u8, len: *usize, mask: bool) EditResult {
    var cursor = len.*;
    const width = con.size().cols;
    while (true) {
        // Redraw the whole line: simple and correct on every console type.
        con.moveTo(row, col);
        var shown: usize = 0;
        const avail: usize = if (width > col + 1) width - col - 1 else 0;
        // Scroll horizontally so the cursor stays visible.
        const start: usize = if (cursor > avail) cursor - avail else 0;
        var i = start;
        while (i < len.* and shown < avail) : (i += 1) {
            con.puts(if (mask) "*" else buf[i .. i + 1]);
            shown += 1;
        }
        while (shown < avail) : (shown += 1) con.puts(" ");
        con.moveTo(row, col + @as(u16, @intCast(cursor - start)));

        switch (con.getKey(null)) {
            .enter => return .accepted,
            .esc => return .cancelled,
            .left => cursor -|= 1,
            .right => cursor = @min(cursor + 1, len.*),
            .home => cursor = 0,
            .end => cursor = len.*,
            .backspace => if (cursor > 0) {
                std.mem.copyForwards(u8, buf[cursor - 1 .. len.* - 1], buf[cursor..len.*]);
                cursor -= 1;
                len.* -= 1;
            },
            .delete => if (cursor < len.*) {
                std.mem.copyForwards(u8, buf[cursor .. len.* - 1], buf[cursor + 1 .. len.*]);
                len.* -= 1;
            },
            .char => |c| if (len.* < buf.len) {
                std.mem.copyBackwards(u8, buf[cursor + 1 .. len.* + 1], buf[cursor..len.*]);
                buf[cursor] = c;
                cursor += 1;
                len.* += 1;
            },
            else => {},
        }
    }
}

fn passwordOk(cfg: *const config.Config, typed: []const u8) bool {
    const want = cfg.password orelse return true;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(typed, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.ascii.eqlIgnoreCase(&hex, want);
}

fn draw(con: Console, cfg: *const config.Config, sel: usize, remaining: ?u32) void {
    con.clear();
    con.moveTo(0, 0);
    con.puts("dklilo boot menu");
    for (cfg.entries, 0..) |e, i| {
        con.moveTo(@intCast(2 + i), 2);
        con.setHighlight(i == sel);
        con.puts(" ");
        con.puts(e.label);
        con.puts(" ");
        con.setHighlight(false);
    }
    const base: u16 = @intCast(3 + cfg.entries.len);
    con.moveTo(base, 0);
    con.puts("Up/Down: choose   Enter: boot   e: edit command line");
    if (remaining) |r| {
        con.moveTo(base + 1, 0);
        var b: [48]u8 = undefined;
        const s = std.fmt.bufPrint(&b, "Booting in {d} s (any key stops)   ", .{(r + 9) / 10}) catch "";
        con.puts(s);
    }
}

/// Shows the menu and returns the chosen entry and its command line, or null
/// if there are no entries (the caller then offers a manual prompt).
pub fn run(con: Console, cfg: *const config.Config, cmd_buf: []u8) ?Choice {
    if (cfg.entries.len == 0) return null;
    var sel = cfg.defaultIndex();

    // Boot at once when nothing asks us to wait.
    const immediate = (cfg.timeout orelse 1) == 0 or (cfg.entries.len == 1 and !cfg.prompt and cfg.timeout != null);
    if (immediate) return .{ .index = sel, .cmdline = buildCmdline(cfg.entries[sel], cmd_buf) };

    var remaining: ?u32 = cfg.timeout; // tenths of a second
    while (true) {
        draw(con, cfg, sel, remaining);
        const key = con.getKey(if (remaining != null) 100 else null);
        switch (key) {
            .timeout => {
                const r = remaining.?;
                if (r <= 1) return .{ .index = sel, .cmdline = buildCmdline(cfg.entries[sel], cmd_buf) };
                remaining = r - 1;
                continue;
            },
            else => remaining = null,
        }
        switch (key) {
            .up => sel = if (sel == 0) cfg.entries.len - 1 else sel - 1,
            .down => sel = (sel + 1) % cfg.entries.len,
            .enter => return .{ .index = sel, .cmdline = buildCmdline(cfg.entries[sel], cmd_buf) },
            .char => |c| if (c == 'e' and cfg.entries[sel].kind == .linux) {
                if (edit(con, cfg, sel, cmd_buf)) |line| return .{ .index = sel, .cmdline = line };
            },
            else => {},
        }
    }
}

/// Edits the entry's command line. Returns the final line, or null if the
/// user cancelled (or failed the password) and wants the menu back.
fn edit(con: Console, cfg: *const config.Config, sel: usize, cmd_buf: []u8) ?[]const u8 {
    const entry = cfg.entries[sel];
    const row: u16 = @intCast(6 + cfg.entries.len);

    if (cfg.password != null and entry.restricted) {
        var pw: [64]u8 = undefined;
        var pw_len: usize = 0;
        con.moveTo(row, 0);
        con.puts("Password: ");
        const r = editLine(con, row, 10, &pw, &pw_len, true);
        if (r == .cancelled or !passwordOk(cfg, pw[0..pw_len])) {
            con.moveTo(row + 1, 0);
            con.puts("Access denied.");
            _ = con.getKey(1500);
            return null;
        }
    }

    const initial = buildCmdline(entry, cmd_buf);
    var len = initial.len;
    con.moveTo(row, 0);
    con.puts("Command line:                                        ");
    con.moveTo(row + 1, 0);
    con.puts("(Enter boots, Esc goes back)");
    return switch (editLine(con, row, 14, cmd_buf, &len, false)) {
        .accepted => cmd_buf[0..len],
        .cancelled => null,
    };
}

/// With no usable configuration, asks for a kernel path and command line by
/// hand, so a broken config never leaves the machine unbootable. Writes
/// "path" and "cmdline" into the buffers and returns their lengths, or null
/// if the user pressed Esc.
pub fn manualPrompt(con: Console, path_buf: []u8, cmd_buf: []u8) ?struct { path: []const u8, cmdline: []const u8 } {
    con.clear();
    con.moveTo(0, 0);
    con.puts("dklilo: no usable configuration. Boot by hand.");
    con.moveTo(2, 0);
    con.puts("Kernel path:  ");
    var plen: usize = 0;
    if (editLine(con, 2, 14, path_buf, &plen, false) == .cancelled) return null;
    con.moveTo(3, 0);
    con.puts("Command line: ");
    var clen: usize = 0;
    if (editLine(con, 3, 14, cmd_buf, &clen, false) == .cancelled) return null;
    return .{ .path = path_buf[0..plen], .cmdline = cmd_buf[0..clen] };
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

/// A console that plays back a key script and records what was written.
const FakeConsole = struct {
    keys: []const Key,
    next: usize = 0,
    /// Timeouts requested from getKey, to check the countdown cadence.
    timeouts_seen: usize = 0,
    text: [4096]u8 = undefined,
    text_len: usize = 0,

    const vt = Console.VTable{
        .clear = clear,
        .moveTo = moveTo,
        .setHighlight = setHighlight,
        .puts = puts,
        .getKey = getKey,
        .size = size,
    };
    fn con(self: *FakeConsole) Console {
        return .{ .ctx = self, .vtable = &vt };
    }
    fn me(ctx: *anyopaque) *FakeConsole {
        return @ptrCast(@alignCast(ctx));
    }
    fn clear(_: *anyopaque) void {}
    fn moveTo(_: *anyopaque, _: u16, _: u16) void {}
    fn setHighlight(_: *anyopaque, _: bool) void {}
    fn puts(ctx: *anyopaque, s: []const u8) void {
        const f = me(ctx);
        const n = @min(s.len, f.text.len - f.text_len);
        @memcpy(f.text[f.text_len..][0..n], s[0..n]);
        f.text_len += n;
    }
    fn getKey(ctx: *anyopaque, timeout_ms: ?u32) Key {
        const f = me(ctx);
        if (f.next >= f.keys.len) {
            // Script exhausted: a timeout lets the countdown finish; a blocking
            // read would hang forever, so fail loudly.
            if (timeout_ms == null) @panic("test script ran out of keys");
            f.timeouts_seen += 1;
            return .timeout;
        }
        const k = f.keys[f.next];
        f.next += 1;
        return k;
    }
    fn size(_: *anyopaque) console.Size {
        return .{ .rows = 25, .cols = 80 };
    }
};

fn keysOf(comptime s: []const u8) [s.len]Key {
    var out: [s.len]Key = undefined;
    for (s, 0..) |c, i| out[i] = .{ .char = c };
    return out;
}

const sample =
    \\timeout = 30
    \\default = b
    \\image = /boot/a
    \\  label = a
    \\  root = PARTUUID=x
    \\  append = "ro quiet"
    \\image = /boot/b
    \\  label = b
    \\  append = "single"
    \\other = windows
    \\  label = w
;

test "countdown boots the default after the timeout" {
    var cfg = try config.parse(testing.allocator, sample, null);
    defer cfg.deinit();
    var f = FakeConsole{ .keys = &.{} };
    var buf: [256]u8 = undefined;
    const c = run(f.con(), &cfg, &buf).?;
    try testing.expectEqual(@as(usize, 1), c.index);
    try testing.expectEqualStrings("single", c.cmdline);
    try testing.expectEqual(@as(usize, 30), f.timeouts_seen + 0); // 3 s at 100 ms ticks
}

test "any key stops the countdown; arrows choose; enter boots" {
    var cfg = try config.parse(testing.allocator, sample, null);
    defer cfg.deinit();
    var f = FakeConsole{ .keys = &.{ .up, .up, .enter } };
    var buf: [256]u8 = undefined;
    const c = run(f.con(), &cfg, &buf).?;
    try testing.expectEqual(@as(usize, 2), c.index); // b -> a -> wraps to w
    try testing.expectEqualStrings("", c.cmdline);
}

test "timeout 0 boots immediately without drawing" {
    var cfg = try config.parse(testing.allocator, "timeout = 0\nimage = /k\nroot = /dev/x\n", null);
    defer cfg.deinit();
    var f = FakeConsole{ .keys = &.{} };
    var buf: [256]u8 = undefined;
    const c = run(f.con(), &cfg, &buf).?;
    try testing.expectEqualStrings("root=/dev/x", c.cmdline);
    try testing.expectEqual(@as(usize, 0), f.text_len);
}

test "editing the command line" {
    var cfg = try config.parse(testing.allocator, sample, null);
    defer cfg.deinit();
    // Select a, edit: Home, delete 'r','o' (root=...), type a prefix, End, add " debug".
    const typed = keysOf(" debug");
    const keys = [_]Key{ .up, .{ .char = 'e' }, .home, .delete, .delete, .{ .char = 'X' }, .end } ++ typed ++ [_]Key{.enter};
    var f = FakeConsole{ .keys = &keys };
    var buf: [256]u8 = undefined;
    const c = run(f.con(), &cfg, &buf).?;
    try testing.expectEqual(@as(usize, 0), c.index);
    try testing.expectEqualStrings("Xot=PARTUUID=x ro quiet debug", c.cmdline);
}

test "backspace, left/right and Esc going back to the menu" {
    var cfg = try config.parse(testing.allocator, sample, null);
    defer cfg.deinit();
    const keys = [_]Key{ .{ .char = 'e' }, .backspace, .backspace, .left, .left, .right, .esc, .enter };
    var f = FakeConsole{ .keys = &keys };
    var buf: [256]u8 = undefined;
    const c = run(f.con(), &cfg, &buf).?;
    // Esc discarded the edit; Enter then boots b with its unedited line.
    try testing.expectEqual(@as(usize, 1), c.index);
    try testing.expectEqualStrings("single", c.cmdline);
}

test "restricted entries ask for the password" {
    const pw_hash = "5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8"; // "password"
    const text = "password = " ++ pw_hash ++ "\nimage = /k\nlabel = k\nroot = /dev/x\nrestricted\n";
    var cfg = try config.parse(testing.allocator, text, null);
    defer cfg.deinit();
    var buf: [256]u8 = undefined;

    // Wrong password: back to the menu, then Enter boots with the stock line.
    const bad = [_]Key{.{ .char = 'e' }} ++ keysOf("nope") ++ [_]Key{ .enter, .timeout, .enter };
    var f1 = FakeConsole{ .keys = &bad };
    const c1 = run(f1.con(), &cfg, &buf).?;
    try testing.expectEqualStrings("root=/dev/x", c1.cmdline);
    // The typed password is never echoed.
    try testing.expect(std.mem.indexOf(u8, f1.text[0..f1.text_len], "nope") == null);

    // Right password: the editor opens.
    const good = [_]Key{.{ .char = 'e' }} ++ keysOf("password") ++ [_]Key{.enter} ++ keysOf("!") ++ [_]Key{.enter};
    var f2 = FakeConsole{ .keys = &good };
    const c2 = run(f2.con(), &cfg, &buf).?;
    try testing.expectEqualStrings("root=/dev/x!", c2.cmdline);
}

test "a loopback ISO entry tells the kernel where the ISO is" {
    var cfg = try config.parse(testing.allocator, "image = /boot/vmlinuz\n  append = \"quiet\"\n  iso = LABEL=data:/isos/rescue.iso\n", null);
    defer cfg.deinit();
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("quiet iso-scan/filename=/isos/rescue.iso", buildCmdline(cfg.entries[0], &buf));
}

test "no entries means the caller must prompt" {
    var cfg = try config.parse(testing.allocator, "", null);
    defer cfg.deinit();
    var f = FakeConsole{ .keys = &.{} };
    var buf: [8]u8 = undefined;
    try testing.expect(run(f.con(), &cfg, &buf) == null);
}

test "manual prompt returns what was typed" {
    const keys = keysOf("/vmlinuz") ++ [_]Key{.enter} ++ keysOf("ro") ++ [_]Key{.enter};
    var f = FakeConsole{ .keys = &keys };
    var p: [64]u8 = undefined;
    var c: [64]u8 = undefined;
    const r = manualPrompt(f.con(), &p, &c).?;
    try testing.expectEqualStrings("/vmlinuz", r.path);
    try testing.expectEqualStrings("ro", r.cmdline);
}
