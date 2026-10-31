//! A BIOS drive as a `BlockDev`, read with the `int 13h` extensions (LBA).

const rm = @import("realmode.zig");
const common = @import("common");

pub const Disk = struct {
    drive: u8,
    sector_size: u32 = 512,
    sector_count: u64 = 0,

    /// Queries the drive (`int 13h ah=48h`) and returns a ready `Disk`.
    pub fn open(drive: u8) ?Disk {
        var d = Disk{ .drive = drive };
        // Extension check: ah=41h bx=55AAh must come back bx=AA55h, CF clear.
        const chk = rm.int(0x13, .{ .eax = 0x4100, .ebx = 0x55AA, .edx = drive });
        if (chk.carry() or (chk.ebx & 0xFFFF) != 0xAA55) return null;

        const buf = @as([*]u8, @ptrFromInt(rm.scratch_addr))[0..0x42];
        @memset(buf, 0);
        buf[0] = 0x42; // result buffer size (EDD 3.0)
        const r = rm.int(0x13, .{ .eax = 0x4800, .edx = drive, .esi = rm.scratch_addr });
        if (!r.carry()) {
            const total = readLe(u64, buf[0x10..]);
            const bps = readLe(u16, buf[0x18..]);
            if (bps >= 512 and bps <= common.blockdev.max_sector_size) d.sector_size = bps;
            d.sector_count = if (total != 0 and total != 0xFFFFFFFFFFFFFFFF) total else 0xFFFFFFFF;
        } else {
            d.sector_count = 0xFFFFFFFF;
        }
        return d;
    }

    pub fn blockDev(self: *Disk) common.blockdev.BlockDev {
        return .{
            .ctx = self,
            .readSectorsFn = read,
            .sector_size = self.sector_size,
            .sector_count = self.sector_count,
        };
    }

    fn read(ctx: *anyopaque, lba_start: u64, buf: []u8) common.blockdev.Error!void {
        const self: *Disk = @ptrCast(@alignCast(ctx));
        const per_call = rm.bounce_size / self.sector_size;
        var lba = lba_start;
        var done: usize = 0;
        while (done < buf.len) {
            const sectors: u32 = @intCast(@min(per_call, (buf.len - done) / self.sector_size));
            try self.readChunk(lba, sectors);
            const n = sectors * self.sector_size;
            const src: [*]const u8 = @ptrFromInt(rm.bounce_addr);
            @memcpy(buf[done..][0..n], src[0..n]);
            done += n;
            lba += sectors;
        }
    }

    /// Reads up to a bounce buffer's worth of sectors into the bounce buffer.
    fn readChunk(self: *Disk, lba: u64, sectors: u32) common.blockdev.Error!void {
        const dap = @as([*]u8, @ptrFromInt(rm.dap_addr))[0..16];
        var attempt: u32 = 0;
        while (attempt < 3) : (attempt += 1) {
            dap[0] = 16;
            dap[1] = 0;
            writeLe(u16, dap[2..], @intCast(sectors));
            writeLe(u16, dap[4..], 0); // buffer offset
            writeLe(u16, dap[6..], rm.bounce_addr >> 4); // buffer segment
            writeLe(u64, dap[8..], lba);
            const r = rm.int(0x13, .{ .eax = 0x4200, .edx = self.drive, .esi = rm.dap_addr });
            if (!r.carry()) return;
            _ = rm.int(0x13, .{ .eax = 0, .edx = self.drive }); // reset and retry
        }
        return error.IoError;
    }
};

fn readLe(comptime T: type, b: []const u8) T {
    var v: T = 0;
    for (0..@sizeOf(T)) |i| v |= @as(T, b[i]) << @intCast(8 * i);
    return v;
}

fn writeLe(comptime T: type, b: []u8, v: T) void {
    for (0..@sizeOf(T)) |i| b[i] = @truncate(v >> @intCast(8 * i));
}
