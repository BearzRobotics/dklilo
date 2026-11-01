//! Stage 2 (BIOS loader). Stage 1 loads this flat binary to 0x8000 and jumps to
//! its first byte; `realmode.zig` switches to 32-bit protected mode and calls
//! `stage2_main`. Disk, keyboard and screen go through BIOS calls made via the
//! real-mode trampoline; everything else is the same code the UEFI loader runs.
//!
//! The kernel and initramfs are read from the filesystem straight to their
//! final addresses, so nothing here buffers a whole file.

const std = @import("std");
const common = @import("common");
const rm = @import("realmode.zig");
const con = @import("console.zig");
const bdisk = @import("disk.zig");
const bp = common.bootparams;

comptime {
    _ = rm; // pulls in the entry point and trampoline assembly
}

// Memory layout above 1 MiB (see realmode.zig for the low-memory map):
//   0x0100000  kernel (protected-mode part)
//   0x1E00000  stack (grows down from 0x1F00000)
//   0x2000000  heap, 8 MiB
const kernel_addr: u32 = 0x100000;
const heap_addr: usize = 0x2000000;
const heap_size: usize = 8 * 1024 * 1024;
const initrd_floor: u64 = heap_addr + heap_size;

extern const __bss_start: u8;
extern const __bss_end: u8;

fn clearBss() void {
    const start: [*]u8 = @ptrCast(@constCast(&__bss_start));
    const len = @intFromPtr(&__bss_end) - @intFromPtr(&__bss_start);
    @memset(start[0..len], 0);
}

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [200]u8 = undefined;
    con.puts(std.fmt.bufPrint(&buf, fmt, args) catch return);
}

// ---- memory map --------------------------------------------------------------

var e820_buf: [bp.max_e820]bp.E820Entry = undefined;

/// The firmware memory map from `int 15h, ax=E820h`.
fn readE820() []const bp.E820Entry {
    const buf: [*]u8 = @ptrFromInt(rm.scratch_addr + 0x40);
    var n: usize = 0;
    var cont: u32 = 0;
    while (n < e820_buf.len) {
        const r = rm.int(0x15, .{
            .eax = 0xE820,
            .ebx = cont,
            .ecx = 24,
            .edx = 0x534D4150, // "SMAP"
            .edi = rm.scratch_addr + 0x40,
        });
        if (r.carry() or r.eax != 0x534D4150) break;
        const len = std.mem.readInt(u64, buf[8..16], .little);
        if (len != 0) {
            e820_buf[n] = .{
                .addr = std.mem.readInt(u64, buf[0..8], .little),
                .size = len,
                .kind = std.mem.readInt(u32, buf[16..20], .little),
            };
            n += 1;
        }
        cont = r.ebx;
        if (cont == 0) break;
    }
    return e820_buf[0..n];
}

// ---- booting Linux -------------------------------------------------------------

const BootError = error{ NotFound, ReadFailed, BadKernel, NoMemory };

fn open(set: *common.volumes.Set, default: *common.volumes.Volume, spec: []const u8, subvol: ?[]const u8) BootError!common.volumes.Set.Opened {
    return set.openFile(default, spec, subvol) catch |e| {
        say("\r\n{s}: {s}", .{ spec, @errorName(e) });
        return error.NotFound;
    };
}

fn readInto(fs: *common.fs.Fs, file: *const common.fs.File, offset: u64, dest: u64, len: u64) BootError!void {
    const p: [*]u8 = @ptrFromInt(@as(usize, @intCast(dest)));
    const n = fs.readAt(file, offset, p[0..@intCast(len)]) catch |e| {
        say("\r\nread error: {s}", .{@errorName(e)});
        return error.ReadFailed;
    };
    if (n != len) {
        say("\r\nshort read: {d} of {d}", .{ n, len });
        return error.ReadFailed;
    }
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
    var k = try open(set, default, kernel_spec, subvol);
    var head: [4096]u8 = undefined;
    const head_len = k.fs.readAt(&k.file, 0, &head) catch |e| {
        say("\r\nread {s}: {s}", .{ kernel_spec, @errorName(e) });
        return error.ReadFailed;
    };
    const kernel = bp.parseKernel(head[0..head_len], k.file.size) catch |e| {
        say("\r\nnot a bootable kernel: {s}", .{@errorName(e)});
        return error.BadKernel;
    };

    const e820 = readE820();

    // Where the initramfs goes: size first, then as high as allowed.
    var total: u64 = 0;
    var initrds: [8]@TypeOf(k) = undefined;
    if (initrd_specs.len > initrds.len) return error.NotFound;
    for (initrd_specs, 0..) |spec, i| {
        initrds[i] = try open(set, default, spec, subvol);
        total += std.mem.alignForward(u64, initrds[i].file.size, 4);
    }
    const kernel_end: u64 = kernel_addr + @max(@as(u64, kernel.pm_size), kernel.header.init_size);
    var initrd_at: u64 = 0;
    if (total > 0) {
        initrd_at = bp.placeInitrd(e820, kernel.header.initrd_addr_max, total, @max(kernel_end, initrd_floor)) orelse {
            say("\r\nnot enough memory for the initramfs", .{});
            return error.NoMemory;
        };
    }

    try readInto(k.fs, &k.file, kernel.setup_size, kernel_addr, kernel.pm_size);
    say("\r\nLoading initramfs...", .{});
    var off: u64 = 0;
    for (initrd_specs, 0..) |_, i| {
        var f = initrds[i];
        try readInto(f.fs, &f.file, 0, initrd_at + off, f.file.size);
        const padded = std.mem.alignForward(u64, f.file.size, 4);
        const pad: [*]u8 = @ptrFromInt(@as(usize, @intCast(initrd_at + off + f.file.size)));
        @memset(pad[0..@intCast(padded - f.file.size)], 0);
        off += padded;
    }

    // Command line and the zero page.
    const cmd: [*]u8 = @ptrFromInt(rm.cmdline_addr);
    const max_cmd = @min(@as(usize, if (kernel.header.cmdline_size == 0) 255 else kernel.header.cmdline_size), 2048) - 1;
    const cn = @min(cmdline.len, max_cmd);
    @memcpy(cmd[0..cn], cmdline[0..cn]);
    cmd[cn] = 0;

    const page: *[bp.boot_params_size]u8 = @ptrFromInt(rm.boot_params_addr);
    const hdr = bp.initBootParams(page, kernel, e820);
    hdr.cmd_line_ptr = rm.cmdline_addr;
    hdr.ramdisk_image = @intCast(initrd_at);
    hdr.ramdisk_size = @intCast(total);
    const cur = con.cursor();
    bp.setVgaText(page, cur.row, cur.col);

    say("\r\nStarting kernel...\r\n", .{});
    rm.startKernel(hdr.code32_start, rm.boot_params_addr);
}

// ---- chainloading ----------------------------------------------------------

/// Loads another operating system's boot sector and jumps to it. `target` is
/// `windows` (find the NTFS boot partition) or a partition number / device
/// name ending in one (`2`, `/dev/sda2`) on the boot disk.
fn chainload(set: *common.volumes.Set, target: []const u8) void {
    const vol = if (std.mem.eql(u8, target, "windows"))
        set.findWindowsBoot(0)
    else blk: {
        var end = target.len;
        while (end > 0 and std.ascii.isDigit(target[end - 1])) end -= 1;
        const n = std.fmt.parseInt(u8, target[end..], 10) catch break :blk null;
        break :blk set.findPartition(0, n);
    };
    const v = vol orelse {
        say("\r\nNo boot partition found for '{s}'.", .{target});
        return;
    };
    const sector: *[512]u8 = @ptrFromInt(rm.boot_sector_addr);
    v.region.readAt(0, sector) catch {
        say("\r\nCannot read the boot sector.", .{});
        return;
    };
    // A copy of the MBR partition entry for ds:si, as the MBR would leave it.
    const entry: *[16]u8 = @ptrFromInt(rm.part_entry_addr);
    entry.* = @splat(0);
    entry[0] = if (v.bootable) 0x80 else 0;
    entry[1] = 0xFE; // CHS fields: out of range, LBA fields are authoritative
    entry[2] = 0xFF;
    entry[3] = 0xFF;
    entry[4] = v.mbr_type;
    entry[5] = 0xFE;
    entry[6] = 0xFF;
    entry[7] = 0xFF;
    const lba: u32 = @intCast(v.region.start / v.region.dev.sector_size);
    std.mem.writeInt(u32, entry[8..12], lba, .little);
    std.mem.writeInt(u32, entry[12..16], @intCast(v.region.len / v.region.dev.sector_size), .little);
    con.clear();
    rm.chainBootSector(rm.driveNumber());
}

// ---- main ----------------------------------------------------------------------

fn manual(set: *common.volumes.Set, c: common.console.Console) void {
    var default: ?*common.volumes.Volume = null;
    for (set.vols.items) |*v| if (v.filesystem(set.allocator) != null) {
        default = v;
        break;
    };
    const vol = default orelse {
        say("dklilo: no readable filesystem found.\r\n", .{});
        _ = c.getKey(null);
        return;
    };
    while (true) {
        var pbuf: [256]u8 = undefined;
        var cbuf: [1024]u8 = undefined;
        const r = common.menu.manualPrompt(c, &pbuf, &cbuf) orelse return;
        bootLinux(set, vol, r.path, &.{}, null, null, r.cmdline) catch {};
        say("\r\nBoot failed. Press a key.", .{});
        _ = c.getKey(null);
    }
}

export fn stage2_main() callconv(.c) noreturn {
    clearBss();
    con.init();
    const c = con.console();

    var fba = std.heap.FixedBufferAllocator.init(@as([*]u8, @ptrFromInt(heap_addr))[0..heap_size]);
    const allocator = fba.allocator();

    con.clear();
    say("dklilo stage2 (32-bit)\r\n", .{});

    var set = common.volumes.Set.init(allocator);
    var disk = bdisk.Disk.open(rm.driveNumber()) orelse {
        say("dklilo: BIOS disk extensions unavailable\r\n", .{});
        halt();
    };
    _ = set.addDisk(disk.blockDev()) catch halt();

    if (set.findConfig(null)) |f| {
        if (set.readFile(f.vol, f.path)) |text| {
            var diag = common.config.Diagnostic{};
            if (common.config.parse(allocator, text, &diag)) |parsed| {
                var cfg = parsed;
                while (true) {
                    var cmd: [1024]u8 = undefined;
                    const choice = common.menu.run(c, &cfg, &cmd) orelse break;
                    const entry = cfg.entries[choice.index];
                    switch (entry.kind) {
                        .linux => {
                            bootLinux(&set, f.vol, entry.target, entry.initrds, entry.subvol, entry.iso, choice.cmdline) catch {};
                            say("\r\nBoot failed. Press a key.", .{});
                            _ = c.getKey(null);
                        },
                        .chain => {
                            chainload(&set, entry.target);
                            _ = c.getKey(null);
                        },
                    }
                }
            } else |e| {
                say("dklilo.conf line {d}: {s}\r\n", .{ diag.line, @errorName(e) });
                _ = c.getKey(3000);
            }
        } else |_| {}
    }
    manual(&set, c);
    halt();
}

fn halt() noreturn {
    while (true) asm volatile ("hlt");
}
