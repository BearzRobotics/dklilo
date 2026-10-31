//! BIOS console: VGA text through `int 10h`, keyboard through `int 16h`, and
//! COM1 mirrored in both directions (ANSI escapes out, ANSI keys in). Both are
//! live at once, so the menu works from the keyboard or over a serial line.

const rm = @import("realmode.zig");
const common = @import("common");
const Key = common.console.Key;

const com1: u16 = 0x3F8;

fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[v], %[p]"
        :
        : [v] "{al}" (value),
          [p] "{dx}" (port),
    );
}

fn inb(port: u16) u8 {
    return asm volatile ("inb %[p], %[v]"
        : [v] "={al}" (-> u8),
        : [p] "{dx}" (port),
    );
}

var screen_row: u16 = 0;
var screen_col: u16 = 0;
var attr: u8 = 0x07;
var serial_ok = false;

/// Programs COM1 for 115200 8N1 with FIFOs; sets `serial_ok` if a UART answers.
pub fn init() void {
    outb(com1 + 1, 0x00);
    outb(com1 + 3, 0x80);
    outb(com1 + 0, 0x01);
    outb(com1 + 1, 0x00);
    outb(com1 + 3, 0x03);
    outb(com1 + 2, 0xC7);
    outb(com1 + 4, 0x13); // loopback self-test
    outb(com1, 0xAE);
    serial_ok = inb(com1) == 0xAE;
    outb(com1 + 4, 0x03);
}

fn serialByte(c: u8) void {
    if (!serial_ok) return;
    var spins: u32 = 0;
    while (inb(com1 + 5) & 0x20 == 0) : (spins += 1) if (spins > 100000) return;
    outb(com1, c);
}

fn serialStr(s: []const u8) void {
    for (s) |c| serialByte(c);
}

fn gotoXY(row: u16, col: u16) void {
    _ = rm.int(0x10, .{ .eax = 0x0200, .ebx = 0, .edx = (@as(u32, row) << 8) | col });
}

fn putCell(c: u8) void {
    _ = rm.int(0x10, .{ .eax = 0x0900 | @as(u32, c), .ebx = attr, .ecx = 1 });
}

pub fn clear() void {
    _ = rm.int(0x10, .{ .eax = 0x0600, .ebx = @as(u32, 0x07) << 8, .ecx = 0, .edx = 0x184F });
    screen_row = 0;
    screen_col = 0;
    gotoXY(0, 0);
    serialStr("\x1b[0m\x1b[2J\x1b[H");
}

pub fn moveTo(row: u16, col: u16) void {
    screen_row = row;
    screen_col = col;
    gotoXY(row, col);
    var b: [16]u8 = undefined;
    const s = fmtMove(&b, row, col);
    serialStr(s);
}

fn fmtMove(b: *[16]u8, row: u16, col: u16) []const u8 {
    var n: usize = 0;
    b[n] = 0x1b;
    b[n + 1] = '[';
    n += 2;
    n += putNum(b[n..], row + 1);
    b[n] = ';';
    n += 1;
    n += putNum(b[n..], col + 1);
    b[n] = 'H';
    n += 1;
    return b[0..n];
}

fn putNum(out: []u8, v: u16) usize {
    var tmp: [5]u8 = undefined;
    var n: usize = 0;
    var x = v;
    while (true) {
        tmp[n] = '0' + @as(u8, @intCast(x % 10));
        n += 1;
        x /= 10;
        if (x == 0) break;
    }
    for (0..n) |i| out[i] = tmp[n - 1 - i];
    return n;
}

pub fn setHighlight(on: bool) void {
    attr = if (on) 0x70 else 0x07;
    serialStr(if (on) "\x1b[7m" else "\x1b[0m");
}

pub fn puts(s: []const u8) void {
    for (s) |c| {
        serialByte(c);
        switch (c) {
            '\r' => screen_col = 0,
            '\n' => {
                screen_row = @min(screen_row + 1, 24);
                screen_col = 0;
            },
            else => {
                gotoXY(screen_row, screen_col);
                putCell(c);
                screen_col += 1;
                if (screen_col >= 80) {
                    screen_col = 0;
                    screen_row = @min(screen_row + 1, 24);
                }
            },
        }
    }
    gotoXY(screen_row, screen_col);
}

pub fn cursor() struct { row: u8, col: u8 } {
    return .{ .row = @intCast(screen_row), .col = @intCast(screen_col) };
}

fn delay10ms() void {
    // int 15h ah=86h: wait cx:dx microseconds.
    _ = rm.int(0x15, .{ .eax = 0x8600, .ecx = 0, .edx = 10_000 });
}

fn serialReady() bool {
    return serial_ok and inb(com1 + 5) & 1 != 0;
}

/// Reads the rest of an ANSI escape sequence after ESC arrived on the serial
/// line. A lone ESC (nothing follows within ~50 ms) is the Esc key.
fn serialEscape() Key {
    var tries: u32 = 0;
    while (!serialReady()) : (tries += 1) {
        if (tries >= 5) return .esc;
        delay10ms();
    }
    const c1 = inb(com1);
    if (c1 != '[' and c1 != 'O') return .esc;
    var param: u8 = 0;
    while (true) {
        tries = 0;
        while (!serialReady()) : (tries += 1) {
            if (tries >= 5) return .esc;
            delay10ms();
        }
        const c = inb(com1);
        switch (c) {
            'A' => return .up,
            'B' => return .down,
            'C' => return .right,
            'D' => return .left,
            'H' => return .home,
            'F' => return .end,
            '~' => return switch (param) {
                1, 7 => .home,
                3 => .delete,
                4, 8 => .end,
                else => .esc,
            },
            '0'...'9' => param = c - '0',
            else => if (c >= 0x40) return .esc,
        }
    }
}

fn serialKey() ?Key {
    if (!serialReady()) return null;
    const c = inb(com1);
    return switch (c) {
        '\r', '\n' => .enter,
        0x7F, 0x08 => .backspace,
        '\t' => .tab,
        0x1B => serialEscape(),
        0x20...0x7E => .{ .char = c },
        else => null,
    };
}

fn keyboardKey() ?Key {
    const peek = rm.int(0x16, .{ .eax = 0x0100 });
    if (peek.eflags & 0x40 != 0) return null; // ZF set: no key
    const r = rm.int(0x16, .{ .eax = 0x0000 });
    const scan: u8 = @truncate(r.eax >> 8);
    const ascii: u8 = @truncate(r.eax);
    switch (scan) {
        0x48 => if (ascii == 0 or ascii == 0xE0) return .up,
        0x50 => if (ascii == 0 or ascii == 0xE0) return .down,
        0x4B => if (ascii == 0 or ascii == 0xE0) return .left,
        0x4D => if (ascii == 0 or ascii == 0xE0) return .right,
        0x47 => if (ascii == 0 or ascii == 0xE0) return .home,
        0x4F => if (ascii == 0 or ascii == 0xE0) return .end,
        0x53 => if (ascii == 0 or ascii == 0xE0) return .delete,
        else => {},
    }
    return switch (ascii) {
        0x1B => .esc,
        '\r' => .enter,
        0x08 => .backspace,
        '\t' => .tab,
        0x20...0x7E => .{ .char = ascii },
        else => null,
    };
}

pub fn getKey(timeout_ms: ?u32) Key {
    var waited: u32 = 0;
    while (true) {
        if (keyboardKey()) |k| return k;
        if (serialKey()) |k| return k;
        if (timeout_ms) |t| if (waited >= t) return .timeout;
        delay10ms();
        waited += 10;
    }
}

pub fn size() common.console.Size {
    return .{ .rows = 25, .cols = 80 };
}

fn vClear(_: *anyopaque) void {
    clear();
}
fn vMoveTo(_: *anyopaque, r: u16, c: u16) void {
    moveTo(r, c);
}
fn vHighlight(_: *anyopaque, on: bool) void {
    setHighlight(on);
}
fn vPuts(_: *anyopaque, s: []const u8) void {
    puts(s);
}
fn vGetKey(_: *anyopaque, t: ?u32) Key {
    return getKey(t);
}
fn vSize(_: *anyopaque) common.console.Size {
    return size();
}

const vtable = common.console.Console.VTable{
    .clear = vClear,
    .moveTo = vMoveTo,
    .setHighlight = vHighlight,
    .puts = vPuts,
    .getKey = vGetKey,
    .size = vSize,
};
var dummy: u8 = 0;

pub fn console() common.console.Console {
    return .{ .ctx = &dummy, .vtable = &vtable };
}
