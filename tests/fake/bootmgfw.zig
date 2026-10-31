//! A stand-in for Windows Boot Manager, to test chainloading without Windows.
//! Real boot managers locate their own volume from the loaded image's device
//! handle, so this checks that the loader provided one.

const std = @import("std");
const uefi = std.os.uefi;

pub fn main() void {
    const out = uefi.system_table.con_out.?;
    const bs = uefi.system_table.boot_services.?;
    const li = bs.handleProtocol(uefi.protocol.LoadedImage, uefi.handle) catch null;
    const have_device = if (li) |l| l.device_handle != null else false;
    const msg: [*:0]const u16 = if (have_device)
        std.unicode.utf8ToUtf16LeStringLiteral("FAKE-BOOTMGR-OK device=yes\r\n")
    else
        std.unicode.utf8ToUtf16LeStringLiteral("FAKE-BOOTMGR-OK device=no\r\n");
    _ = out.outputString(msg) catch {};
    bs.stall(500_000) catch {};
}
