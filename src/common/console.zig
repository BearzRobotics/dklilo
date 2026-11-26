//! The console as the menu sees it: a text screen plus a keyboard, behind one
//! interface. The BIOS build backs it with `int 10h`/`int 16h` and COM1, the
//! UEFI build with SimpleTextInput/Output and the serial port, and tests with
//! a scripted fake. Serial and screen are mirrored by the implementation.

const std = @import("std");

pub const Key = union(enum) {
    /// A printable ASCII character.
    char: u8,
    up,
    down,
    left,
    right,
    home,
    end,
    delete,
    backspace,
    enter,
    esc,
    tab,
    /// A key on the keyboard with no meaning here. It still stops a countdown.
    other,
    /// `getKey` waited the full timeout without a key.
    timeout,
};

pub const Size = struct { rows: u16, cols: u16 };

pub const Console = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        clear: *const fn (ctx: *anyopaque) void,
        /// 0-based position.
        moveTo: *const fn (ctx: *anyopaque, row: u16, col: u16) void,
        setHighlight: *const fn (ctx: *anyopaque, on: bool) void,
        puts: *const fn (ctx: *anyopaque, s: []const u8) void,
        /// Waits for a key; `null` waits forever, otherwise returns `.timeout`
        /// after that many milliseconds.
        getKey: *const fn (ctx: *anyopaque, timeout_ms: ?u32) Key,
        size: *const fn (ctx: *anyopaque) Size,
    };

    pub fn clear(self: Console) void {
        self.vtable.clear(self.ctx);
    }
    pub fn moveTo(self: Console, row: u16, col: u16) void {
        self.vtable.moveTo(self.ctx, row, col);
    }
    pub fn setHighlight(self: Console, on: bool) void {
        self.vtable.setHighlight(self.ctx, on);
    }
    pub fn puts(self: Console, s: []const u8) void {
        self.vtable.puts(self.ctx, s);
    }
    pub fn getKey(self: Console, timeout_ms: ?u32) Key {
        return self.vtable.getKey(self.ctx, timeout_ms);
    }
    pub fn size(self: Console) Size {
        return self.vtable.size(self.ctx);
    }
};

/// Converts UTF-8 to UTF-16, as UEFI wants its text, and returns the number of
/// code units. `out` needs room for `text.len`. A byte that is not part of
/// valid UTF-8 becomes the code unit of the same value.
pub fn utf16FromUtf8(out: []u16, text: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        // One byte on its own, unless a whole valid sequence starts here.
        var point: u21 = text[i];
        var len: usize = 1;
        if (std.unicode.utf8ByteSequenceLength(text[i])) |expected| {
            if (expected > 1 and expected <= text.len - i) {
                if (std.unicode.utf8Decode(text[i..][0..expected])) |decoded| {
                    point = decoded;
                    len = expected;
                } else |_| {}
            }
        } else |_| {}
        i += len;
        if (point < 0x10000) {
            out[n] = @intCast(point);
            n += 1;
        } else {
            const v = point - 0x10000;
            out[n] = @intCast(0xD800 + (v >> 10));
            out[n + 1] = @intCast(0xDC00 + (v & 0x3FF));
            n += 2;
        }
    }
    return n;
}

test "utf16FromUtf8" {
    var out: [32]u16 = undefined;
    const expect = struct {
        fn f(want: []const u16, got: []const u16) !void {
            try std.testing.expectEqualSlices(u16, want, got);
        }
    }.f;
    try expect(&.{ 'a', 0xE9, 0x20AC, 0xD83D, 0xDE00 }, out[0..utf16FromUtf8(&out, "a\u{e9}\u{20ac}\u{1f600}")]);
    // U+00C3 is the same number as the first byte that encodes it.
    try expect(&.{ 0xC3, '!' }, out[0..utf16FromUtf8(&out, "\u{c3}!")]);
    // Bytes that aren't valid UTF-8 are kept one by one.
    try expect(&.{ 0xFF, 'x', 0xC3 }, out[0..utf16FromUtf8(&out, "\xFFx\xC3")]);
    try expect(&.{ 0xC3, 'a' }, out[0..utf16FromUtf8(&out, "\xC3a")]);
}
