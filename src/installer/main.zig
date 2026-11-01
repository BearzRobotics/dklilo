//! `dklilo`: installs and checks the boot loader. Static, no libc.
//!
//!   dklilo check [conf] [--device DEV]
//!   dklilo install-bios <disk> [--yes]
//!   dklilo install-uefi <esp-dir> [--removable] [--entry-file F] [--device DEV] [--yes]
//!   dklilo config [--boot DIR] [-o FILE] [--force] [--root DEV] [--append STR] [--no-windows]
//!   dklilo mkiso-images <dir>
//!   dklilo isohybrid <iso>
//!
//! Every disk write is listed first and needs --yes or a typed confirmation.

const std = @import("std");
const common = @import("common");
const plan = @import("plan.zig");
const fat12 = @import("fat12.zig");
const genconfig = @import("genconfig.zig");

const Io = std.Io;

const stage1_image = @embedFile("stage1.bin");
const stage2_image = @embedFile("stage2.bin");
const cdstub_image = @embedFile("cdstub.bin");
const efi_image = @embedFile("dkliloX64.efi");

var io_global: Io = undefined;
var gpa_global: std.mem.Allocator = undefined;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    Io.File.stdout().writeStreamingAll(io_global, s) catch {};
}

fn err(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    Io.File.stderr().writeStreamingAll(io_global, s) catch {};
}

fn usage() u8 {
    err(
        \\usage:
        \\  dklilo check [conf] [--device DEV]
        \\  dklilo install-bios <disk> [--yes]
        \\  dklilo install-uefi <esp-dir> [--removable] [--entry-file FILE] [--device DEV] [--yes]
        \\  dklilo config [--boot DIR] [-o FILE] [--force] [--root DEV] [--append STR] [--no-windows]
        \\  dklilo mkiso-images <dir>
        \\  dklilo isohybrid <iso>
        \\
    , .{});
    return 2;
}

// ---- devices ---------------------------------------------------------------

/// A disk or image file, read and written by byte offset.
const Device = struct {
    file: Io.File,
    size: u64,

    fn open(path: []const u8, write: bool) !Device {
        const f = try Io.Dir.cwd().openFile(io_global, path, .{ .mode = if (write) .read_write else .read_only });
        var size = f.length(io_global) catch 0;
        if (size == 0) {
            // Block devices report no length; ask the kernel.
            var bytes: u64 = 0;
            const BLKGETSIZE64 = 0x80081272;
            if (std.os.linux.ioctl(f.handle, BLKGETSIZE64, @intFromPtr(&bytes)) == 0) size = bytes;
        }
        return .{ .file = f, .size = size };
    }
    fn close(self: *Device) void {
        self.file.close(io_global);
    }
    fn readAt(self: *Device, off: u64, buf: []u8) !void {
        const n = try self.file.readPositionalAll(io_global, buf, off);
        if (n != buf.len) return error.ShortRead;
    }
    fn writeAt(self: *Device, off: u64, data: []const u8) !void {
        try self.file.writePositionalAll(io_global, data, off);
    }
    fn blockDev(self: *Device) common.blockdev.BlockDev {
        return .{ .ctx = self, .readSectorsFn = read, .sector_size = 512, .sector_count = self.size / 512 };
    }
    fn read(ctx: *anyopaque, lba: u64, buf: []u8) common.blockdev.Error!void {
        const self: *Device = @ptrCast(@alignCast(ctx));
        self.readAt(lba * 512, buf) catch return error.IoError;
    }
};

fn confirm(yes: bool) bool {
    if (yes) return true;
    out("Proceed? Type 'yes': ", .{});
    var buf: [64]u8 = undefined;
    var r = Io.File.stdin().reader(io_global, &buf);
    const line = r.interface.takeDelimiterExclusive('\n') catch return false;
    return std.mem.eql(u8, std.mem.trim(u8, line, " \r\t"), "yes");
}

// ---- install-bios ----------------------------------------------------------

fn installBios(args: []const [:0]const u8) !u8 {
    var disk_path: ?[]const u8 = null;
    var yes = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--yes")) yes = true else if (disk_path == null) disk_path = a else return usage();
    }
    const path = disk_path orelse return usage();

    var dev = Device.open(path, true) catch |e| {
        err("dklilo: cannot open {s}: {s}\n", .{ path, @errorName(e) });
        return 1;
    };
    defer dev.close();

    // The plan needs the start of the disk: the MBR, GPT and the gap.
    const head_len: usize = @intCast(@min(dev.size, 1024 * 1024));
    const head = try gpa_global.alloc(u8, head_len);
    defer gpa_global.free(head);
    try dev.readAt(0, head);

    const padded = try gpa_global.alloc(u8, stage2_image.len + 1024);
    defer gpa_global.free(padded);
    const p = plan.planBios(head, stage1_image, stage2_image, padded, gpa_global) catch |e| {
        switch (e) {
            error.ForeignData => err("dklilo: the space for stage 2 holds data that is not zeros or an older dklilo.\n  Refusing to overwrite it (another boot loader may live there).\n", .{}),
            error.NoRoom => err("dklilo: not enough room before the first partition for stage 2 ({d} bytes).\n", .{stage2_image.len}),
            error.NoBiosBootPartition => err("dklilo: this GPT disk has no BIOS boot partition (type EF02) to hold stage 2.\n", .{}),
            error.NoPartitionTable => err("dklilo: {s} has no partition table (no 0x55AA MBR signature).\n", .{path}),
            error.BadImage => err("dklilo: internal error: bad embedded boot images.\n", .{}),
        }
        return 1;
    };

    out("Installing the BIOS boot loader on {s}:\n", .{path});
    const writes = p.writes();
    for (writes) |w| out("  write {s}: offset {d}, {d} bytes\n", .{ w.what, w.offset, w.data.len });
    out("  stage 2 at LBA {d} ({d} sectors)\n", .{ p.stage2_lba, p.stage2_sectors });
    if (p.replaces_boot_code) out("  note: the existing MBR boot code will be replaced\n", .{});
    if (!confirm(yes)) {
        out("Aborted; nothing was written.\n", .{});
        return 1;
    }
    for (writes) |w| try dev.writeAt(w.offset, w.data);
    dev.file.sync(io_global) catch {};
    out("Done.\n", .{});
    return 0;
}

// ---- install-uefi ----------------------------------------------------------

const boot_guid = "8be4df61-93ca-11d2-aa0d-00e098032b8c";
const efivars = "/sys/firmware/efi/efivars";

/// Splits `/dev/nvme0n1p1` into (`/dev/nvme0n1`, 1) and `/dev/sda2` into
/// (`/dev/sda`, 2).
fn splitPartitionName(dev: []const u8, disk_buf: []u8) ?struct { disk: []const u8, number: u32 } {
    var end = dev.len;
    while (end > 0 and std.ascii.isDigit(dev[end - 1])) end -= 1;
    if (end == dev.len or end == 0) return null;
    const number = std.fmt.parseInt(u32, dev[end..], 10) catch return null;
    var base = dev[0..end];
    // nvme0n1p1, mmcblk0p1: the 'p' separates a disk name that ends in a digit.
    if (base.len >= 2 and base[base.len - 1] == 'p' and std.ascii.isDigit(base[base.len - 2])) base = base[0 .. base.len - 1];
    @memcpy(disk_buf[0..base.len], base);
    return .{ .disk = disk_buf[0..base.len], .number = number };
}

/// Finds the device mounted at (or containing) `dir` from /proc/self/mountinfo.
fn mountSource(dir: []const u8, buf: []u8) ?[]const u8 {
    const text = Io.Dir.cwd().readFileAlloc(io_global, "/proc/self/mountinfo", gpa_global, .limited(1 << 20)) catch return null;
    defer gpa_global.free(text);
    var best_len: usize = 0;
    var found: ?[]const u8 = null;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        var i: usize = 0;
        var mp: []const u8 = "";
        while (f.next()) |tok| : (i += 1) {
            if (i == 4) mp = tok;
            if (std.mem.eql(u8, tok, "-")) {
                _ = f.next(); // fs type
                const src = f.next() orelse break;
                if (std.mem.startsWith(u8, dir, mp) and mp.len >= best_len and std.mem.startsWith(u8, src, "/dev/")) {
                    best_len = mp.len;
                    @memcpy(buf[0..src.len], src);
                    found = buf[0..src.len];
                }
                break;
            }
        }
    }
    return found;
}

fn installUefi(args: []const [:0]const u8) !u8 {
    var esp: ?[]const u8 = null;
    var removable = false;
    var yes = false;
    var entry_file: ?[]const u8 = null;
    var device: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (std.mem.eql(u8, a, "--removable")) {
            removable = true;
        } else if (std.mem.eql(u8, a, "--yes")) {
            yes = true;
        } else if (std.mem.eql(u8, a, "--entry-file") and i + 1 < args.len) {
            i += 1;
            entry_file = args[i];
        } else if (std.mem.eql(u8, a, "--device") and i + 1 < args.len) {
            i += 1;
            device = args[i];
        } else if (esp == null) {
            esp = a;
        } else return usage();
    }
    const esp_dir = esp orelse return usage();

    const target_rel: []const u8 = if (removable) "EFI/BOOT/BOOTX64.EFI" else "EFI/dklilo/dkliloX64.efi";
    out("Installing the UEFI boot loader into {s}:\n  copy dkliloX64.efi ({d} bytes) to {s}/{s}\n", .{ esp_dir, efi_image.len, esp_dir, target_rel });

    // The boot entry (not needed for removable media).
    var load_option_buf: [512]u8 = undefined;
    var load_option: ?[]u8 = null;
    if (!removable) {
        var devbuf: [256]u8 = undefined;
        const dev_path = device orelse mountSource(esp_dir, &devbuf) orelse {
            err("dklilo: cannot tell which partition {s} is on; pass --device /dev/...\n", .{esp_dir});
            return 1;
        };
        var diskbuf: [256]u8 = undefined;
        const sp = splitPartitionName(dev_path, &diskbuf) orelse {
            err("dklilo: {s} does not look like a partition\n", .{dev_path});
            return 1;
        };
        var disk = Device.open(sp.disk, false) catch |e| {
            err("dklilo: cannot open {s}: {s}\n", .{ sp.disk, @errorName(e) });
            return 1;
        };
        defer disk.close();
        const table = common.part.read(disk.blockDev()) catch {
            err("dklilo: cannot read the partition table of {s}\n", .{sp.disk});
            return 1;
        };
        var info: ?plan.PartitionInfo = null;
        for (table.slice()) |p| if (p.number == sp.number) {
            var sig = std.mem.zeroes([16]u8);
            if (table.kind == .gpt) sig = p.part_guid else std.mem.writeInt(u32, sig[0..4], table.disk_signature, .little);
            info = .{ .number = p.number, .start_lba = p.start_lba, .sector_count = p.sector_count, .signature = sig, .is_gpt = table.kind == .gpt };
        };
        const pi = info orelse {
            err("dklilo: partition {d} not found on {s}\n", .{ sp.number, sp.disk });
            return 1;
        };
        load_option = plan.buildLoadOption(&load_option_buf, "dklilo", pi, "\\EFI\\dklilo\\dkliloX64.efi");
        out("  boot entry: partition {d} of {s}, \\EFI\\dklilo\\dkliloX64.efi\n", .{ pi.number, sp.disk });
    }
    if (load_option != null) {
        if (entry_file) |f| out("  write the EFI_LOAD_OPTION to {s}\n", .{f}) else out("  create a Boot#### variable and put it first in BootOrder (efivarfs)\n", .{});
    }
    if (!confirm(yes)) {
        out("Aborted; nothing was written.\n", .{});
        return 1;
    }

    // Copy the loader.
    var dir = Io.Dir.cwd().openDir(io_global, esp_dir, .{}) catch |e| {
        err("dklilo: cannot open {s}: {s}\n", .{ esp_dir, @errorName(e) });
        return 1;
    };
    defer dir.close(io_global);
    if (std.fs.path.dirname(target_rel)) |sub| try dir.createDirPath(io_global, sub);
    try dir.writeFile(io_global, .{ .sub_path = target_rel, .data = efi_image });

    if (load_option) |lo| {
        if (entry_file) |f| {
            try Io.Dir.cwd().writeFile(io_global, .{ .sub_path = f, .data = lo });
        } else {
            writeBootVariable(lo) catch |e| {
                err("dklilo: the loader is installed, but creating the boot entry failed: {s}\n  (is efivarfs mounted at {s}? you can use --entry-file)\n", .{ @errorName(e), efivars });
                return 1;
            };
        }
    }
    out("Done.\n", .{});
    return 0;
}

/// Creates (or updates) our Boot#### variable and puts it first in BootOrder.
fn writeBootVariable(load_option: []const u8) !void {
    const attrs = [4]u8{ 7, 0, 0, 0 }; // non-volatile | boot service | runtime
    var dir = try Io.Dir.cwd().openDir(io_global, efivars, .{ .iterate = true });
    defer dir.close(io_global);

    // Reuse our entry if one exists, else take the lowest free number.
    var number: u16 = 0xFFFF;
    var free: ?u16 = null;
    var n: u32 = 0;
    while (n <= 0xFFFF) : (n += 1) {
        var name: [64]u8 = undefined;
        const nm = std.fmt.bufPrint(&name, "Boot{X:0>4}-" ++ boot_guid, .{n}) catch unreachable;
        const data = dir.readFileAlloc(io_global, nm, gpa_global, .limited(4096)) catch {
            if (free == null) free = @intCast(n);
            if (n > 0x40 and free != null) break;
            continue;
        };
        defer gpa_global.free(data);
        // attrs(4) + load attrs(4) + path length(2) + description
        const desc = "d\x00k\x00l\x00i\x00l\x00o\x00\x00\x00";
        if (data.len > 10 + desc.len and std.mem.eql(u8, data[10..][0..desc.len], desc)) {
            number = @intCast(n);
            break;
        }
    }
    if (number == 0xFFFF) number = free orelse return error.NoFreeBootNumber;

    var name: [64]u8 = undefined;
    const nm = try std.fmt.bufPrint(&name, "Boot{X:0>4}-" ++ boot_guid, .{number});
    try writeVar(dir, nm, &attrs, load_option);

    // BootOrder: our entry first, the rest in their old order.
    var order: [2 * 256]u8 = undefined;
    var order_len: usize = 0;
    std.mem.writeInt(u16, order[0..2], number, .little);
    order_len = 2;
    if (dir.readFileAlloc(io_global, "BootOrder-" ++ boot_guid, gpa_global, .limited(4096))) |old| {
        defer gpa_global.free(old);
        var k: usize = 4;
        while (k + 2 <= old.len and order_len + 2 <= order.len) : (k += 2) {
            const v = std.mem.readInt(u16, old[k..][0..2], .little);
            if (v == number) continue;
            std.mem.writeInt(u16, order[order_len..][0..2], v, .little);
            order_len += 2;
        }
    } else |_| {}
    try writeVar(dir, "BootOrder-" ++ boot_guid, &attrs, order[0..order_len]);
    out("  boot entry Boot{X:0>4} created\n", .{number});
}

fn writeVar(dir: Io.Dir, name: []const u8, attrs: []const u8, data: []const u8) !void {
    // efivarfs wants the attributes and the value in a single write().
    const buf = try gpa_global.alloc(u8, attrs.len + data.len);
    defer gpa_global.free(buf);
    @memcpy(buf[0..attrs.len], attrs);
    @memcpy(buf[attrs.len..], data);
    try dir.writeFile(io_global, .{ .sub_path = name, .data = buf });
}

// ---- check -----------------------------------------------------------------

fn check(args: []const [:0]const u8) !u8 {
    var conf_path: ?[]const u8 = null;
    var device: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (std.mem.eql(u8, a, "--device") and i + 1 < args.len) {
            i += 1;
            device = args[i];
        } else if (conf_path == null) conf_path = a else return usage();
    }

    var set = common.volumes.Set.init(gpa_global);
    defer set.deinit();

    // Where do the files live? With --device, in that disk's filesystems (and
    // the config is found the way the boot loader finds it). Otherwise the
    // config is a host file and its filesystem's device is looked up.
    var dev_storage: [8]Device = undefined;
    var ndev: usize = 0;
    defer for (dev_storage[0..ndev]) |*d| d.close();

    var text: []u8 = undefined;
    var default_vol: *common.volumes.Volume = undefined;

    if (device) |dp| {
        dev_storage[0] = Device.open(dp, false) catch |e| {
            err("dklilo: cannot open {s}: {s}\n", .{ dp, @errorName(e) });
            return 1;
        };
        ndev = 1;
        _ = try set.addDisk(dev_storage[0].blockDev());
        const found = set.findConfig(null) orelse {
            err("dklilo: no dklilo.conf found on {s}\n", .{dp});
            return 1;
        };
        out("config: {s}\n", .{found.path});
        text = set.readFile(found.vol, found.path) catch |e| {
            err("dklilo: cannot read the config: {s}\n", .{@errorName(e)});
            return 1;
        };
        default_vol = found.vol;
    } else {
        const path = conf_path orelse "/boot/dklilo.conf";
        text = Io.Dir.cwd().readFileAlloc(io_global, path, gpa_global, .limited(1 << 20)) catch |e| {
            err("dklilo: cannot read {s}: {s}\n", .{ path, @errorName(e) });
            return 1;
        };
        var abs_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const abs_len = Io.Dir.cwd().realPathFile(io_global, path, &abs_buf) catch 0;
        var devbuf: [256]u8 = undefined;
        const src = mountSource(abs_buf[0..abs_len], &devbuf) orelse {
            err("dklilo: cannot tell which device holds {s}; use --device\n", .{path});
            return 1;
        };
        dev_storage[0] = Device.open(src, false) catch |e| {
            err("dklilo: cannot open {s}: {s}\n", .{ src, @errorName(e) });
            return 1;
        };
        ndev = 1;
        _ = try set.addDisk(dev_storage[0].blockDev());
        default_vol = &set.vols.items[0];
    }
    defer gpa_global.free(text);

    var diag = common.config.Diagnostic{};
    var cfg = common.config.parse(gpa_global, text, &diag) catch |e| {
        err("dklilo: config line {d}: {s}\n", .{ diag.line, @errorName(e) });
        return 1;
    };
    defer cfg.deinit();
    out("{d} entries, labels unique, default '{s}'\n", .{ cfg.entries.len, cfg.entries[cfg.defaultIndex()].label });

    var problems: u32 = 0;
    for (cfg.entries) |e| {
        if (e.kind == .chain) {
            out("ok:   {s}: chainload {s}\n", .{ e.label, e.target });
            continue;
        }
        var vol = default_vol;
        var sub = e.subvol;
        if (e.iso) |iso| {
            // Loopback ISO: mount the file, then check inside it.
            vol = set.isoVolume(default_vol, iso, e.subvol) catch |er| {
                err("FAIL: {s}: iso {s}: {s}\n", .{ e.label, iso, @errorName(er) });
                problems += 1;
                continue;
            };
            sub = null;
            out("ok:   {s}: iso {s}\n", .{ e.label, iso });
        }
        problems += checkFile(&set, vol, e.label, "image", e.target, sub);
        for (e.initrds) |ir| problems += checkFile(&set, vol, e.label, "initrd", ir, sub);
        if (e.root) |r| {
            if ((std.mem.startsWith(u8, r, "LABEL=") or std.mem.startsWith(u8, r, "UUID=")) and e.initrds.len == 0) {
                out("warn: {s}: root={s} needs an initramfs to be resolved (PARTUUID= works without)\n", .{ e.label, r });
            }
        }
    }
    if (problems > 0) {
        err("dklilo: {d} problem(s) found\n", .{problems});
        return 1;
    }
    out("all files found\n", .{});
    return 0;
}

fn checkFile(set: *common.volumes.Set, def: *common.volumes.Volume, label: []const u8, what: []const u8, spec: []const u8, subvol: ?[]const u8) u32 {
    if (set.openFile(def, spec, subvol)) |o| {
        out("ok:   {s}: {s} {s} ({d} bytes)\n", .{ label, what, spec, o.file.size });
        return 0;
    } else |e| {
        err("FAIL: {s}: {s} {s}: {s}\n", .{ label, what, spec, @errorName(e) });
        return 1;
    }
}

// ---- config ----------------------------------------------------------------

/// `/dev/disk/by-partuuid/X -> ../../sda2` lookup: the PARTUUID of `dev`.
fn partuuidOf(dev: []const u8, buf: []u8) ?[]const u8 {
    var dir = Io.Dir.cwd().openDir(io_global, "/dev/disk/by-partuuid", .{ .iterate = true }) catch return null;
    defer dir.close(io_global);
    var it = dir.iterate();
    const want = std.fs.path.basename(dev);
    while (it.next(io_global) catch null) |e| {
        var lb: [256]u8 = undefined;
        const n = dir.readLink(io_global, e.name, &lb) catch continue;
        if (std.mem.eql(u8, std.fs.path.basename(lb[0..n]), want) and e.name.len <= buf.len) {
            @memcpy(buf[0..e.name.len], e.name);
            return buf[0..e.name.len];
        }
    }
    return null;
}

/// Is there a Windows install on any local disk? NTFS boot sector (BIOS) or
/// \EFI\Microsoft\Boot\bootmgfw.efi on a FAT partition (UEFI).
fn detectWindows() bool {
    var sys = Io.Dir.cwd().openDir(io_global, "/sys/block", .{ .iterate = true }) catch return false;
    defer sys.close(io_global);
    var devs: std.ArrayList(*Device) = .empty;
    defer {
        for (devs.items) |d| {
            d.close();
            gpa_global.destroy(d);
        }
        devs.deinit(gpa_global);
    }
    var set = common.volumes.Set.init(gpa_global);
    defer set.deinit();
    var it = sys.iterate();
    while (it.next(io_global) catch null) |e| {
        const skip = [_][]const u8{ "loop", "ram", "zram", "sr", "dm-", "md", "nbd", "fd" };
        var bad = false;
        for (skip) |p| if (std.mem.startsWith(u8, e.name, p)) {
            bad = true;
        };
        if (bad) continue;
        var pb: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "/dev/{s}", .{e.name}) catch continue;
        const d = gpa_global.create(Device) catch continue;
        d.* = Device.open(path, false) catch {
            gpa_global.destroy(d);
            continue;
        };
        devs.append(gpa_global, d) catch {
            d.close();
            gpa_global.destroy(d);
            continue;
        };
        _ = set.addDisk(d.blockDev()) catch continue;
    }
    for (set.vols.items) |*v| {
        if (v.number != 0 and v.hasNtfsBootSector()) return true;
        const fs = v.filesystem(gpa_global) orelse continue;
        if (fs.* != .fat) continue;
        if (fs.lookup("/EFI/Microsoft/Boot/bootmgfw.efi")) |ino| {
            if (ino.is_regular) return true;
        } else |_| {}
    }
    return false;
}

fn configCmd(args: []const [:0]const u8) !u8 {
    var boot: []const u8 = "/boot";
    var out_path: ?[]const u8 = null;
    var force = false;
    var root_dev: ?[]const u8 = null;
    var append: []const u8 = "ro quiet";
    var want_windows = true;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        const has_next = i + 1 < args.len;
        if (std.mem.eql(u8, a, "--boot") and has_next) {
            i += 1;
            boot = args[i];
        } else if (std.mem.eql(u8, a, "-o") and has_next) {
            i += 1;
            out_path = args[i];
        } else if (std.mem.eql(u8, a, "--root") and has_next) {
            i += 1;
            root_dev = args[i];
        } else if (std.mem.eql(u8, a, "--append") and has_next) {
            i += 1;
            append = args[i];
        } else if (std.mem.eql(u8, a, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, a, "--no-windows")) {
            want_windows = false;
        } else return usage();
    }

    // List the boot directory.
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| gpa_global.free(n);
        names.deinit(gpa_global);
    }
    {
        var dir = Io.Dir.cwd().openDir(io_global, boot, .{ .iterate = true }) catch |e| {
            err("dklilo: cannot open {s}: {s}\n", .{ boot, @errorName(e) });
            return 1;
        };
        defer dir.close(io_global);
        var it = dir.iterate();
        while (try it.next(io_global)) |e| try names.append(gpa_global, try gpa_global.dupe(u8, e.name));
    }
    const kernels = try genconfig.findKernels(gpa_global, names.items);
    defer gpa_global.free(kernels);
    if (kernels.len == 0) err("dklilo: warning: no kernels (vmlinuz*) found in {s}\n", .{boot});

    // Is the boot directory its own filesystem? Then the config (kept in it)
    // refers to kernels as "/vmlinuz-…", otherwise as "/boot/vmlinuz-…".
    var abs_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const abs_len = Io.Dir.cwd().realPathFile(io_global, boot, &abs_buf) catch 0;
    const abs = abs_buf[0..abs_len];
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    const boot_src = mountSource(abs, &b1);
    const root_src = mountSource("/", &b2);
    const separate = boot_src != null and root_src != null and !std.mem.eql(u8, boot_src.?, root_src.?);
    const prefix: []const u8 = if (separate) "" else if (abs.len > 0) std.mem.trimEnd(u8, abs, "/") else "/boot";

    var uuid_buf: [64]u8 = undefined;
    var root_buf: [128]u8 = undefined;
    var root_val: ?[]const u8 = null;
    const rdev = root_dev orelse root_src;
    if (rdev) |rd| {
        if (std.mem.startsWith(u8, rd, "PARTUUID=") or std.mem.startsWith(u8, rd, "UUID=") or std.mem.startsWith(u8, rd, "LABEL=")) {
            root_val = rd;
        } else if (partuuidOf(rd, &uuid_buf)) |u| {
            root_val = std.fmt.bufPrint(&root_buf, "PARTUUID={s}", .{u}) catch null;
        } else if (!std.mem.eql(u8, rd, "/dev/root")) {
            root_val = rd;
            err("dklilo: note: no PARTUUID for {s}; using the device name, which can change between boots\n", .{rd});
        }
    }
    if (root_val == null) err("dklilo: warning: could not work out the root device; pass --root\n", .{});

    const windows = want_windows and detectWindows();
    var aw: Io.Writer.Allocating = .init(gpa_global);
    defer aw.deinit();
    try genconfig.render(&aw.writer, kernels, .{ .prefix = prefix, .root = root_val, .append = append, .windows = windows });

    // The loader must be able to parse what we wrote.
    var diag = common.config.Diagnostic{};
    var parsed = common.config.parse(gpa_global, aw.written(), &diag) catch |e| {
        err("dklilo: internal error: generated config does not parse (line {d}): {s}\n", .{ diag.line, @errorName(e) });
        return 1;
    };
    parsed.deinit();

    if (out_path) |op| {
        if (!force) {
            if (Io.Dir.cwd().access(io_global, op, .{})) {
                err("dklilo: {s} exists; use --force to overwrite it\n", .{op});
                return 1;
            } else |_| {}
        }
        Io.Dir.cwd().writeFile(io_global, .{ .sub_path = op, .data = aw.written() }) catch |e| {
            err("dklilo: cannot write {s}: {s}\n", .{ op, @errorName(e) });
            return 1;
        };
        err("wrote {s}: {d} Linux entr{s}{s}; check it with `dklilo check {s}`\n", .{ op, kernels.len, if (kernels.len == 1) "y" else "ies", if (windows) " + Windows" else "", op });
    } else {
        Io.File.stdout().writeStreamingAll(io_global, aw.written()) catch {};
    }
    return 0;
}

// ---- ISO images ------------------------------------------------------------

const cd_sector = 2048;

/// Writes the three files `xorriso` needs to build a bootable hybrid ISO:
///   eltorito.bin  El Torito BIOS image: a boot sector, then stage 2
///   efiboot.img   FAT image holding \EFI\BOOT\BOOTX64.EFI
///   mbr.bin       stage 1 as the 440-byte MBR code of the hybrid ISO
fn mkisoImages(args: []const [:0]const u8) !u8 {
    if (args.len != 1) return usage();
    const dir_path: []const u8 = args[0];
    var dir = Io.Dir.cwd().openDir(io_global, dir_path, .{}) catch |e| {
        err("dklilo: cannot open {s}: {s}\n", .{ dir_path, @errorName(e) });
        return 1;
    };
    defer dir.close(io_global);

    // eltorito.bin: the boot sector, then stage 2 padded to CD sectors.
    const s2_sectors = (stage2_image.len + cd_sector - 1) / cd_sector;
    const el = try gpa_global.alloc(u8, cd_sector * (1 + s2_sectors));
    defer gpa_global.free(el);
    @memset(el, 0);
    if (cdstub_image.len > cd_sector) return error.StubTooBig;
    @memcpy(el[0..cdstub_image.len], cdstub_image);
    std.mem.writeInt(u16, el[0x40..][0..2], @intCast(s2_sectors), .little);
    @memcpy(el[cd_sector..][0..stage2_image.len], stage2_image);
    try dir.writeFile(io_global, .{ .sub_path = "eltorito.bin", .data = el });

    const efi = fat12.buildEfiImage(gpa_global, efi_image) catch |e| {
        err("dklilo: cannot build the EFI image: {s}\n", .{@errorName(e)});
        return 1;
    };
    defer gpa_global.free(efi);
    try dir.writeFile(io_global, .{ .sub_path = "efiboot.img", .data = efi });
    try dir.writeFile(io_global, .{ .sub_path = "mbr.bin", .data = stage1_image[0..plan.mbr_code_size] });
    out("wrote eltorito.bin ({d} bytes), efiboot.img ({d} bytes), mbr.bin ({d} bytes) in {s}\n", .{ el.len, efi.len, plan.mbr_code_size, dir_path });
    return 0;
}

/// Makes a built ISO bootable from a USB stick under BIOS: finds eltorito.bin
/// through the El Torito boot catalog and points stage 1 (in the ISO's system
/// area, installed there by `xorriso --grub2-mbr mbr.bin`) at the stage 2 that
/// follows its boot sector. Only the 10-byte block list is rewritten.
fn isohybrid(args: []const [:0]const u8) !u8 {
    if (args.len != 1) return usage();
    var dev = Device.open(args[0], true) catch |e| {
        err("dklilo: cannot open {s}: {s}\n", .{ args[0], @errorName(e) });
        return 1;
    };
    defer dev.close();

    var vd: [cd_sector]u8 = undefined;
    try dev.readAt(17 * cd_sector, &vd);
    if (vd[0] != 0 or !std.mem.eql(u8, vd[1..6], "CD001") or !std.mem.startsWith(u8, vd[7..], "EL TORITO SPECIFICATION")) {
        err("dklilo: {s} has no El Torito boot record; build it with xorriso -b ... first\n", .{args[0]});
        return 1;
    }
    const catalog = std.mem.readInt(u32, vd[71..75], .little);
    var cat: [cd_sector]u8 = undefined;
    try dev.readAt(@as(u64, catalog) * cd_sector, &cat);
    // Validation entry, then the default (BIOS) entry.
    if (cat[0] != 1 or cat[30] != 0x55 or cat[31] != 0xAA or cat[32] != 0x88) {
        err("dklilo: unexpected boot catalog layout\n", .{});
        return 1;
    }
    const rba = std.mem.readInt(u32, cat[32 + 8 ..][0..4], .little);
    var second: [cd_sector]u8 = undefined;
    try dev.readAt((@as(u64, rba) + 1) * cd_sector, &second);
    if (!std.mem.eql(u8, second[2..10], plan.stage2_magic)) {
        err("dklilo: the El Torito image is not a dklilo eltorito.bin\n", .{});
        return 1;
    }
    const lba512: u64 = (@as(u64, rba) + 1) * 4;
    const sectors512: u16 = @intCast((stage2_image.len + 511) / 512);
    var bl: [10]u8 = undefined;
    std.mem.writeInt(u64, bl[0..8], lba512, .little);
    std.mem.writeInt(u16, bl[8..10], sectors512, .little);
    try dev.writeAt(plan.blocklist_offset, &bl);
    dev.file.sync(io_global) catch {};
    out("stage 1 now loads stage 2 from 512-byte sector {d} ({d} sectors)\n", .{ lba512, sectors512 });
    return 0;
}

// ---- main ------------------------------------------------------------------

pub fn main(init: std.process.Init) !u8 {
    io_global = init.io;
    gpa_global = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return usage();
    const cmd = args[1];
    const rest = args[2..];
    if (std.mem.eql(u8, cmd, "check")) return check(rest);
    if (std.mem.eql(u8, cmd, "install-bios")) return installBios(rest);
    if (std.mem.eql(u8, cmd, "install-uefi")) return installUefi(rest);
    if (std.mem.eql(u8, cmd, "config")) return configCmd(rest);
    if (std.mem.eql(u8, cmd, "mkiso-images")) return mkisoImages(rest);
    if (std.mem.eql(u8, cmd, "isohybrid")) return isohybrid(rest);
    return usage();
}
