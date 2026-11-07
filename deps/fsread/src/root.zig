//! Read-only filesystem readers (ext2/3/4, btrfs, FAT12/16/32, ISO 9660) that
//! take their I/O from a `std.Io`, so they run unchanged on a hosted OS and in
//! a freestanding bootloader.
//!
//! `fs.Fs` detects the filesystem on a `Region` and presents one interface;
//! the individual readers are exported too and are only compiled if used.

pub const region = @import("region.zig");
pub const Region = region.Region;
pub const fs = @import("fs.zig");
pub const ext4 = @import("ext4.zig");
pub const btrfs = @import("btrfs.zig");
pub const fat = @import("fat.zig");
pub const iso9660 = @import("iso9660.zig");
pub const crc = @import("crc.zig");
pub const lzo = @import("lzo.zig");

test {
    _ = region;
    _ = fs;
    _ = ext4;
    _ = btrfs;
    _ = fat;
    _ = iso9660;
    _ = crc;
    _ = lzo;
}
