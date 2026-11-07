//! UEFI loader. Finds `dklilo.conf` on the boot disk with dklilo's own
//! filesystem code (through `BlockIo`), shows the menu, then starts the
//! chosen Linux kernel as an EFI application (its EFI stub). The initramfs is
//! handed over through a `LoadFile2` protocol on the well-known
//! `LINUX_EFI_INITRD_MEDIA_GUID` device path, which kernels since 5.8 use.

const std = @import("std");
const uefi = std.os.uefi;
const common = @import("common");
const Console = common.console.Console;
const Key = common.console.Key;

const BlockIo = uefi.protocol.BlockIo;
const DevicePath = uefi.protocol.DevicePath;
const LoadedImage = uefi.protocol.LoadedImage;
const Status = uefi.Status;
const Guid = uefi.Guid;
const cc = uefi.cc;

const allocator = uefi.pool_allocator;

// ---- console ---------------------------------------------------------------

const UefiConsole = struct {
    const vt = Console.VTable{
        .clear = clear,
        .moveTo = moveTo,
        .setHighlight = setHighlight,
        .puts = puts,
        .getKey = getKey,
        .size = size,
    };
    var dummy: u8 = 0;

    fn console() Console {
        return .{ .ctx = &dummy, .vtable = &vt };
    }

    fn out() *uefi.protocol.SimpleTextOutput {
        return uefi.system_table.con_out.?;
    }

    fn clear(_: *anyopaque) void {
        out().clearScreen() catch {};
        out().enableCursor(true) catch {};
    }
    fn moveTo(_: *anyopaque, row: u16, col: u16) void {
        out().setCursorPosition(col, row) catch {};
    }
    fn setHighlight(_: *anyopaque, on: bool) void {
        const attr: uefi.protocol.SimpleTextOutput.Attribute = if (on)
            .{ .foreground = .black, .background = .lightgray }
        else
            .{};
        out().setAttribute(attr) catch {};
    }
    fn puts(_: *anyopaque, s: []const u8) void {
        var buf: [129]u16 = undefined;
        var i: usize = 0;
        while (i < s.len) {
            const n = @min(s.len - i, 128);
            for (s[i..][0..n], 0..) |c, j| buf[j] = c;
            buf[n] = 0;
            _ = out().outputString(@ptrCast(&buf)) catch {};
            i += n;
        }
    }
    fn size(_: *anyopaque) common.console.Size {
        const mode = out().mode.mode;
        const g = out().queryMode(@intCast(mode)) catch return .{ .rows = 25, .cols = 80 };
        return .{ .rows = @intCast(g.rows), .cols = @intCast(g.columns) };
    }
    fn getKey(_: *anyopaque, timeout_ms: ?u32) Key {
        const cin = uefi.system_table.con_in.?;
        const bs = uefi.system_table.boot_services.?;
        var waited: u32 = 0;
        while (true) {
            if (cin.readKeyStroke()) |k| {
                switch (k.scan_code) {
                    0x01 => return .up,
                    0x02 => return .down,
                    0x03 => return .right,
                    0x04 => return .left,
                    0x05 => return .home,
                    0x06 => return .end,
                    0x08 => return .delete,
                    0x17 => return .esc,
                    else => switch (k.unicode_char) {
                        0x0D => return .enter,
                        0x08 => return .backspace,
                        0x09 => return .tab,
                        0x20...0x7E => return .{ .char = @intCast(k.unicode_char) },
                        else => {},
                    },
                }
            } else |_| {}
            if (timeout_ms) |t| if (waited >= t) return .timeout;
            bs.stall(10_000) catch {};
            waited += 10;
        }
    }
};

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    UefiConsole.puts(&UefiConsole.dummy, s);
}

// ---- block devices ---------------------------------------------------------

/// A disk read through the firmware's BlockIo. Reads go through an aligned
/// bounce buffer when the caller's buffer doesn't satisfy `io_align`.
const UefiDisk = struct {
    bio: *BlockIo,
    bounce: []align(4096) u8,

    const bounce_size = 256 * 1024;

    fn blockDev(self: *UefiDisk) common.blockdev.BlockDev {
        return .{
            .ctx = self,
            .readSectorsFn = read,
            .sector_size = self.bio.media.block_size,
            .sector_count = self.bio.media.last_block + 1,
        };
    }

    fn read(ctx: *anyopaque, lba: u64, buf: []u8) common.blockdev.Error!void {
        const self: *UefiDisk = @ptrCast(@alignCast(ctx));
        const media = self.bio.media;
        const align_req: usize = @max(media.io_align, 1);
        if (@intFromPtr(buf.ptr) % align_req == 0) {
            self.bio.readBlocks(media.media_id, lba, buf) catch return error.IoError;
            return;
        }
        var done: usize = 0;
        while (done < buf.len) {
            const n = @min(buf.len - done, bounce_size);
            self.bio.readBlocks(media.media_id, lba + done / media.block_size, self.bounce[0..n]) catch
                return error.IoError;
            @memcpy(buf[done..][0..n], self.bounce[0..n]);
            done += n;
        }
    }
};

/// Bytes of a device path without its terminating end node.
fn pathPrefix(p: *const DevicePath) []const u8 {
    const total = p.size();
    const bytes: [*]const u8 = @ptrCast(p);
    return bytes[0..total -| 4];
}

// ---- device tree ------------------------------------------------------------

const device_tree_guid align(8) = Guid{
    .time_low = 0xb1b621d5,
    .time_mid = 0xf19c,
    .time_high_and_version = 0x41a5,
    .clock_seq_high_and_reserved = 0x83,
    .clock_seq_low = 0x0b,
    .node = .{ 0xd9, 0x15, 0x2c, 0x69, 0xaa, 0xe0 },
};

/// Moves the firmware's device tree (the `EFI_DTB_TABLE_GUID` configuration
/// table, present on ARM and RISC-V machines) into memory we allocate, and
/// publishes the copy. On edk2's RISC-V "virt" platform the tree sits inside
/// the range the firmware's own stack grows through, and dklilo's deeper call
/// chains overwrite it, so the kernel's EFI stub then rejects it ("Invalid
/// header detected on UEFI supplied FDT") and cannot boot. The copy is made
/// first thing, before the stack is used deeply. Harmless where the tree is
/// not at risk, and a no-op where there is none (x86).
fn protectDeviceTree(bs: *uefi.tables.BootServices) void {
    const st = uefi.system_table;
    var i: usize = 0;
    while (i < st.number_of_table_entries) : (i += 1) {
        const t = st.configuration_table[i];
        if (!std.meta.eql(t.vendor_guid, device_tree_guid)) continue;
        const src: [*]const u8 = @ptrCast(t.vendor_table);
        // flattened device tree header: magic 0xd00dfeed, then totalsize (both big-endian)
        if (std.mem.readInt(u32, src[0..4], .big) != 0xd00dfeed) return;
        const size = std.mem.readInt(u32, src[4..8], .big);
        if (size < 40 or size > 4 << 20) return;
        const pages = bs.allocatePages(.any, .boot_services_data, (size + 4095) / 4096) catch return;
        const dst: [*]u8 = @ptrCast(pages.ptr);
        @memcpy(dst[0..size], src[0..size]);
        bs.installConfigurationTable(&device_tree_guid, @ptrCast(dst)) catch {};
        return;
    }
}

// ---- initrd via LoadFile2 --------------------------------------------------

const LoadFile2 = extern struct {
    load_file: *const fn (*LoadFile2, ?*const anyopaque, bool, *usize, ?*anyopaque) callconv(cc) Status,

    pub const guid align(8) = Guid{
        .time_low = 0x4006c0c1,
        .time_mid = 0xfcb3,
        .time_high_and_version = 0x403e,
        .clock_seq_high_and_reserved = 0x99,
        .clock_seq_low = 0x6d,
        .node = .{ 0x4a, 0x6c, 0x87, 0x24, 0xe0, 0x6d },
    };
};

/// Vendor-media device path ending in the LINUX_EFI_INITRD_MEDIA_GUID
/// (5568e427-68fc-4f3d-ac74-ca555231cc68), followed by an end node.
const InitrdPath = extern struct {
    node_type: u8 = 0x04, // media
    node_subtype: u8 = 0x03, // vendor
    node_len: [2]u8 = .{ 20, 0 },
    vendor: [16]u8 = .{ 0x27, 0xe4, 0x68, 0x55, 0xfc, 0x68, 0x3d, 0x4f, 0xac, 0x74, 0xca, 0x55, 0x52, 0x31, 0xcc, 0x68 },
    end_type: u8 = 0x7F,
    end_subtype: u8 = 0xFF,
    end_len: [2]u8 = .{ 4, 0 },

    pub const guid align(8) = DevicePath.guid;
};

var initrd_data: []const u8 = &.{};

fn loadInitrd(_: *LoadFile2, _: ?*const anyopaque, boot_policy: bool, size: *usize, buffer: ?*anyopaque) callconv(cc) Status {
    if (boot_policy) return .unsupported;
    if (buffer == null or size.* < initrd_data.len) {
        size.* = initrd_data.len;
        return .buffer_too_small;
    }
    const dst: [*]u8 = @ptrCast(buffer.?);
    @memcpy(dst[0..initrd_data.len], initrd_data);
    size.* = initrd_data.len;
    return .success;
}

var lf2 = LoadFile2{ .load_file = loadInitrd };
var initrd_path = InitrdPath{};

// ---- booting ---------------------------------------------------------------

const BootError = error{ NotFound, ReadFailed, LoadFailed, StartFailed, OutOfMemory };

/// Reads `spec` (a path, maybe with a LABEL=/UUID=/PARTUUID= prefix).
fn readSpec(set: *common.volumes.Set, default: *common.volumes.Volume, spec: []const u8, subvol: ?[]const u8) BootError![]u8 {
    return set.readSpec(default, spec, subvol) catch |e| {
        say("\r\n{s}: {s}", .{ spec, @errorName(e) });
        return if (e == error.NotFound) error.NotFound else error.ReadFailed;
    };
}

fn bootLinux(
    set: *common.volumes.Set,
    default_in: *common.volumes.Volume,
    kernel_spec: []const u8,
    initrd_specs: []const []const u8,
    subvol_in: ?[]const u8,
    iso: ?[]const u8,
    cmdline: []const u8,
) BootError!void {
    const bs = uefi.system_table.boot_services.?;
    // A loopback ISO entry reads the kernel and initramfs from inside the ISO.
    var default = default_in;
    var subvol = subvol_in;
    if (iso) |spec| {
        default = set.isoVolume(default_in, spec, subvol_in) catch |e| {
            say("\r\n{s}: {s}", .{ spec, @errorName(e) });
            return error.NotFound;
        };
        subvol = null;
    }

    say("\r\nLoading {s}...", .{kernel_spec});
    const kernel = try readSpec(set, default, kernel_spec, subvol);
    defer allocator.free(kernel);

    // Concatenate the initramfs files, each padded to 4 bytes so the kernel's
    // cpio unpacker finds the next archive on a boundary.
    var total: usize = 0;
    var parts: std.ArrayList([]u8) = .empty;
    defer {
        for (parts.items) |p| allocator.free(p);
        parts.deinit(allocator);
    }
    for (initrd_specs) |spec| {
        const data = try readSpec(set, default, spec, subvol);
        try parts.append(allocator, data);
        total += std.mem.alignForward(usize, data.len, 4);
    }
    if (total > 0) {
        const joined = try allocator.alloc(u8, total);
        var off: usize = 0;
        for (parts.items) |p| {
            @memcpy(joined[off..][0..p.len], p);
            const padded = std.mem.alignForward(usize, p.len, 4);
            @memset(joined[off + p.len ..][0 .. padded - p.len], 0);
            off += padded;
        }
        initrd_data = joined;
    }

    // UTF-16 command line for LoadedImage.load_options.
    const opts = try allocator.alloc(u16, cmdline.len + 1);
    for (cmdline, 0..) |c, i| opts[i] = c;
    opts[cmdline.len] = 0;

    const handle = bs.loadImage(false, uefi.handle, .{ .buffer = kernel }) catch |e| {
        say("\r\nLoadImage failed: {s}", .{@errorName(e)});
        return error.LoadFailed;
    };
    const li = (bs.handleProtocol(LoadedImage, handle) catch null) orelse return error.LoadFailed;
    li.load_options = opts.ptr;
    li.load_options_size = @intCast(opts.len * 2);

    if (total > 0) {
        _ = bs.installProtocolInterfaces(null, .{ &initrd_path, &lf2 }) catch |e| {
            say("\r\ninitrd protocol install failed: {s}", .{@errorName(e)});
            return error.LoadFailed;
        };
    }

    say("\r\nStarting kernel...\r\n", .{});
    _ = bs.startImage(handle) catch |e| {
        say("\r\nStartImage failed: {s}", .{@errorName(e)});
        return error.StartFailed;
    };
}

const SimpleFileSystem = uefi.protocol.SimpleFileSystem;

/// Starts an EFI application stored on a FAT volume the firmware can read
/// (normally the ESP). `windows` means Windows Boot Manager; anything else is
/// taken as the path of an EFI file (`/` or `\\` separated). The image is
/// loaded through its device path, not from memory, because boot managers
/// find their own volume from it.
fn chainEfi(target: []const u8) void {
    const bs = uefi.system_table.boot_services.?;
    const path8 = if (std.mem.eql(u8, target, "windows")) "\\EFI\\Microsoft\\Boot\\bootmgfw.efi" else target;

    var path16: [256:0]u16 = undefined;
    if (path8.len + 1 > path16.len) return;
    var n: usize = 0;
    if (path8.len == 0 or (path8[0] != '/' and path8[0] != '\\')) {
        path16[0] = '\\';
        n = 1;
    }
    for (path8) |c| {
        path16[n] = if (c == '/') '\\' else c;
        n += 1;
    }
    path16[n] = 0;

    const handles = (bs.locateHandleBuffer(.{ .by_protocol = &SimpleFileSystem.guid }) catch null) orelse {
        say("\r\nNo FAT volumes found.", .{});
        return;
    };
    for (handles) |h| {
        const sfs = (bs.handleProtocol(SimpleFileSystem, h) catch null) orelse continue;
        const root = sfs.openVolume() catch continue;
        const f = root.open(&path16, .read, .{}) catch {
            root.close() catch {};
            continue;
        };
        f.close() catch {};
        root.close() catch {};

        const dp = (bs.handleProtocol(DevicePath, h) catch null) orelse continue;
        const full = dp.createFileDevicePath(allocator, path16[0..n]) catch continue;
        say("\r\nStarting {s}...\r\n", .{path8});
        const img = bs.loadImage(false, uefi.handle, .{ .device_path = full }) catch |e| {
            say("\r\nLoadImage failed: {s}", .{@errorName(e)});
            return;
        };
        _ = bs.startImage(img) catch |e| {
            say("\r\nStartImage failed: {s}", .{@errorName(e)});
        };
        return;
    }
    say("\r\n{s} not found on any FAT volume.", .{path8});
}

pub fn main() void {
    const bs = uefi.system_table.boot_services.?;
    protectDeviceTree(bs);
    bs.setWatchdogTimer(0, 0, null) catch {};
    const con = UefiConsole.console();

    var set = common.volumes.Set.init(allocator);
    var boot_disk: ?usize = null;

    // Which disk are we on? Our own partition's device path starts with the
    // disk's device path.
    var self_path: ?[]const u8 = null;
    if (bs.handleProtocol(LoadedImage, uefi.handle) catch null) |me| {
        if (me.device_handle) |dh| {
            if (bs.handleProtocol(DevicePath, dh) catch null) |p| self_path = pathPrefix(p);
        }
    }

    const handles = (bs.locateHandleBuffer(.{ .by_protocol = &BlockIo.guid }) catch null) orelse &[_]uefi.Handle{};
    for (handles) |h| {
        const bio = (bs.handleProtocol(BlockIo, h) catch null) orelse continue;
        if (!bio.media.media_present or bio.media.logical_partition) continue;
        const bounce = bs.allocatePages(.any, .boot_services_data, UefiDisk.bounce_size / 4096) catch continue;
        const disk = allocator.create(UefiDisk) catch continue;
        disk.* = .{ .bio = bio, .bounce = @ptrCast(bounce) };
        const idx = set.addDisk(disk.blockDev()) catch continue;
        if (self_path) |sp| if (bs.handleProtocol(DevicePath, h) catch null) |dp| {
            if (std.mem.startsWith(u8, sp, pathPrefix(dp))) boot_disk = idx;
        };
    }

    // Config: the boot disk first, then any disk.
    var found = set.findConfig(boot_disk);
    if (found == null and boot_disk != null) found = set.findConfig(null);

    if (found) |f| {
        const text = set.readFile(f.vol, f.path) catch {
            return manual(&set, con);
        };
        var diag = common.config.Diagnostic{};
        var cfg = common.config.parse(allocator, text, &diag) catch |e| {
            say("dklilo.conf line {d}: {s}\r\n", .{ diag.line, @errorName(e) });
            _ = con.getKey(3000);
            return manual(&set, con);
        };
        while (true) {
            var cmd: [1024]u8 = undefined;
            const choice = common.menu.run(con, &cfg, &cmd) orelse return manual(&set, con);
            const entry = cfg.entries[choice.index];
            switch (entry.kind) {
                .linux => {
                    bootLinux(&set, f.vol, entry.target, entry.initrds, entry.subvol, entry.iso, choice.cmdline) catch {};
                    say("\r\nBoot failed. Press a key.", .{});
                    _ = con.getKey(null);
                },
                .chain => {
                    chainEfi(entry.target);
                    say("\r\nReturned to dklilo. Press a key.", .{});
                    _ = con.getKey(null);
                },
            }
        }
    }
    manual(&set, con);
}

/// No usable configuration: let the user type a kernel path and command line.
fn manual(set: *common.volumes.Set, con: Console) void {
    var default: ?*common.volumes.Volume = null;
    for (set.vols.items) |*v| if (v.filesystem(allocator) != null) {
        default = v;
        break;
    };
    const vol = default orelse {
        say("dklilo: no readable filesystem found.\r\n", .{});
        _ = con.getKey(null);
        return;
    };
    while (true) {
        var pbuf: [256]u8 = undefined;
        var cbuf: [1024]u8 = undefined;
        const r = common.menu.manualPrompt(con, &pbuf, &cbuf) orelse return;
        bootLinux(set, vol, r.path, &.{}, null, null, r.cmdline) catch {};
        say("\r\nBoot failed. Press a key.", .{});
        _ = con.getKey(null);
    }
}
