//! The console as the menu sees it: a text screen plus a keyboard, behind one
//! interface. The BIOS build backs it with `int 10h`/`int 16h` and COM1, the
//! UEFI build with SimpleTextInput/Output and the serial port, and tests with
//! a scripted fake. Serial and screen are mirrored by the implementation.

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
