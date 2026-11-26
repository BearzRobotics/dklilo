//! The boot menu: a list of entries with a countdown to the default, and a
//! command-line editor. It only talks to a `Console`, so the same code runs
//! on BIOS, UEFI and in tests.
//!
//! Keys: Up/Down choose, Enter boots, `e` edits the command line (needs the
//! password if one is configured and the entry is `restricted`), `m` boots a
//! kernel by hand (needs the password if one is configured), any key stops the
//! countdown.

const std = @import("std");
const config = @import("config.zig");
const console = @import("console.zig");
const Console = console.Console;
const Key = console.Key;

/// The headings of the two screens. `dklilo install-uefi` also looks for
/// them to recognise an installed loader, so changing one stops it from
/// recognising loaders already installed.
pub const title = "dklilo boot menu";
pub const manual_title = "dklilo: no usable configuration";

pub const Choice = struct {
    index: usize,
    /// Kernel command line (empty for chainload entries); lives in the
    /// buffer passed to `run`.
    cmdline: []const u8,
};

/// The room the loaders have for a command line.
pub const max_cmdline = 1024;

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

/// What the user, or the countdown, asked for.
pub const Result = union(enum) {
    boot: Choice,
    /// Ask for a kernel path and command line (`manualPrompt`). Any password
    /// has already been given.
    manual,
};

/// The longest password that can be typed.
const max_password = 256;
/// How long "Access denied" stays up before another try, in 100 ms steps.
const denied_ticks = 15;

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

/// Screen rows the menu needs besides the entries: the title and a blank, then
/// a blank, the key help, the countdown, a blank and two rows for questions.
const rows_around_list = 8;

/// How many entries are on screen at once.
fn listRows(con: Console, cfg: *const config.Config) usize {
    return @max(1, @min(cfg.entries.len, con.size().rows -| rows_around_list));
}

fn draw(con: Console, cfg: *const config.Config, sel: usize, remaining: ?u32) void {
    con.clear();
    con.moveTo(0, 0);
    con.puts(title);
    // A long list scrolls just enough to keep the selection on screen.
    const rows = listRows(con, cfg);
    const first = if (sel < rows) 0 else sel - rows + 1;
    for (cfg.entries[first..][0..rows], first.., 0..) |e, i, row| {
        con.moveTo(@intCast(2 + row), 0);
        con.puts(if (row == 0 and first > 0) "^" else if (row == rows - 1 and i + 1 < cfg.entries.len) "v" else " ");
        con.moveTo(@intCast(2 + row), 2);
        con.setHighlight(i == sel);
        con.puts(" ");
        con.puts(e.label);
        con.puts(" ");
        con.setHighlight(false);
    }
    con.moveTo(@intCast(3 + rows), 0);
    con.puts("Up/Down: choose  Enter: boot  e: edit command line  m: boot by hand");
    if (remaining) |r| drawCountdown(con, cfg, r);
}

/// Rewrites only the countdown line, so the menu doesn't flicker while the
/// timer runs.
fn drawCountdown(con: Console, cfg: *const config.Config, remaining: u32) void {
    con.moveTo(@intCast(4 + listRows(con, cfg)), 0);
    var b: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&b, "Booting in {d} s (any key stops)   ", .{seconds(remaining)}) catch "";
    con.puts(s);
}

/// Tenths of a second as whole seconds, rounded up.
fn seconds(tenths: u32) u32 {
    return tenths / 10 + @intFromBool(tenths % 10 != 0);
}

/// Shows the menu and returns what to do, or null if there are no entries
/// (the caller then offers a manual prompt).
///
/// After a boot has failed, pass `after_failure`: the menu is then always
/// shown and nothing boots until a key says so. Otherwise a configuration that
/// boots at once would retry the same entry for ever.
pub fn run(con: Console, cfg: *const config.Config, cmd_buf: []u8, after_failure: bool) ?Result {
    if (cfg.entries.len == 0) return null;
    var sel = cfg.defaultIndex();

    // Boot at once when nothing asks us to wait.
    const immediate = (cfg.timeout orelse 1) == 0 or (cfg.entries.len == 1 and !cfg.prompt and cfg.timeout != null);
    if (immediate and !after_failure) return boot(cfg, sel, cmd_buf);

    var remaining: ?u32 = if (after_failure) null else cfg.timeout; // tenths of a second
    var full = true; // redraw everything, or just the countdown line
    while (true) {
        if (full) draw(con, cfg, sel, remaining);
        const key = con.getKey(if (remaining != null) 100 else null);
        switch (key) {
            .timeout => {
                const r = remaining.?;
                if (r <= 1) return boot(cfg, sel, cmd_buf);
                remaining = r - 1;
                full = false;
                // Touch the screen only when the displayed second changes.
                if (seconds(r - 1) != seconds(r)) drawCountdown(con, cfg, r - 1);
                continue;
            },
            else => {
                remaining = null;
                full = true;
            },
        }
        switch (key) {
            .up => sel = if (sel == 0) cfg.entries.len - 1 else sel - 1,
            .down => sel = (sel + 1) % cfg.entries.len,
            .enter => return boot(cfg, sel, cmd_buf),
            .char => |c| if (c == 'e' and cfg.entries[sel].kind == .linux) {
                if (edit(con, cfg, sel, cmd_buf)) |line| return .{ .boot = .{ .index = sel, .cmdline = line } };
            } else if (c == 'm') {
                if (cfg.password == null or askPassword(con, cfg, promptRow(con, cfg))) return .manual;
            },
            else => {},
        }
    }
}

fn boot(cfg: *const config.Config, sel: usize, cmd_buf: []u8) Result {
    return .{ .boot = .{ .index = sel, .cmdline = buildCmdline(cfg.entries[sel], cmd_buf) } };
}

/// The screen row below the menu where questions are asked.
fn promptRow(con: Console, cfg: *const config.Config) u16 {
    return @intCast(6 + listRows(con, cfg));
}

/// Asks for the password. A wrong one is followed by a pause that typing
/// cannot cut short.
fn askPassword(con: Console, cfg: *const config.Config, row: u16) bool {
    var pw: [max_password]u8 = undefined;
    defer std.crypto.secureZero(u8, &pw);
    var pw_len: usize = 0;
    con.moveTo(row, 0);
    con.puts("Password: ");
    const r = editLine(con, row, 10, &pw, &pw_len, true);
    if (r == .accepted and passwordOk(cfg, pw[0..pw_len])) return true;
    con.moveTo(row + 1, 0);
    con.puts("Access denied.");
    var ticks: u32 = 0;
    while (ticks < denied_ticks) {
        // Keys pressed during the pause are read and thrown away.
        if (con.getKey(100) == .timeout) ticks += 1;
    }
    return false;
}

/// Edits the entry's command line. Returns the final line, or null if the
/// user cancelled (or failed the password) and wants the menu back.
fn edit(con: Console, cfg: *const config.Config, sel: usize, cmd_buf: []u8) ?[]const u8 {
    const entry = cfg.entries[sel];
    const row = promptRow(con, cfg);

    if (cfg.password != null and entry.restricted) {
        if (!askPassword(con, cfg, row)) return null;
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

/// Why the manual prompt is shown, which decides its heading.
pub const ManualReason = enum { no_config, chosen };

/// Asks for a kernel path and command line by hand: when there is no usable
/// configuration, so a broken one never leaves the machine unbootable, or from
/// the menu. Writes "path" and "cmdline" into the buffers and returns their
/// lengths, or null if the user pressed Esc.
pub fn manualPrompt(con: Console, reason: ManualReason, path_buf: []u8, cmd_buf: []u8) ?struct { path: []const u8, cmdline: []const u8 } {
    con.clear();
    con.moveTo(0, 0);
    con.puts(switch (reason) {
        .no_config => manual_title ++ ". Boot by hand.",
        .chosen => "Boot by hand. (Esc goes back)",
    });
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
    /// The lowest row anything was written to.
    max_row: u16 = 0,

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
    fn moveTo(ctx: *anyopaque, row: u16, _: u16) void {
        const f = me(ctx);
        f.max_row = @max(f.max_row, row);
    }
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
    const c = run(f.con(), &cfg, &buf, false).?.boot;
    try testing.expectEqual(@as(usize, 1), c.index);
    try testing.expectEqualStrings("single", c.cmdline);
    try testing.expectEqual(@as(usize, 30), f.timeouts_seen + 0); // 3 s at 100 ms ticks
}

test "any key stops the countdown; arrows choose; enter boots" {
    var cfg = try config.parse(testing.allocator, sample, null);
    defer cfg.deinit();
    var f = FakeConsole{ .keys = &.{ .up, .up, .enter } };
    var buf: [256]u8 = undefined;
    const c = run(f.con(), &cfg, &buf, false).?.boot;
    try testing.expectEqual(@as(usize, 2), c.index); // b -> a -> wraps to w
    try testing.expectEqualStrings("", c.cmdline);
}

test "timeout 0 boots immediately without drawing" {
    var cfg = try config.parse(testing.allocator, "timeout = 0\nimage = /k\nroot = /dev/x\n", null);
    defer cfg.deinit();
    var f = FakeConsole{ .keys = &.{} };
    var buf: [256]u8 = undefined;
    const c = run(f.con(), &cfg, &buf, false).?.boot;
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
    const c = run(f.con(), &cfg, &buf, false).?.boot;
    try testing.expectEqual(@as(usize, 0), c.index);
    try testing.expectEqualStrings("Xot=PARTUUID=x ro quiet debug", c.cmdline);
}

test "backspace, left/right and Esc going back to the menu" {
    var cfg = try config.parse(testing.allocator, sample, null);
    defer cfg.deinit();
    const keys = [_]Key{ .{ .char = 'e' }, .backspace, .backspace, .left, .left, .right, .esc, .enter };
    var f = FakeConsole{ .keys = &keys };
    var buf: [256]u8 = undefined;
    const c = run(f.con(), &cfg, &buf, false).?.boot;
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
    const bad = [_]Key{.{ .char = 'e' }} ++ keysOf("nope") ++ [_]Key{.enter} ++ @as([denied_ticks]Key, @splat(.timeout)) ++ [_]Key{.enter};
    var f1 = FakeConsole{ .keys = &bad };
    const c1 = run(f1.con(), &cfg, &buf, false).?.boot;
    try testing.expectEqualStrings("root=/dev/x", c1.cmdline);
    // The typed password is never echoed.
    try testing.expect(std.mem.indexOf(u8, f1.text[0..f1.text_len], "nope") == null);

    // Right password: the editor opens.
    const good = [_]Key{.{ .char = 'e' }} ++ keysOf("password") ++ [_]Key{.enter} ++ keysOf("!") ++ [_]Key{.enter};
    var f2 = FakeConsole{ .keys = &good };
    const c2 = run(f2.con(), &cfg, &buf, false).?.boot;
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
    try testing.expect(run(f.con(), &cfg, &buf, false) == null);
}

test "manual prompt returns what was typed" {
    const keys = keysOf("/vmlinuz") ++ [_]Key{.enter} ++ keysOf("ro") ++ [_]Key{.enter};
    var f = FakeConsole{ .keys = &keys };
    var p: [64]u8 = undefined;
    var c: [64]u8 = undefined;
    const r = manualPrompt(f.con(), .no_config, &p, &c).?;
    try testing.expectEqualStrings("/vmlinuz", r.path);
    try testing.expectEqualStrings("ro", r.cmdline);
}

test "after a failed boot the menu always waits" {
    // Both of these boot at once, until a boot has failed.
    for ([_][]const u8{ "timeout = 0\nimage = /a\nimage = /b\n", "timeout = 50\nimage = /a\n" }) |text| {
        var cfg = try config.parse(testing.allocator, text, null);
        defer cfg.deinit();
        var buf: [256]u8 = undefined;
        var f = FakeConsole{ .keys = &.{.enter} };
        _ = run(f.con(), &cfg, &buf, true).?.boot;
        try testing.expect(std.mem.indexOf(u8, f.text[0..f.text_len], title) != null);
        try testing.expectEqual(@as(usize, 1), f.next); // a key was waited for,
        try testing.expectEqual(@as(usize, 0), f.timeouts_seen); // with no countdown
    }
}

test "m boots by hand, behind the password if there is one" {
    var buf: [256]u8 = undefined;
    {
        var cfg = try config.parse(testing.allocator, sample, null);
        defer cfg.deinit();
        var f = FakeConsole{ .keys = &.{.{ .char = 'm' }} };
        try testing.expect(run(f.con(), &cfg, &buf, false).? == .manual);
    }
    // The password guards it even when no entry is `restricted`.
    const pw_hash = "5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8"; // "password"
    var cfg = try config.parse(testing.allocator, "password = " ++ pw_hash ++ "\nimage = /k\n", null);
    defer cfg.deinit();
    // Keys typed during the pause after a wrong password are thrown away: the
    // 'm' here must not count.
    const keys = [_]Key{ .{ .char = 'm' }, .{ .char = 'x' }, .enter, .{ .char = 'm' } } ++
        @as([denied_ticks]Key, @splat(.timeout)) ++ [_]Key{.{ .char = 'm' }} ++ keysOf("password") ++ [_]Key{.enter};
    var f = FakeConsole{ .keys = &keys };
    try testing.expect(run(f.con(), &cfg, &buf, false).? == .manual);
    try testing.expectEqual(keys.len, f.next);
}

test "a password longer than 64 characters works" {
    const long = &@as([100]u8, @splat('k'));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(long, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    var text: [128]u8 = undefined;
    var cfg = try config.parse(testing.allocator, try std.fmt.bufPrint(&text, "password = {s}\nimage = /k\n", .{&hex}), null);
    defer cfg.deinit();
    const keys = [_]Key{.{ .char = 'm' }} ++ keysOf(long) ++ [_]Key{.enter};
    var f = FakeConsole{ .keys = &keys };
    var buf: [256]u8 = undefined;
    try testing.expect(run(f.con(), &cfg, &buf, false).? == .manual);
}

test "a long menu scrolls and stays on the screen" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "timeout = 600\nprompt\n");
    for (0..40) |i| try text.print(testing.allocator, "image = /boot/k{d}\n  label = entry-{d}.\n", .{ i, i });
    var cfg = try config.parse(testing.allocator, text.items, null);
    defer cfg.deinit();
    var buf: [256]u8 = undefined;
    // Up wraps to the last entry, which has to come into view; then open the
    // editor on it.
    var f = FakeConsole{ .keys = &.{ .up, .{ .char = 'e' }, .enter } };
    const c = run(f.con(), &cfg, &buf, false).?.boot;
    try testing.expectEqual(@as(usize, 39), c.index);
    try testing.expect(std.mem.indexOf(u8, f.text[0..f.text_len], "entry-39.") != null);
    try testing.expect(f.max_row < 25);
}

test "the longest possible timeout doesn't overflow" {
    var cfg = try config.parse(testing.allocator, "timeout = 4294967295\nprompt\nimage = /k\n", null);
    defer cfg.deinit();
    var buf: [256]u8 = undefined;
    var f = FakeConsole{ .keys = &.{ .timeout, .enter } };
    _ = run(f.con(), &cfg, &buf, false).?.boot;
    try testing.expect(std.mem.indexOf(u8, f.text[0..f.text_len], "429496730 s") != null);
}
