//! Shared modules used by the BIOS loader, the UEFI loader and the Linux tool.

pub const blockdev = @import("blockdev.zig");
const fsread = @import("fsread");

pub const devio = @import("devio.zig");
pub const crc = fsread.crc;
pub const config = @import("config.zig");
pub const console = @import("console.zig");
pub const menu = @import("menu.zig");
pub const volumes = @import("volumes.zig");
pub const bootparams = @import("linux/bootparams.zig");
pub const lzo = fsread.lzo;
pub const part = @import("part.zig");
pub const btrfs = fsread.btrfs;
pub const fs = fsread.fs;
pub const fat = fsread.fat;
pub const iso9660 = fsread.iso9660;
pub const ext4 = fsread.ext4;

test {
    _ = blockdev;
    _ = devio;
    _ = config;
    _ = console;
    _ = menu;
    _ = volumes;
    _ = bootparams;
    _ = part;
    _ = @import("tests.zig");
}
