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
// `stage2_early` checks that the stack and heap are RAM, and `bootLinux` that
// the kernel stays below the stack and fits in RAM.
const kernel_addr: u32 = 0x100000;
/// The most of a command line handed to a kernel.
const max_cmdline_area = 2048;
const stack_floor: u32 = 0x1E00000;
const stack_top: u32 = 0x1F00000;
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
    var w = std.Io.Writer.fixed(&buf);
    w.print(fmt, args) catch {}; // a long message is cut short, not dropped
    con.puts(w.buffered());
}

// ---- memory map --------------------------------------------------------------

var e820_buf: [bp.max_e820]bp.E820Entry = undefined;

/// The firmware memory map: from `int 15h, ax=E820h`, or for a BIOS without
/// it, one made up from the older memory size calls.
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
    if (n == 0) return oldMemoryMap();
    return e820_buf[0..n];
}

/// Conventional memory in KiB, from `int 12h`.
fn lowMemoryKib() u32 {
    return rm.int(0x12, .{}).eax & 0xFFFF;
}

/// A map from `int 15h, ax=E801h` (or `ah=88h`) and `int 12h`, as the kernel's
/// own setup code makes one. Empty if the BIOS answers neither.
fn oldMemoryMap() []const bp.E820Entry {
    var above_1m_kib: u32 = 0;
    var above_16m_blocks: u32 = 0; // of 64 KiB
    const r = rm.int(0x15, .{ .eax = 0xE801 });
    if (!r.carry()) {
        above_1m_kib = r.eax & 0xFFFF;
        above_16m_blocks = r.ebx & 0xFFFF;
        if (above_1m_kib == 0) { // some answer in cx and dx instead
            above_1m_kib = r.ecx & 0xFFFF;
            above_16m_blocks = r.edx & 0xFFFF;
        }
    }
    if (above_1m_kib == 0) {
        const old = rm.int(0x15, .{ .eax = 0x8800 });
        if (!old.carry()) above_1m_kib = old.eax & 0xFFFF;
    }
    if (above_1m_kib == 0) return e820_buf[0..0];
    var n: usize = 0;
    const ranges = [_][2]u64{
        .{ 0, @as(u64, lowMemoryKib()) * 1024 },
        .{ 0x100000, @as(u64, above_1m_kib) * 1024 },
        .{ 0x1000000, @as(u64, above_16m_blocks) * 65536 },
    };
    for (ranges) |range| {
        if (range[1] == 0) continue;
        e820_buf[n] = .{ .addr = range[0], .size = range[1], .kind = bp.E820Entry.usable };
        n += 1;
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

    // Loading a bigger kernel would overwrite this loader as it runs.
    const max_pm_size = stack_floor - kernel_addr;
    if (kernel.pm_size > max_pm_size) {
        say("\r\nkernel too large: {d} bytes (the limit is {d})", .{ kernel.pm_size, max_pm_size });
        return error.BadKernel;
    }
    const e820 = readE820();

    // Where the initramfs goes: size first, then as high as allowed.
    var total: u64 = 0;
    const initrds = set.allocator.alloc(@TypeOf(k), initrd_specs.len) catch {
        say("\r\nnot enough memory for {d} initramfs files", .{initrd_specs.len});
        return error.NoMemory;
    };
    defer set.allocator.free(initrds);
    for (initrd_specs, 0..) |spec, i| {
        initrds[i] = try open(set, default, spec, subvol);
        // Under 4 GiB each, so the sum of eight can't overflow.
        if (initrds[i].file.size > std.math.maxInt(u32)) {
            say("\r\nnot enough memory for the initramfs", .{});
            return error.NoMemory;
        }
        total += std.mem.alignForward(u64, initrds[i].file.size, 4);
    }
    // The kernel moves itself to where it will run and needs init_size bytes
    // there to decompress, so keep the initramfs above that.
    const run_at = bp.runAddress(kernel.header, kernel_addr);
    const run_end = run_at +| kernel.header.init_size;
    const load_end = kernel_addr + @as(u64, kernel.pm_size);
    const kernel_end: u64 = @max(load_end, run_end);
    // Without a memory map (a very old BIOS) there is nothing to check against.
    if (e820.len > 0 and !(bp.rangeUsable(e820, kernel_addr, load_end) and
        bp.rangeUsable(e820, run_at, run_end)))
    {
        say("\r\nnot enough memory for the kernel", .{});
        return error.NoMemory;
    }
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
    // With nothing to load there is no address to load it to.
    for (initrds[0..if (total > 0) initrds.len else 0]) |opened| {
        var f = opened;
        try readInto(f.fs, &f.file, 0, initrd_at + off, f.file.size);
        const padded = std.mem.alignForward(u64, f.file.size, 4);
        const pad: [*]u8 = @ptrFromInt(@as(usize, @intCast(initrd_at + off + f.file.size)));
        @memset(pad[0..@intCast(padded - f.file.size)], 0);
        off += padded;
    }

    // Command line and the zero page.
    const cmd: [*]u8 = @ptrFromInt(rm.cmdline_addr);
    const max_cmd = @min(@as(usize, if (kernel.header.cmdline_size == 0) 255 else kernel.header.cmdline_size), max_cmdline_area) - 1;
    const cn = @min(cmdline.len, max_cmd);
    if (cn < cmdline.len) say("\r\nwarning: command line cut to {d} bytes, all this kernel takes", .{cn});
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
/// `windows` (find the NTFS boot partition) or a partition of the boot disk: a
/// number (`2`), or a device name ending in one (`/dev/sda2`).
fn chainload(set: *common.volumes.Set, target: []const u8) void {
    const vol = if (std.mem.eql(u8, target, "windows"))
        set.findWindowsBoot(0)
    else blk: {
        const wanted = common.config.chainPartition(target) orelse break :blk null;
        const found = set.findPartition(0, wanted.number);
        if (wanted.device_name and found != null) {
            // The BIOS has no device names: say what is being started.
            say("\r\n{s}: starting partition {d} of the boot disk\r\n", .{ target, wanted.number });
            _ = con.getKey(2000);
        }
        break :blk found;
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
    if (sector[510] != 0x55 or sector[511] != 0xAA) {
        say("\r\n'{s}' does not start with a boot sector (not a boot sector).", .{target});
        return;
    }
    // The MBR entry a boot sector is handed holds 32-bit sector numbers.
    const first_sector = v.region.start / v.region.dev.sector_size;
    const lba = std.math.cast(u32, first_sector) orelse {
        say("\r\n'{s}' starts too far into the disk to be chainloaded.", .{target});
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
    std.mem.writeInt(u32, entry[8..12], lba, .little);
    std.mem.writeInt(u32, entry[12..16], std.math.cast(u32, v.region.len / v.region.dev.sector_size) orelse std.math.maxInt(u32), .little);
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
        var cbuf: [common.menu.max_cmdline]u8 = undefined;
        const r = common.menu.manualPrompt(c, .no_config, &pbuf, &cbuf) orelse return;
        bootLinux(set, vol, r.path, &.{}, null, null, r.cmdline) catch {};
        say("\r\nBoot failed. Press a key.", .{});
        _ = c.getKey(null);
    }
}

/// Runs first, on a small stack in low memory: the real stack and the heap are
/// at fixed addresses that a machine with little RAM doesn't have.
export fn stage2_early() callconv(.c) void {
    clearBss();
    con.init();
    // Conventional memory holds the loader, the disk buffer and what the
    // kernel is handed; the BIOS may keep part of it for itself.
    const low_needed = rm.cmdline_addr + max_cmdline_area;
    const low = lowMemoryKib();
    if (low * 1024 < low_needed) {
        say("dklilo: not enough low memory ({d} KiB; {d} needed)\r\n", .{ low, (low_needed + 1023) / 1024 });
        halt();
    }
    const e820 = readE820();
    if (e820.len == 0) return;
    if (bp.rangeUsable(e820, stack_floor, stack_top) and
        bp.rangeUsable(e820, heap_addr, heap_addr + heap_size)) return;
    con.clear();
    say("dklilo: not enough memory (RAM is needed from {d} to {d} MiB)\r\n", .{
        stack_floor >> 20, (heap_addr + heap_size) >> 20,
    });
    halt();
}

/// With no configuration found, says which volumes couldn't be looked into.
fn reportProbeErrors(set: *common.volumes.Set, c: common.console.Console) void {
    var any = false;
    for (set.vols.items) |v| if (v.probe_error) |e| {
        say("partition {d}: {s}\r\n", .{ v.number, @errorName(e) });
        any = true;
    };
    if (any) _ = c.getKey(5000);
}

export fn stage2_main() callconv(.c) noreturn {
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

    const found = set.findConfig(null);
    if (found == null) reportProbeErrors(&set, c);
    if (found) |f| {
        if (set.readFile(f.vol, f.path)) |text| {
            var diag = common.config.Diagnostic{};
            if (common.config.parse(allocator, text, &diag)) |parsed| {
                var cfg = parsed;
                var failed = false; // from then on, only a key starts anything
                while (true) {
                    var cmd: [common.menu.max_cmdline]u8 = undefined;
                    const result = common.menu.run(c, &cfg, &cmd, failed) orelse break;
                    failed = true;
                    const choice = switch (result) {
                        .boot => |choice| choice,
                        .manual => {
                            var pbuf: [256]u8 = undefined;
                            if (common.menu.manualPrompt(c, .chosen, &pbuf, &cmd)) |r| {
                                bootLinux(&set, f.vol, r.path, &.{}, null, null, r.cmdline) catch {};
                                say("\r\nBoot failed. Press a key.", .{});
                                _ = c.getKey(null);
                            }
                            continue;
                        },
                    };
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
        } else |e| {
            say("cannot read {s}: {s}\r\n", .{ f.path, @errorName(e) });
            _ = c.getKey(3000);
        }
    }
    manual(&set, c);
    halt();
}

fn halt() noreturn {
    while (true) asm volatile ("hlt");
}
