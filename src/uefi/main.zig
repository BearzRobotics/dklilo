//! UEFI loader (L0 skeleton). Prints a banner on the firmware console.

const std = @import("std");
const uefi = std.os.uefi;

pub fn main() void {
    const out = uefi.system_table.con_out.?;
    _ = out.outputString(std.unicode.utf8ToUtf16LeStringLiteral("dklilo\r\n")) catch {};
    // Give a human/serial observer time to see it, then return to firmware.
    _ = uefi.system_table.boot_services.?.stall(1_000_000) catch {};
}
