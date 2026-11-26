//! `dklilo`: installs and checks the boot loader. Static, no libc.
//!
//!   dklilo check [conf] [--device DEV]
//!   dklilo install-bios <disk> [--force] [--yes]
//!   dklilo install-uefi <esp-dir> [--removable [--force]] [--entry-file F] [--device DEV] [--yes]
//!   dklilo config [--boot DIR] [-o FILE] [--force] [--root DEV] [--append STR] [--no-windows]
//!   dklilo mkiso-images <dir>
//!   dklilo isohybrid <iso> [--yes]
//!
//! Every disk write is listed first and needs --yes or a typed confirmation.

const std = @import("std");
const common = @import("common");
const plan = @import("plan.zig");
const fat12 = @import("fat12.zig");
const genconfig = @import("genconfig.zig");
const bootvars = @import("bootvars.zig");
const blockinfo = @import("blockinfo.zig");
const mounts = @import("mounts.zig");
const safefile = @import("safefile.zig");
const arch_mod = @import("arch.zig");
const Arch = arch_mod.Arch;

const Io = std.Io;

const stage1_image = @embedFile("stage1.bin");
const stage2_image = @embedFile("stage2.bin");
const cdstub_image = @embedFile("cdstub.bin");
/// The UEFI loader for each architecture; every one is embedded so the tool can
/// prepare a disk for a machine of a different architecture.
fn efiImage(a: Arch) []const u8 {
    return switch (a) {
        .x64 => @embedFile("dkliloX64.efi"),
        .aa64 => @embedFile("dkliloAA64.efi"),
        .arm => @embedFile("dkliloARM.efi"),
        .riscv64 => @embedFile("dkliloRISCV64.efi"),
    };
}

/// Parses `--arch` values, or reports the valid ones.
fn parseArch(v: []const u8) ?Arch {
    return arch_mod.parse(v) orelse {
        err("dklilo: unknown architecture '{s}' (use x64, aa64, arm or riscv64)\n", .{v});
        return null;
    };
}

var io_global: Io = undefined;
var gpa_global: std.mem.Allocator = undefined;
/// Freed when the program ends.
var arena_global: std.mem.Allocator = undefined;

fn print(file: Io.File, comptime fmt: []const u8, args: anytype) void {
    // Long paths make long lines: none may be dropped.
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch
        std.fmt.allocPrint(arena_global, fmt, args) catch return;
    file.writeStreamingAll(io_global, s) catch {};
}

fn out(comptime fmt: []const u8, args: anytype) void {
    print(Io.File.stdout(), fmt, args);
}

fn err(comptime fmt: []const u8, args: anytype) void {
    print(Io.File.stderr(), fmt, args);
}

/// Whether an argument is meant as an option, so an unknown one is not taken
/// for a path.
fn isOption(a: []const u8) bool {
    return a.len > 1 and a[0] == '-';
}

fn usage() u8 {
    err(
        \\usage:
        \\  dklilo check [conf] [--device DEV]
        \\  dklilo install-bios <disk> [--force] [--yes]
        \\  dklilo install-uefi <esp-dir> [--arch ARCH] [--removable [--force]] [--entry-file FILE] [--device DEV] [--yes]
        \\  dklilo config [--boot DIR] [-o FILE] [--force] [--root DEV] [--append STR] [--no-windows]
        \\  dklilo mkiso-images <dir> [--arch ARCH]
        \\  dklilo isohybrid <iso> [--yes]
        \\
    , .{});
    return 2;
}

// ---- devices ---------------------------------------------------------------

/// A disk or image file, read and written by byte offset.
const Device = struct {
    file: Io.File,
    size: u64,
    /// The disk's logical sector size; 512 for an image file.
    sector_size: u32 = 512,

    fn open(path: []const u8, write: bool) !Device {
        const f = try Io.Dir.cwd().openFile(io_global, path, .{ .mode = if (write) .read_write else .read_only });
        var size = f.length(io_global) catch 0;
        var sector_size: u32 = 512;
        if (size == 0) {
            // Block devices report no length; ask the kernel. BLKGETSIZE64 is
            // _IOR(0x12, 114, size_t): the number depends on the word size,
            // the result is 64 bits either way.
            var bytes: u64 = 0;
            const BLKGETSIZE64: u32 = if (@sizeOf(usize) == 8) 0x80081272 else 0x80041272;
            if (std.os.linux.ioctl(f.handle, BLKGETSIZE64, @intFromPtr(&bytes)) == 0) size = bytes;
        }
        var logical: c_int = 0;
        const BLKSSZGET: u32 = 0x1268;
        const rc = std.os.linux.ioctl(f.handle, BLKSSZGET, @intFromPtr(&logical));
        if (std.os.linux.errno(rc) == .SUCCESS and logical >= 512 and logical <= common.blockdev.max_sector_size)
            sector_size = @intCast(logical);
        return .{ .file = f, .size = size, .sector_size = sector_size };
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
        return .{ .ctx = self, .readSectorsFn = read, .sector_size = self.sector_size, .sector_count = self.size / self.sector_size };
    }
    fn read(ctx: *anyopaque, lba: u64, buf: []u8) common.blockdev.Error!void {
        const self: *Device = @ptrCast(@alignCast(ctx));
        self.readAt(lba * self.sector_size, buf) catch return error.IoError;
    }
};

/// The device number of the block device `path` names (symlinks followed), or
/// null if it names something else or nothing.
fn blockDeviceNumber(path: []const u8) ?struct { major: u32, minor: u32 } {
    const linux = std.os.linux;
    const z = arena_global.dupeSentinel(u8, path, 0) catch return null;
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, z.ptr, 0, .{ .TYPE = true }, &st)) != .SUCCESS) return null;
    if (st.mode & linux.S.IFMT != linux.S.IFBLK) return null;
    return .{ .major = st.rdev_major, .minor = st.rdev_minor };
}

fn confirm(yes: bool) bool {
    if (yes) return true;
    out("Proceed? Type 'yes': ", .{});
    var buf: [64]u8 = undefined;
    var r = Io.File.stdin().reader(io_global, &buf);
    const line = r.interface.takeDelimiterExclusive('\n') catch return false;
    return std.mem.eql(u8, std.mem.trim(u8, line, " \r\t"), "yes");
}

/// Does `path` (symlinks followed) name a partition's block device? Anything
/// that is not a block device, an image file for one, is not.
fn namesPartition(path: [:0]const u8) !bool {
    const linux = std.os.linux;
    var st: linux.Statx = undefined;
    // A path that cannot be examined is left to the open to report.
    if (linux.errno(linux.statx(linux.AT.FDCWD, path.ptr, 0, .{ .TYPE = true }, &st)) != .SUCCESS) return false;
    if (st.mode & linux.S.IFMT != linux.S.IFBLK) return false;
    var sys = try Io.Dir.cwd().openDir(io_global, "/sys/dev/block", .{});
    defer sys.close(io_global);
    return blockinfo.isPartition(io_global, sys, st.rdev_major, st.rdev_minor);
}

// ---- install-bios ----------------------------------------------------------

fn installBios(args: []const [:0]const u8) !u8 {
    var disk_path: ?[:0]const u8 = null;
    var yes = false;
    var force = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--yes")) {
            yes = true;
        } else if (std.mem.eql(u8, a, "--force")) {
            force = true;
        } else if (disk_path == null and !isOption(a)) disk_path = a else return usage();
    }
    const path = disk_path orelse return usage();
    const partition = namesPartition(path) catch |e| {
        err("dklilo: cannot tell whether {s} is a disk or a partition: {s}\n", .{ path, @errorName(e) });
        return 1;
    };
    if (partition) {
        err("dklilo: {s} is a partition. install-bios takes the whole disk (for example /dev/sda, not /dev/sda1).\n", .{path});
        return 1;
    }

    var dev = Device.open(path, true) catch |e| {
        err("dklilo: cannot open {s}: {s}\n", .{ path, @errorName(e) });
        return 1;
    };
    defer dev.close();
    if (dev.sector_size != 512) {
        err("dklilo: {s} has {d}-byte sectors; the BIOS loader can only be installed on 512-byte ones.\n", .{ path, dev.sector_size });
        return 1;
    }

    // The plan needs the start of the disk: the MBR, GPT, the gap and the BIOS
    // boot partition. Tools align the first partition to 1 MiB, so a BIOS boot
    // partition normally spans 1-2 MiB; one placed further in is read apart.
    const head_len: usize = @intCast(@min(dev.size, 4 * 1024 * 1024));
    const head = try gpa_global.alloc(u8, head_len);
    defer gpa_global.free(head);
    try dev.readAt(0, head);

    var far: ?plan.Area = null;
    if (plan.biosBootPartition(head)) |bb| {
        // Typed: `@min` with a constant would give a type too narrow for the
        // byte count.
        const sectors: u64 = @min(bb.sectors, plan.max_stage2_sectors);
        const disk_sectors = dev.size / plan.sector_size;
        if (bb.lba < disk_sectors and sectors <= disk_sectors - bb.lba and
            (bb.lba + sectors) * plan.sector_size > head.len)
        {
            const data = try arena_global.alloc(u8, @intCast(sectors * plan.sector_size));
            try dev.readAt(bb.lba * plan.sector_size, data);
            far = .{ .lba = bb.lba, .data = data };
        }
    }

    const padded = try gpa_global.alloc(u8, plan.max_stage2_sectors * plan.sector_size);
    defer gpa_global.free(padded);
    const p = plan.planBios(head, stage1_image, stage2_image, padded, force, far) catch |e| {
        switch (e) {
            error.ForeignData => err("dklilo: the space for stage 2 holds data that is not zeros or an older dklilo.\n  Refusing to overwrite it (another boot loader may live there).\n", .{}),
            error.NoRoom => err("dklilo: not enough room before the first partition for stage 2 ({d} bytes).\n", .{stage2_image.len}),
            error.BiosBootTooSmall => err("dklilo: the BIOS boot partition is too small for stage 2 ({d} bytes).\n", .{stage2_image.len}),
            error.NoBiosBootPartition => err("dklilo: this GPT disk has no BIOS boot partition (type EF02) to hold stage 2.\n", .{}),
            error.NoPartitionTable => err("dklilo: {s} has no partition table (no 0x55AA MBR signature).\n", .{path}),
            error.BadImage => err("dklilo: internal error: bad embedded boot images.\n", .{}),
            error.UnrecordedStage2 => err("dklilo: an older dklilo stage 2 is there, but the MBR no longer records its length,\n  so what follows it cannot be checked. If nothing else uses that space, repeat with --force.\n", .{}),
            error.FilesystemBootSector => err("dklilo: {s} starts with a filesystem's boot sector, not a partition table. Refusing:\n  installing would destroy that filesystem. Give the whole disk.\n", .{path}),
            error.BadPartitionTable => err("dklilo: {s} has no valid MBR partition table (bad status byte in an entry).\n", .{path}),
            error.NoPartitions => err("dklilo: the partition table of {s} is empty.\n", .{path}),
        }
        return 1;
    };

    out("Installing the BIOS boot loader on {s}:\n", .{path});
    const writes = p.writes();
    for (writes) |w| out("  write {s}: offset {d}, {d} bytes\n", .{ w.what, w.offset, w.data.len });
    out("  stage 2 at LBA {d} ({d} sectors)\n", .{ p.stage2_lba, p.stage2_sectors });
    const cleared = p.writes()[0].data.len / plan.sector_size - p.stage2_sectors;
    if (cleared > 0) out("  note: the write also zeroes {d} more sectors left by a longer older stage 2\n", .{cleared});
    if (p.replaces_boot_code) out("  note: the existing MBR boot code will be replaced\n", .{});
    if (!confirm(yes)) {
        out("Aborted; nothing was written.\n", .{});
        return 1;
    }
    // Each write is on the disk before the next starts, so the MBR never
    // points at a stage 2 that isn't there.
    for (writes) |w| {
        dev.writeAt(w.offset, w.data) catch |e| {
            err("dklilo: writing {s} to {s} failed: {s}. The boot loader is not installed.\n", .{ w.what, path, @errorName(e) });
            return 1;
        };
        dev.file.sync(io_global) catch |e| {
            err("dklilo: {s} may not have reached {s}: {s}. The boot loader may not be installed.\n", .{ w.what, path, @errorName(e) });
            return 1;
        };
    }
    out("Done.\n", .{});
    return 0;
}

// ---- install-uefi ----------------------------------------------------------

const efivars = "/sys/firmware/efi/efivars";

const PartitionName = struct { disk: []const u8, number: u32 };

/// The disk and number of the partition `dev` names. Block devices (by any
/// name, such as a `/dev/disk/by-*` link) are looked up in sysfs; the name of
/// anything else, an image's partition for a test, is taken apart.
fn findPartition(dev: []const u8) !?PartitionName {
    const number = blockDeviceNumber(dev) orelse return splitPartitionName(dev);
    var sys = try Io.Dir.cwd().openDir(io_global, "/sys/dev/block", .{});
    defer sys.close(io_global);
    var name: [64]u8 = undefined;
    const p = (try blockinfo.partition(io_global, sys, number.major, number.minor, &name)) orelse return null;
    return .{ .disk = try std.fmt.allocPrint(arena_global, "/dev/{s}", .{p.disk}), .number = p.number };
}

/// Splits `/dev/nvme0n1p1` into (`/dev/nvme0n1`, 1) and `/dev/sda2` into
/// (`/dev/sda`, 2).
fn splitPartitionName(dev: []const u8) ?PartitionName {
    var end = dev.len;
    while (end > 0 and std.ascii.isDigit(dev[end - 1])) end -= 1;
    if (end == dev.len or end == 0) return null;
    const number = std.fmt.parseInt(u32, dev[end..], 10) catch return null;
    var base = dev[0..end];
    // nvme0n1p1, mmcblk0p1: the 'p' separates a disk name that ends in a digit.
    if (base.len >= 2 and base[base.len - 1] == 'p' and std.ascii.isDigit(base[base.len - 2])) base = base[0 .. base.len - 1];
    return .{ .disk = base, .number = number };
}

/// /proc/self/mountinfo, or the file given as `--mountinfo FILE` (tests).
var mountinfo_override: ?[]const u8 = null;
fn mountinfoPath() []const u8 {
    return mountinfo_override orelse "/proc/self/mountinfo";
}

/// Reads a whole file by streaming until EOF. `readFileAlloc` trusts the size
/// from stat, which is 0 for files in /proc, so it returns nothing for them.
fn readStreamed(path: []const u8) ![]u8 {
    var file = try Io.Dir.cwd().openFile(io_global, path, .{});
    defer file.close(io_global);
    var fr = file.readerStreaming(io_global, &.{});
    return fr.interface.allocRemaining(arena_global, .limited(1 << 20)) catch |e| switch (e) {
        error.ReadFailed => return fr.err.?,
        error.OutOfMemory, error.StreamTooLong => |x| return x,
    };
}

/// The mount holding the absolute path `dir`.
fn mountOf(dir: []const u8) ?mounts.Mount {
    const text = readStreamed(mountinfoPath()) catch return null;
    return mounts.find(arena_global, text, dir) catch null;
}

/// `path` made absolute, with symlinks resolved. A path that can't be
/// resolved is returned as it is.
fn canonical(path: []const u8) []const u8 {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = Io.Dir.cwd().realPathFile(io_global, path, &buf) catch return path;
    return arena_global.dupe(u8, buf[0..n]) catch path;
}

/// What is at `path`, where a loader is about to be written.
fn existingLoader(path: []const u8) !enum { none, dklilo, foreign } {
    const data = Io.Dir.cwd().readFileAlloc(io_global, path, gpa_global, .limited(16 << 20)) catch |e| switch (e) {
        error.FileNotFound => return .none,
        error.StreamTooLong => return .foreign, // far larger than our loaders
        else => return e,
    };
    defer gpa_global.free(data);
    return if (plan.isDkliloLoader(data)) .dklilo else .foreign;
}

fn installUefi(args: []const [:0]const u8) !u8 {
    var esp: ?[]const u8 = null;
    var removable = false;
    var force = false;
    var yes = false;
    var entry_file: ?[]const u8 = null;
    var device: ?[]const u8 = null;
    var arch = arch_mod.native();
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (std.mem.eql(u8, a, "--arch") and i + 1 < args.len) {
            i += 1;
            arch = parseArch(args[i]) orelse return 2;
        } else if (std.mem.eql(u8, a, "--removable")) {
            removable = true;
        } else if (std.mem.eql(u8, a, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, a, "--yes")) {
            yes = true;
        } else if (std.mem.eql(u8, a, "--entry-file") and i + 1 < args.len) {
            i += 1;
            entry_file = args[i];
        } else if (std.mem.eql(u8, a, "--device") and i + 1 < args.len) {
            i += 1;
            device = args[i];
        } else if (std.mem.eql(u8, a, "--mountinfo") and i + 1 < args.len) {
            i += 1;
            mountinfo_override = args[i];
        } else if (esp == null and !isOption(a)) {
            esp = a;
        } else return usage();
    }
    const esp_dir = esp orelse return usage();

    const efi_image = efiImage(arch);
    var name_buf: [64]u8 = undefined;
    var rel_buf: [96]u8 = undefined;
    const installed = arch_mod.installedName(&name_buf, arch);
    const target_rel: []const u8 = if (removable)
        std.fmt.bufPrint(&rel_buf, "EFI/BOOT/{s}", .{arch_mod.fallbackName(&name_buf, arch)}) catch unreachable
    else
        std.fmt.bufPrint(&rel_buf, "EFI/dklilo/{s}", .{installed}) catch unreachable;

    // The fallback path is shared: whatever else boots this medium may be
    // there. (EFI/dklilo/ is our own directory.)
    var replacing: []const u8 = "";
    if (removable) {
        const full = try std.fs.path.join(gpa_global, &.{ esp_dir, target_rel });
        defer gpa_global.free(full);
        switch (existingLoader(full) catch |e| {
            err("dklilo: cannot read the existing {s}: {s}\n", .{ full, @errorName(e) });
            return 1;
        }) {
            .none => {},
            .dklilo => replacing = "  replacing the dklilo loader that is there\n",
            .foreign => if (force) {
                replacing = "  note: replacing a boot loader that is NOT dklilo (--force)\n";
            } else {
                err("dklilo: {s} exists and is not a dklilo loader; another system may need it.\n  Refusing to replace it. Repeat with --force if you are sure.\n", .{full});
                return 1;
            },
        }
    }

    // The boot entry (not needed for removable media).
    var load_option_buf: [512]u8 = undefined;
    var load_option: ?[]u8 = null;
    var entry_note: []const u8 = "";
    if (!removable) {
        const dev_path = device orelse blk: {
            const mount = mountOf(canonical(esp_dir)) orelse {
                err("dklilo: cannot tell which partition {s} is on; pass --device /dev/...\n", .{esp_dir});
                return 1;
            };
            // An ESP is FAT. Anything else here usually means that the ESP is
            // not mounted, and the directory is on the root filesystem.
            if (!std.mem.eql(u8, mount.fstype, "vfat") and !std.mem.eql(u8, mount.fstype, "msdos")) {
                err("dklilo: {s} is on a {s} filesystem mounted at {s}, not on a FAT partition.\n  Is the EFI System Partition mounted? (--device names it otherwise.)\n", .{ esp_dir, mount.fstype, mount.point });
                return 1;
            }
            break :blk mount.device() orelse {
                err("dklilo: cannot tell which partition {s} is on; pass --device /dev/...\n", .{esp_dir});
                return 1;
            };
        };
        const sp = (findPartition(dev_path) catch |e| {
            err("dklilo: cannot look up {s}: {s}\n", .{ dev_path, @errorName(e) });
            return 1;
        }) orelse {
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
            const is_esp = if (table.kind == .gpt) std.mem.eql(u8, &p.type_guid, &esp_type_guid) else p.mbr_type == 0xEF;
            if (!is_esp) entry_note = "  warning: that partition's type is not EFI System Partition; the firmware may not boot from it\n";
        };
        const pi = info orelse {
            err("dklilo: partition {d} not found on {s}\n", .{ sp.number, sp.disk });
            return 1;
        };
        var loader_path_buf: [96]u8 = undefined;
        const loader_path = std.fmt.bufPrint(&loader_path_buf, "\\EFI\\dklilo\\{s}", .{installed}) catch unreachable;
        load_option = plan.buildLoadOption(&load_option_buf, "dklilo", pi, loader_path);
        entry_note = try std.fmt.allocPrint(arena_global, "  boot entry: partition {d} of {s}, {s}\n{s}", .{ pi.number, sp.disk, loader_path, entry_note });
    }
    out("Installing the {s} UEFI boot loader into {s}:\n  copy {d} bytes to {s}/{s}\n{s}{s}", .{ arch.tag(), esp_dir, efi_image.len, esp_dir, target_rel, replacing, entry_note });
    if (load_option != null) {
        if (entry_file) |f| out("  write the EFI_LOAD_OPTION to {s}\n", .{f}) else out("  create a Boot#### variable and put it first in BootOrder (efivarfs)\n", .{});
    }
    if (!confirm(yes)) {
        out("Aborted; nothing was written.\n", .{});
        return 1;
    }

    // Copy the loader.
    // `iterate` for a real descriptor: `syncfs` refuses a path-only one.
    var dir = Io.Dir.cwd().openDir(io_global, esp_dir, .{ .iterate = true }) catch |e| {
        err("dklilo: cannot open {s}: {s}\n", .{ esp_dir, @errorName(e) });
        return 1;
    };
    defer dir.close(io_global);
    writeLoader(dir, target_rel, efi_image) catch |e| {
        err("dklilo: cannot write {s}/{s}: {s}\n  A loader that was there before is unchanged.\n", .{ esp_dir, target_rel, @errorName(e) });
        return 1;
    };
    // The new name and the directories, as well as the contents, before
    // anything (BootOrder, for one) comes to depend on them.
    const synced = std.os.linux.errno(std.os.linux.syncfs(dir.handle));
    if (synced != .SUCCESS) {
        err("dklilo: {s}/{s} is written, but may not have reached the disk: {t}\n", .{ esp_dir, target_rel, synced });
        return 1;
    }

    if (load_option) |lo| {
        if (entry_file) |f| {
            try Io.Dir.cwd().writeFile(io_global, .{ .sub_path = f, .data = lo });
        } else {
            createBootEntry(lo) catch |e| {
                err("dklilo: the loader is installed, but creating the boot entry failed: {s}\n  (is efivarfs mounted at {s}? you can use --entry-file)\n", .{ @errorName(e), efivars });
                return 1;
            };
        }
    }
    out("Done.\n", .{});
    return 0;
}

/// The GPT type of an EFI System Partition, in on-disk byte order.
const esp_type_guid = [16]u8{ 0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11, 0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B };

/// Replaces the loader, leaving the old one in place unless the new one is
/// complete.
fn writeLoader(dir: Io.Dir, path: []const u8, image: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(io_global, parent);
    try safefile.write(io_global, dir, path, image, true);
}

fn createBootEntry(load_option: []const u8) !void {
    var dir = try Io.Dir.cwd().openDir(io_global, efivars, .{ .iterate = true });
    defer dir.close(io_global);
    const number = try bootvars.install(io_global, gpa_global, dir, load_option);
    out("  boot entry Boot{X:0>4} created\n", .{number});
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
        } else if (std.mem.eql(u8, a, "--mountinfo") and i + 1 < args.len) {
            i += 1;
            mountinfo_override = args[i];
        } else if (conf_path == null and !isOption(a)) conf_path = a else return usage();
    }

    var disks: Disks = .{};
    defer disks.deinit();
    var set = common.volumes.Set.init(gpa_global);
    defer set.deinit();

    // Where do the files live? With --device, in that disk's filesystems (and
    // the config is found the way the boot loader finds it). Otherwise the
    // config is a host file and its filesystem's device is looked up.
    var text: []u8 = undefined;
    var default_vol: *common.volumes.Volume = undefined;
    // The partition of the first disk holding the config; null for all of it.
    var partition_number: ?u32 = null;

    if (device) |dp| {
        _ = disks.add(&set, dp) catch |e| {
            err("dklilo: cannot open {s}: {s}\n", .{ dp, @errorName(e) });
            return 1;
        };
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
        const mount = mountOf(canonical(path));
        const src = (if (mount) |m| m.device() else null) orelse {
            err("dklilo: cannot tell which device holds {s}; use --device\n", .{path});
            gpa_global.free(text);
            return 1;
        };
        // The disk is read underneath the mounted filesystem: write out what
        // is still only in memory.
        std.os.linux.sync();
        // Add the whole disk when it can be opened, so that PARTUUID= works.
        var added = false;
        if (blockDeviceNumber(src) != null) {
            if (findPartition(src) catch null) |p| {
                if (disks.add(&set, p.disk)) |_| {
                    partition_number = p.number;
                    added = true;
                } else |_| {}
            }
        }
        if (!added) _ = disks.add(&set, src) catch |e| {
            err("dklilo: cannot open {s}: {s}\n", .{ src, @errorName(e) });
            gpa_global.free(text);
            return 1;
        };
    }
    defer gpa_global.free(text);

    var diag = common.config.Diagnostic{};
    var cfg = common.config.parse(gpa_global, text, &diag) catch |e| {
        err("dklilo: config line {d}: {s}\n", .{ diag.line, @errorName(e) });
        return 1;
    };
    defer cfg.deinit();
    if (cfg.entries.len == 0) {
        out("no entries: the loader will ask for a kernel and command line\n", .{});
        return 0;
    }
    out("{d} entries, labels unique, default '{s}'\n", .{ cfg.entries.len, cfg.entries[cfg.defaultIndex()].label });

    if (device == null) {
        // LABEL=, UUID= and PARTUUID= may name another disk.
        if (usesVolumePrefix(cfg)) disks.addLocal(&set);
        // Only now that no more volumes are added does a pointer to one last.
        default_vol = for (set.vols.items) |*v| {
            if (v.disk == 0 and (partition_number == null or v.number == partition_number.?)) break v;
        } else {
            err("dklilo: cannot find the filesystem that holds the configuration\n", .{});
            return 1;
        };
    }

    // A mounted filesystem always looks like this; an unmounted one shouldn't.
    if (device != null) if (default_vol.filesystem(gpa_global)) |fs| {
        if (fs.needsRecovery()) out("warn: the configuration's filesystem was not unmounted cleanly; the loader may see older files\n", .{});
    };

    if (device == null) {
        // LABEL=, UUID= and PARTUUID= may name another disk.
        if (usesVolumePrefix(cfg)) disks.addLocal(&set);
        // Only now that no more volumes are added does a pointer to one last.
        default_vol = for (set.vols.items) |*v| {
            if (v.disk == 0 and (partition_number == null or v.number == partition_number.?)) break v;
        } else {
            err("dklilo: cannot find the filesystem that holds the configuration\n", .{});
            return 1;
        };
    }

    for (diag.warningSlice()) |w| switch (w.kind) {
        .repeated => out("warn: line {d}: '{s}' is given again; the last one counts\n", .{ w.line, w.key }),
        .ignored_value => out("warn: line {d}: part of the value of '{s}' is ignored\n", .{ w.line, w.key }),
    };
    var problems: u32 = 0;
    if (!cfg.passwordUsable()) {
        err("FAIL: password is not a SHA-256 hash in hexadecimal: nobody can ever match it\n", .{});
        problems += 1;
    }
    var any_restricted = false;
    for (cfg.entries) |e| if (e.restricted) {
        any_restricted = true;
        if (cfg.password == null) out("warn: {s}: 'restricted' without a 'password' protects nothing\n", .{e.label});
    };
    if (cfg.password != null and !any_restricted) {
        out("warn: password: no entry is 'restricted', so entries can be booted and edited without it\n", .{});
    }
    for (cfg.entries) |e| {
        // One byte more than the loaders have room for shows what doesn't fit.
        var cmdline: [common.menu.max_cmdline + 1]u8 = undefined;
        if (common.menu.buildCmdline(e, &cmdline).len > common.menu.max_cmdline) {
            err("FAIL: {s}: the command line is longer than {d} bytes and would be cut off\n", .{ e.label, common.menu.max_cmdline });
            problems += 1;
        }
        if (e.kind == .chain) {
            problems += checkChain(&set, default_vol, &disks, device == null, e.label, e.target);
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
        problems += checkFile(&set, vol, e.label, .image, e.target, sub);
        for (e.initrds) |ir| problems += checkFile(&set, vol, e.label, .initrd, ir, sub);
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

/// Checks an `other =` target as far as it can be: returns the number of
/// problems. `live` means the config is on this machine, so that a `/dev` name
/// can be looked up.
fn checkChain(
    set: *common.volumes.Set,
    config_vol: *common.volumes.Volume,
    disks: *const Disks,
    live: bool,
    label: []const u8,
    target: []const u8,
) u32 {
    if (std.mem.eql(u8, target, "windows")) {
        const bios = set.findWindowsBoot(config_vol.disk) != null;
        if (bios or onSomeFat(set, "/EFI/Microsoft/Boot/bootmgfw.efi")) {
            out("ok:   {s}: chainload Windows\n", .{label});
        } else out("warn: {s}: no Windows found on the disks looked at\n", .{label});
        return 0;
    }
    if (common.config.chainPartition(target)) |wanted| {
        if (set.findPartition(config_vol.disk, wanted.number) == null) {
            err("FAIL: {s}: no partition {d} on the disk the configuration is on (BIOS chainload)\n", .{ label, wanted.number });
            return 1;
        }
        if (wanted.device_name) {
            const named: ?PartitionName = if (live and blockDeviceNumber(target) != null)
                findPartition(target) catch null
            else
                null;
            if (named) |n| {
                if (!std.mem.eql(u8, n.disk, disks.list.items[config_vol.disk].path)) {
                    err("FAIL: {s}: {s} is on another disk; the BIOS loader would start partition {d} of its own\n", .{ label, target, wanted.number });
                    return 1;
                }
            } else out("warn: {s}: the disk name in {s} is not checked: BIOS starts partition {d} of its boot disk\n", .{ label, target, wanted.number });
        }
        out("ok:   {s}: chainload partition {d} (BIOS)\n", .{ label, wanted.number });
        return 0;
    }
    // Anything else is an EFI program, for the UEFI loader.
    if (onSomeFat(set, target)) {
        out("ok:   {s}: chainload {s} (UEFI)\n", .{ label, target });
    } else out("warn: {s}: {s} was not found on a FAT volume looked at\n", .{ label, target });
    return 0;
}

fn onSomeFat(set: *common.volumes.Set, path: []const u8) bool {
    for (set.vols.items) |*v| {
        const fs = v.filesystem(gpa_global) orelse continue;
        if (fs.* != .fat) continue;
        const file = fs.lookup(path) catch continue;
        if (!file.is_dir) return true;
    }
    return false;
}

fn usesVolumePrefix(cfg: common.config.Config) bool {
    for (cfg.entries) |e| {
        if (e.kind != .linux) continue;
        const specs = [_]?[]const u8{ e.target, e.iso };
        for (specs) |maybe| if (maybe) |s| if (common.config.specPath(s).len != s.len) return true;
        for (e.initrds) |s| if (common.config.specPath(s).len != s.len) return true;
    }
    return false;
}

/// Checks one file of an entry; returns the number of problems.
fn checkFile(set: *common.volumes.Set, def: *common.volumes.Volume, label: []const u8, what: enum { image, initrd }, spec: []const u8, subvol: ?[]const u8) u32 {
    var o = set.openFile(def, spec, subvol) catch |e| {
        err("FAIL: {s}: {t} {s}: {s}\n", .{ label, what, spec, @errorName(e) });
        return 1;
    };
    out("ok:   {s}: {t} {s} ({d} bytes)\n", .{ label, what, spec, o.file.size });
    if (o.file.size == 0) {
        if (what == .initrd) {
            out("warn: {s}: initrd {s} is empty\n", .{ label, spec });
            return 0;
        }
        err("FAIL: {s}: image {s} is empty\n", .{ label, spec });
        return 1;
    }
    if (what != .image) return 0;
    var head: [4096]u8 = undefined;
    const n = o.fs.readAt(&o.file, 0, &head) catch |e| {
        err("FAIL: {s}: cannot read {s}: {s}\n", .{ label, spec, @errorName(e) });
        return 1;
    };
    // A bzImage, or a program UEFI can start (every EFI stub kernel is one).
    // Other formats may exist, so this only warns.
    const bzimage = if (common.bootparams.parseKernel(head[0..n], o.file.size)) |_| true else |_| false;
    if (!bzimage and !std.mem.startsWith(u8, head[0..n], "MZ")) {
        out("warn: {s}: {s} does not look like a kernel\n", .{ label, spec });
    }
    return 0;
}

/// The disks `check` and `config` read.
const Disks = struct {
    list: std.ArrayList(Opened) = .empty,

    const Opened = struct { path: []const u8, device: *Device };

    /// Opens `path` and adds its volumes to `set`.
    fn add(self: *Disks, set: *common.volumes.Set, path: []const u8) !usize {
        const d = try arena_global.create(Device);
        d.* = try Device.open(path, false);
        errdefer d.close();
        try self.list.append(arena_global, .{ .path = try arena_global.dupe(u8, path), .device = d });
        return set.addDisk(d.blockDev());
    }

    /// Adds every other disk of this machine that can be opened.
    fn addLocal(self: *Disks, set: *common.volumes.Set) void {
        var sys = Io.Dir.cwd().openDir(io_global, "/sys/block", .{ .iterate = true }) catch return;
        defer sys.close(io_global);
        var it = sys.iterate();
        next: while (it.next(io_global) catch null) |e| {
            const skip = [_][]const u8{ "loop", "ram", "zram", "sr", "dm-", "md", "nbd", "fd" };
            for (skip) |p| if (std.mem.startsWith(u8, e.name, p)) continue :next;
            const path = std.fmt.allocPrint(arena_global, "/dev/{s}", .{e.name}) catch continue;
            for (self.list.items) |open| if (std.mem.eql(u8, open.path, path)) continue :next;
            _ = self.add(set, path) catch continue;
        }
    }

    fn deinit(self: *Disks) void {
        for (self.list.items) |d| d.device.close();
    }
};

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

/// Is there a Windows install on any local disk? On a machine started by UEFI
/// that takes Windows Boot Manager on a FAT partition; on a BIOS one, an NTFS
/// boot sector will do.
fn detectWindows() bool {
    const uefi_host = if (Io.Dir.cwd().access(io_global, "/sys/firmware/efi", .{})) |_| true else |_| false;
    var disks: Disks = .{};
    defer disks.deinit();
    var set = common.volumes.Set.init(gpa_global);
    defer set.deinit();
    disks.addLocal(&set);
    for (set.vols.items) |*v| {
        if (!uefi_host and v.number != 0 and v.hasNtfsBootSector()) return true;
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
        } else if (std.mem.eql(u8, a, "--mountinfo") and has_next) {
            i += 1;
            mountinfo_override = args[i];
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

    // Kernel paths are written as the loader will see them: from the top of
    // the filesystem (or btrfs subvolume) that holds the boot directory,
    // where the configuration belongs too.
    const abs = canonical(boot);
    const boot_mount = mountOf(abs);
    const prefix: []const u8 = if (boot_mount) |m| try m.pathOf(arena_global, abs) else std.mem.trimEnd(u8, abs, "/");

    // The system these kernels are for: the one whose /boot this is, when it
    // is mounted somewhere (a new installation), else the one running.
    var root_mount: ?mounts.Mount = null;
    if (std.mem.eql(u8, std.fs.path.basename(abs), "boot")) {
        if (std.fs.path.dirname(abs)) |parent| {
            if (mountOf(parent)) |m| if (!std.mem.eql(u8, m.point, "/")) {
                root_mount = m;
            };
        }
    }
    if (root_mount == null) root_mount = mountOf("/");
    const root_src: ?[]const u8 = if (root_mount) |m| m.device() else null;

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

    // btrfs: kernels may live in a subvolume, and the kernel must be told which
    // subvolume is the root.
    var rf_buf: [320]u8 = undefined;
    var app_buf: [512]u8 = undefined;
    const boot_sub: ?[]const u8 = if (boot_mount) |m| m.subvolume() else null;
    const root_sub: ?[]const u8 = if (root_mount) |m| m.subvolume() else null;
    if (root_sub) |rs| {
        if (std.mem.indexOf(u8, append, "rootflags=") == null) {
            const rf = std.fmt.bufPrint(&rf_buf, "rootflags=subvol={s}", .{rs}) catch "";
            append = std.fmt.bufPrint(&app_buf, "{s}{s}{s}", .{ append, if (append.len > 0) " " else "", rf }) catch append;
        }
    }
    if (boot_sub != null) {
        err("dklilo: note: {s} is in btrfs subvolume '{s}'. The loader finds dklilo.conf only in the filesystem's default\n" ++
            "        subvolume or on the ESP (\\EFI\\dklilo\\dklilo.conf); put the config there, or run\n" ++
            "        `btrfs subvolume set-default` on that subvolume.\n", .{ boot, boot_sub.? });
    }

    const windows = want_windows and detectWindows();
    var aw: Io.Writer.Allocating = .init(gpa_global);
    defer aw.deinit();
    var ucode_buf: [2][]const u8 = undefined;
    try genconfig.render(arena_global, &aw.writer, kernels, .{
        .prefix = prefix,
        .root = root_val,
        .append = append,
        .subvol = boot_sub,
        .windows = windows,
        .microcode = genconfig.findMicrocode(names.items, &ucode_buf),
    });

    // The loader must be able to parse what we wrote.
    var diag = common.config.Diagnostic{};
    var parsed = common.config.parse(gpa_global, aw.written(), &diag) catch |e| {
        err("dklilo: internal error: generated config does not parse (line {d}): {s}\n", .{ diag.line, @errorName(e) });
        return 1;
    };
    defer parsed.deinit();
    // Options given on the command line must read back as given.
    for (parsed.entries) |e| {
        if (e.kind == .linux and append.len > 0 and !std.mem.eql(u8, e.append orelse "", append)) {
            err("dklilo: --append cannot be written in a configuration as given (check its quotes)\n", .{});
            return 1;
        }
    }

    if (out_path) |op| {
        // With --force, replace what a symlink points at, not the link.
        const target = if (force) canonical(op) else op;
        safefile.write(io_global, Io.Dir.cwd(), target, aw.written(), force) catch |e| {
            if (e == error.PathAlreadyExists) {
                err("dklilo: {s} exists; use --force to overwrite it\n", .{op});
            } else {
                err("dklilo: cannot write {s}: {s}\n", .{ op, @errorName(e) });
            }
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
///   efiboot.img   FAT image holding \EFI\BOOT\BOOT<arch>.EFI
///   mbr.bin       stage 1 as the 440-byte MBR code of the hybrid ISO
fn mkisoImages(args: []const [:0]const u8) !u8 {
    var dir_arg: ?[]const u8 = null;
    var arch = arch_mod.native();
    var k: usize = 0;
    while (k < args.len) : (k += 1) {
        const a: []const u8 = args[k];
        if (std.mem.eql(u8, a, "--arch") and k + 1 < args.len) {
            k += 1;
            arch = parseArch(args[k]) orelse return 2;
        } else if (dir_arg == null and !isOption(a)) dir_arg = a else return usage();
    }
    const dir_path = dir_arg orelse return usage();
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

    var fb_buf: [64]u8 = undefined;
    const efi = fat12.buildEfiImage(gpa_global, efiImage(arch), arch_mod.fallbackName(&fb_buf, arch)) catch |e| {
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
    var path_arg: ?[:0]const u8 = null;
    var yes = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--yes")) {
            yes = true;
        } else if (path_arg == null and !isOption(a)) path_arg = a else return usage();
    }
    const path = path_arg orelse return usage();
    var dev = Device.open(path, true) catch |e| {
        err("dklilo: cannot open {s}: {s}\n", .{ path, @errorName(e) });
        return 1;
    };
    defer dev.close();

    var vd: [cd_sector]u8 = undefined;
    try dev.readAt(17 * cd_sector, &vd);
    if (vd[0] != 0 or !std.mem.eql(u8, vd[1..6], "CD001") or !std.mem.startsWith(u8, vd[7..], "EL TORITO SPECIFICATION")) {
        err("dklilo: {s} has no El Torito boot record; build it with xorriso -b ... first\n", .{path});
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
    // The length of the stage 2 in this ISO, which may be from another
    // version of dklilo: `mkiso-images` records it in the boot sector.
    var length: [2]u8 = undefined;
    try dev.readAt(@as(u64, rba) * cd_sector + 0x40, &length);
    const s2_cd_sectors = std.mem.readInt(u16, &length, .little);
    if (s2_cd_sectors == 0 or s2_cd_sectors > plan.max_stage2_sectors * 512 / cd_sector) {
        err("dklilo: {s}: eltorito.bin records an impossible stage 2 length\n", .{path});
        return 1;
    }
    var mbr_code: [plan.mbr_code_size]u8 = undefined;
    try dev.readAt(0, &mbr_code);
    if (!plan.looksLikeStage1(&mbr_code)) {
        err("dklilo: {s} does not have dklilo's boot code in its system area; build it with\n  xorriso --grub2-mbr mbr.bin\n", .{path});
        return 1;
    }
    // A file is being built; a disk is being overwritten.
    if (blockDeviceNumber(path) != null) {
        out("Writing 10 bytes of stage 1's block list to the disk {s}.\n", .{path});
        if (!confirm(yes)) {
            out("Aborted; nothing was written.\n", .{});
            return 1;
        }
    }
    const lba512: u64 = (@as(u64, rba) + 1) * 4;
    const sectors512: u16 = s2_cd_sectors * 4;
    var bl: [10]u8 = undefined;
    std.mem.writeInt(u64, bl[0..8], lba512, .little);
    std.mem.writeInt(u16, bl[8..10], sectors512, .little);
    try dev.writeAt(plan.blocklist_offset, &bl);
    dev.file.sync(io_global) catch |e| {
        err("dklilo: the change to {s} may not have been saved: {s}\n", .{ path, @errorName(e) });
        return 1;
    };
    out("stage 1 now loads stage 2 from 512-byte sector {d} ({d} sectors)\n", .{ lba512, sectors512 });
    return 0;
}

// ---- main ------------------------------------------------------------------

pub fn main(init: std.process.Init) !u8 {
    io_global = init.io;
    gpa_global = init.gpa;
    arena_global = init.arena.allocator();
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
