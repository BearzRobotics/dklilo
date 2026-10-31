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

fn open(set: *common.volumes.Set, default: *common.volumes.Volume, spec: []const u8) BootError!struct { fs: *common.ext4.Fs, ino: common.ext4.Inode } {
    const at = set.resolve(spec, default) catch |e| {
        say("\r\n{s}: {s}", .{ spec, @errorName(e) });
        return error.NotFound;
    };
    const fs = at.vol.filesystem(set.allocator) orelse {
        say("\r\n{s}: no filesystem", .{spec});
        return error.NotFound;
    };
    const ino = fs.lookup(at.path) catch |e| {
        say("\r\n{s}: {s}", .{ spec, @errorName(e) });
        return error.NotFound;
    };
    return .{ .fs = fs, .ino = ino };
}

fn readInto(fs: *common.ext4.Fs, ino: *const common.ext4.Inode, offset: u64, dest: u64, len: u64) BootError!void {
    const p: [*]u8 = @ptrFromInt(@as(usize, @intCast(dest)));
    const n = fs.readAt(ino, offset, p[0..@intCast(len)]) catch return error.ReadFailed;
    if (n != len) return error.ReadFailed;
}

fn bootLinux(
    set: *common.volumes.Set,
    default: *common.volumes.Volume,
    kernel_spec: []const u8,
    initrd_specs: []const []const u8,
    cmdline: []const u8,
) BootError!void {
    say("\r\nLoading {s}...", .{kernel_spec});
    var k = try open(set, default, kernel_spec);
    var head: [4096]u8 = undefined;
    const head_len = k.fs.readAt(&k.ino, 0, &head) catch return error.ReadFailed;
    const kernel = bp.parseKernel(head[0..head_len], k.ino.size) catch |e| {
        say("\r\nnot a bootable kernel: {s}", .{@errorName(e)});
        return error.BadKernel;
    };

    const e820 = readE820();

    // Where the initramfs goes: size first, then as high as allowed.
    var total: u64 = 0;
    var initrds: [8]@TypeOf(k) = undefined;
    if (initrd_specs.len > initrds.len) return error.NotFound;
    for (initrd_specs, 0..) |spec, i| {
        initrds[i] = try open(set, default, spec);
        total += std.mem.alignForward(u64, initrds[i].ino.size, 4);
    }
    const kernel_end: u64 = kernel_addr + @max(@as(u64, kernel.pm_size), kernel.header.init_size);
    var initrd_at: u64 = 0;
    if (total > 0) {
        initrd_at = bp.placeInitrd(e820, kernel.header.initrd_addr_max, total, @max(kernel_end, initrd_floor)) orelse {
            say("\r\nnot enough memory for the initramfs", .{});
            return error.NoMemory;
        };
    }

    try readInto(k.fs, &k.ino, kernel.setup_size, kernel_addr, kernel.pm_size);
    say("\r\nLoading initramfs...", .{});
    var off: u64 = 0;
    for (initrd_specs, 0..) |_, i| {
        var f = initrds[i];
        try readInto(f.fs, &f.ino, 0, initrd_at + off, f.ino.size);
        const padded = std.mem.alignForward(u64, f.ino.size, 4);
        const pad: [*]u8 = @ptrFromInt(@as(usize, @intCast(initrd_at + off + f.ino.size)));
        @memset(pad[0..@intCast(padded - f.ino.size)], 0);
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
        bootLinux(set, vol, r.path, &.{}, r.cmdline) catch {};
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
                            bootLinux(&set, f.vol, entry.target, entry.initrds, choice.cmdline) catch {};
                            say("\r\nBoot failed. Press a key.", .{});
                            _ = c.getKey(null);
                        },
                        .chain => {
                            say("\r\nChainloading is not implemented yet. Press a key.", .{});
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
