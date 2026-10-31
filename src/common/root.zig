//! Shared modules used by the BIOS loader, the UEFI loader and the Linux tool.

pub const blockdev = @import("blockdev.zig");
pub const crc = @import("crc.zig");
pub const part = @import("part.zig");
pub const ext4 = @import("fs/ext4.zig");

test {
    _ = blockdev;
    _ = crc;
    _ = part;
    _ = ext4;
    _ = @import("tests.zig");
}
