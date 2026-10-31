//! The x86 Linux boot protocol: the setup header found in every bzImage and
//! the "zero page" (`boot_params`) a loader hands to the kernel.
//!
//! Specification: Documentation/arch/x86/boot.rst in the kernel tree
//! (https://www.kernel.org/doc/html/latest/arch/x86/boot.html), and
//! arch/x86/include/uapi/asm/bootparam.h for the structure layouts.

const std = @import("std");

/// Offset of the setup header inside both the bzImage and `boot_params`.
pub const header_offset = 0x1F1;
pub const boot_params_size = 4096;

/// `struct setup_header` (boot.rst, "The Real-Mode Kernel Header"). Fields
/// are byte-packed to match the file offsets shown in the comments.
pub const SetupHeader = extern struct {
    setup_sects: u8, // 1F1
    root_flags: u16 align(1), // 1F2
    syssize: u32 align(1), // 1F4
    ram_size: u16 align(1), // 1F8
    vid_mode: u16 align(1), // 1FA
    root_dev: u16 align(1), // 1FC
    boot_flag: u16 align(1), // 1FE
    jump: u16 align(1), // 200
    header: u32 align(1), // 202, "HdrS"
    version: u16 align(1), // 206
    realmode_swtch: u32 align(1), // 208
    start_sys_seg: u16 align(1), // 20C
    kernel_version: u16 align(1), // 20E
    type_of_loader: u8, // 210
    loadflags: u8, // 211
    setup_move_size: u16 align(1), // 212
    code32_start: u32 align(1), // 214
    ramdisk_image: u32 align(1), // 218
    ramdisk_size: u32 align(1), // 21C
    bootsect_kludge: u32 align(1), // 220
    heap_end_ptr: u16 align(1), // 224
    ext_loader_ver: u8, // 226
    ext_loader_type: u8, // 227
    cmd_line_ptr: u32 align(1), // 228
    initrd_addr_max: u32 align(1), // 22C
    kernel_alignment: u32 align(1), // 230
    relocatable_kernel: u8, // 234
    min_alignment: u8, // 235
    xloadflags: u16 align(1), // 236
    cmdline_size: u32 align(1), // 238
    hardware_subarch: u32 align(1), // 23C
    hardware_subarch_data: u64 align(1), // 240
    payload_offset: u32 align(1), // 248
    payload_length: u32 align(1), // 24C
    setup_data: u64 align(1), // 250
    pref_address: u64 align(1), // 258
    init_size: u32 align(1), // 260
    handover_offset: u32 align(1), // 264
    kernel_info_offset: u32 align(1), // 268
};

/// `loadflags` bits.
pub const loaded_high: u8 = 0x01;
pub const can_use_heap: u8 = 0x80;

/// One `E820` memory map entry as stored in `boot_params.e820_table`.
pub const E820Entry = extern struct {
    addr: u64 align(1),
    size: u64 align(1),
    kind: u32 align(1),

    pub const usable: u32 = 1;
};

pub const max_e820 = 128;

/// Offsets inside `boot_params` (bootparam.h).
const off_e820_entries = 0x1E8;
const off_e820_table = 0x2D0;

comptime {
    std.debug.assert(@sizeOf(SetupHeader) == 0x26C - header_offset);
    std.debug.assert(@offsetOf(SetupHeader, "code32_start") == 0x214 - header_offset);
    std.debug.assert(@offsetOf(SetupHeader, "cmd_line_ptr") == 0x228 - header_offset);
    std.debug.assert(@offsetOf(SetupHeader, "pref_address") == 0x258 - header_offset);
    std.debug.assert(@offsetOf(SetupHeader, "kernel_info_offset") == 0x268 - header_offset);
    std.debug.assert(@sizeOf(E820Entry) == 20);
}

pub const Error = error{
    /// Not a Linux bzImage (no "HdrS" magic or boot flag).
    NotLinux,
    /// Boot protocol older than 2.10, or not loadable high.
    TooOld,
};

/// What a loader needs to know about a kernel image.
pub const Kernel = struct {
    header: SetupHeader,
    /// Bytes of real-mode setup code (the protected-mode kernel starts here).
    setup_size: u32,
    /// Size of the protected-mode kernel within a file of `file_size` bytes.
    pm_size: u32,
};

/// Parses and validates the start of a bzImage (at least 0x270 bytes).
pub fn parseKernel(image_start: []const u8, file_size: u64) Error!Kernel {
    if (image_start.len < 0x270) return error.NotLinux;
    var hdr: SetupHeader = undefined;
    @memcpy(std.mem.asBytes(&hdr), image_start[header_offset..][0..@sizeOf(SetupHeader)]);
    if (hdr.header != 0x53726448 or hdr.boot_flag != 0xAA55) return error.NotLinux; // "HdrS"
    if (hdr.version < 0x020A or hdr.loadflags & loaded_high == 0) return error.TooOld;
    const sects: u32 = if (hdr.setup_sects == 0) 4 else hdr.setup_sects;
    const setup_size = (sects + 1) * 512;
    if (file_size <= setup_size) return error.NotLinux;
    return .{ .header = hdr, .setup_size = setup_size, .pm_size = @intCast(file_size - setup_size) };
}

/// Fills in a zeroed `boot_params` page: the kernel's own setup header with
/// our fields set, plus the E820 map. The caller sets `cmd_line_ptr` etc. via
/// the returned header pointer.
pub fn initBootParams(page: *[boot_params_size]u8, kernel: Kernel, e820: []const E820Entry) *align(1) SetupHeader {
    @memset(page, 0);
    // Real-mode header bytes are copied as the kernel provided them (the
    // protocol says to copy 0x202 + the jump byte count), then updated.
    const hdr: *align(1) SetupHeader = @ptrCast(&page[header_offset]);
    hdr.* = kernel.header;
    hdr.type_of_loader = 0xFF; // dklilo has no assigned loader ID
    hdr.loadflags &= ~@as(u8, 0x20); // QUIET_FLAG off: let the kernel decide
    hdr.loadflags |= loaded_high;
    hdr.ramdisk_image = 0;
    hdr.ramdisk_size = 0;
    hdr.vid_mode = 0xFFFF; // normal
    hdr.setup_data = 0;
    const n = @min(e820.len, max_e820);
    page[off_e820_entries] = @intCast(n);
    for (e820[0..n], 0..) |e, i| {
        const dst: *align(1) E820Entry = @ptrCast(&page[off_e820_table + i * @sizeOf(E820Entry)]);
        dst.* = e;
    }
    return hdr;
}

/// Fills `boot_params.screen_info` for an 80x25 colour VGA text console, so
/// `console=tty0` works. `cursor_row`/`cursor_col` are where the loader left
/// the cursor.
pub fn setVgaText(page: *[boot_params_size]u8, cursor_row: u8, cursor_col: u8) void {
    page[0x00] = cursor_col; // orig_x
    page[0x01] = cursor_row; // orig_y
    page[0x06] = 3; // orig_video_mode
    page[0x07] = 80; // orig_video_cols
    page[0x0E] = 25; // orig_video_lines
    page[0x0F] = 1; // orig_video_isVGA
    page[0x10] = 16; // orig_video_points
}

/// Chooses where to put the initramfs: as high as `initrd_addr_max` and the
/// usable RAM allow, page aligned, and not below `floor` (the end of the
/// area the kernel will occupy). Returns null if it doesn't fit.
pub fn placeInitrd(e820: []const E820Entry, addr_max: u32, size: u64, floor: u64) ?u64 {
    var best: ?u64 = null;
    for (e820) |e| {
        if (e.kind != E820Entry.usable) continue;
        var end = e.addr + e.size;
        end = @min(end, @as(u64, addr_max) + 1);
        if (end <= e.addr or end < size) continue;
        const start = (end - size) & ~@as(u64, 0xFFF);
        if (start < e.addr or start < floor) continue;
        if (best == null or start > best.?) best = start;
    }
    return best;
}

test "header layout matches boot.rst offsets" {
    try std.testing.expectEqual(@as(usize, 0x214 - header_offset), @offsetOf(SetupHeader, "code32_start"));
    try std.testing.expectEqual(@as(usize, 0x22C - header_offset), @offsetOf(SetupHeader, "initrd_addr_max"));
}

test "initrd goes as high as allowed, page aligned, in usable RAM" {
    const map = [_]E820Entry{
        .{ .addr = 0, .size = 0x9F000, .kind = 1 },
        .{ .addr = 0x100000, .size = 0x7EF00000, .kind = 1 }, // up to ~2 GiB
        .{ .addr = 0xFEC00000, .size = 0x1000, .kind = 2 },
    };
    // initrd_addr_max = 0x7FFFFFFF: end of RAM wins.
    const p = placeInitrd(&map, 0x7FFFFFFF, 5 * 1024 * 1024 + 7, 0x2000000).?;
    try std.testing.expectEqual(@as(u64, 0), p & 0xFFF);
    try std.testing.expect(p + 5 * 1024 * 1024 + 7 <= 0x7F000000);
    try std.testing.expect(p + 5 * 1024 * 1024 + 7 > 0x7F000000 - 0x2000);
    // A low addr_max caps it.
    const q = placeInitrd(&map, 0x0FFFFFFF, 1 << 20, 0x2000000).?;
    try std.testing.expect(q + (1 << 20) <= 0x10000000);
    // Doesn't fit above the floor.
    try std.testing.expect(placeInitrd(&map, 0x7FFFFFFF, 1 << 20, 0x7EF80000) == null);
}

test "parseKernel rejects non-kernels and old protocols" {
    var buf = std.mem.zeroes([0x300]u8);
    try std.testing.expectError(error.NotLinux, parseKernel(&buf, 0x10000));
    std.mem.writeInt(u32, buf[0x202..][0..4], 0x53726448, .little);
    std.mem.writeInt(u16, buf[0x1FE..][0..2], 0xAA55, .little);
    std.mem.writeInt(u16, buf[0x206..][0..2], 0x0209, .little);
    buf[0x211] = 1;
    try std.testing.expectError(error.TooOld, parseKernel(&buf, 0x10000));
    std.mem.writeInt(u16, buf[0x206..][0..2], 0x020F, .little);
    buf[0x1F1] = 0; // means 4 setup sectors
    const k = try parseKernel(&buf, 0x10000);
    try std.testing.expectEqual(@as(u32, 5 * 512), k.setup_size);
    try std.testing.expectEqual(@as(u32, 0x10000 - 5 * 512), k.pm_size);
}

test "boot_params gets the e820 map and loader id" {
    var buf = std.mem.zeroes([0x300]u8);
    std.mem.writeInt(u32, buf[0x202..][0..4], 0x53726448, .little);
    std.mem.writeInt(u16, buf[0x1FE..][0..2], 0xAA55, .little);
    std.mem.writeInt(u16, buf[0x206..][0..2], 0x020F, .little);
    buf[0x211] = 1;
    const k = try parseKernel(&buf, 0x10000);
    var page: [boot_params_size]u8 = undefined;
    const map = [_]E820Entry{.{ .addr = 0x100000, .size = 0x1000000, .kind = 1 }};
    const hdr = initBootParams(&page, k, &map);
    try std.testing.expectEqual(@as(u8, 0xFF), hdr.type_of_loader);
    try std.testing.expectEqual(@as(u8, 1), page[0x1E8]);
    try std.testing.expectEqual(@as(u64, 0x100000), std.mem.readInt(u64, page[0x2D0..][0..8], .little));
    try std.testing.expectEqual(@as(u32, 0x53726448), std.mem.readInt(u32, page[0x202..][0..4], .little));
}
