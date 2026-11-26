//! A stand-in for Windows Boot Manager, to test chainloading without Windows.
//! Real boot managers locate their own volume from the loaded image's device
//! handle, so this checks that the loader provided one.
//!
//! The retry test also boots it as a "kernel": it says how large an initramfs
//! the loader is offering through `LoadFile2`, if any, and returns.

const std = @import("std");
const uefi = std.os.uefi;

const LoadFile2 = extern struct {
    load_file: *const fn (*LoadFile2, ?*const anyopaque, bool, *usize, ?*anyopaque) callconv(uefi.cc) uefi.Status,

    pub const guid align(8) = uefi.Guid{
        .time_low = 0x4006c0c1,
        .time_mid = 0xfcb3,
        .time_high_and_version = 0x403e,
        .clock_seq_high_and_reserved = 0x99,
        .clock_seq_low = 0x6d,
        .node = .{ 0x4a, 0x6c, 0x87, 0x24, 0xe0, 0x6d },
    };
};

/// LINUX_EFI_INITRD_MEDIA_GUID as it appears in the device path.
const initrd_media = [16]u8{ 0x27, 0xe4, 0x68, 0x55, 0xfc, 0x68, 0x3d, 0x4f, 0xac, 0x74, 0xca, 0x55, 0x52, 0x31, 0xcc, 0x68 };

/// The size of the offered initramfs, found the way Linux's EFI stub finds it.
fn initrdSize(bs: *uefi.tables.BootServices) ?usize {
    const handles = (bs.locateHandleBuffer(.{ .by_protocol = &LoadFile2.guid }) catch null) orelse return null;
    for (handles) |h| {
        const dp = (bs.handleProtocol(uefi.protocol.DevicePath, h) catch null) orelse continue;
        const bytes: [*]const u8 = @ptrCast(dp);
        if (dp.size() < 24 or !std.mem.eql(u8, bytes[4..20], &initrd_media)) continue;
        const lf = (bs.handleProtocol(LoadFile2, h) catch null) orelse continue;
        var size: usize = 0;
        _ = lf.load_file(lf, null, false, &size, null);
        return size;
    }
    return null;
}

pub fn main() void {
    const out = uefi.system_table.con_out.?;
    const bs = uefi.system_table.boot_services.?;
    const li = bs.handleProtocol(uefi.protocol.LoadedImage, uefi.handle) catch null;
    const have_device = if (li) |l| l.device_handle != null else false;

    var text: [96]u8 = undefined;
    const device: []const u8 = if (have_device) "yes" else "no";
    const line = if (initrdSize(bs)) |n|
        std.fmt.bufPrint(&text, "FAKE-BOOTMGR-OK device={s} initrd={d}\r\n", .{ device, n }) catch return
    else
        std.fmt.bufPrint(&text, "FAKE-BOOTMGR-OK device={s} initrd=none\r\n", .{device}) catch return;
    var wide: [96:0]u16 = undefined;
    for (line, 0..) |c, i| wide[i] = c;
    wide[line.len] = 0;
    _ = out.outputString(wide[0..line.len :0]) catch {};
    // The command line's non-ASCII characters, as code units in hex, to check
    // that it arrived as text and not as bytes.
    if (li) |l| if (l.load_options) |p| {
        const units: [*]const u16 = @ptrCast(@alignCast(p));
        for (units[0 .. l.load_options_size / 2]) |u| {
            if (u < 0x80) continue;
            const hex = std.fmt.bufPrint(&text, "unit={x:0>4} ", .{u}) catch return;
            for (hex, 0..) |c, i| wide[i] = c;
            wide[hex.len] = 0;
            _ = out.outputString(wide[0..hex.len :0]) catch {};
        }
    };
    bs.stall(500_000) catch {};
}
