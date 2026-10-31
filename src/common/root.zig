//! Shared modules used by the BIOS loader, the UEFI loader and the Linux tool.

pub const blockdev = @import("blockdev.zig");
pub const crc = @import("crc.zig");
pub const config = @import("config.zig");
pub const console = @import("console.zig");
pub const menu = @import("menu.zig");
pub const volumes = @import("volumes.zig");
pub const bootparams = @import("linux/bootparams.zig");
pub const lzo = @import("compress/lzo.zig");
pub const part = @import("part.zig");
pub const btrfs = @import("fs/btrfs.zig");
pub const fs = @import("fs/fs.zig");
pub const ext4 = @import("fs/ext4.zig");

test {
    _ = blockdev;
    _ = crc;
    _ = config;
    _ = console;
    _ = menu;
    _ = volumes;
    _ = bootparams;
    _ = lzo;
    _ = part;
    _ = btrfs;
    _ = fs;
    _ = ext4;
    _ = @import("tests.zig");
}
