//! A minimal FAT12 image writer, just enough to build the EFI boot image an
//! El Torito ISO needs: a small volume holding `EFI/BOOT/BOOT<arch>.EFI`.
//! (Reading FAT is a separate, later reader; this only creates images.)

const std = @import("std");

pub const total_sectors = 8192; // 4 MiB
const sector = 512;
const spc = 4; // sectors per cluster (2 KiB)
const reserved = 1;
const fat_sectors = 6;
const root_entries = 512;
const root_sectors = root_entries * 32 / sector;
const data_start = reserved + 2 * fat_sectors + root_sectors;
const clusters = (total_sectors - data_start) / spc;

pub const Error = error{ TooBig, OutOfMemory };

pub const Image = struct {
    bytes: []u8,
    next_cluster: u16 = 2,
    root_used: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Error!Image {
        const b = try allocator.alloc(u8, total_sectors * sector);
        @memset(b, 0);
        // Boot sector with the BIOS parameter block.
        b[0] = 0xEB;
        b[1] = 0x3C;
        b[2] = 0x90;
        @memcpy(b[3..11], "DKLILO  ");
        std.mem.writeInt(u16, b[11..13], sector, .little);
        b[13] = spc;
        std.mem.writeInt(u16, b[14..16], reserved, .little);
        b[16] = 2; // FATs
        std.mem.writeInt(u16, b[17..19], root_entries, .little);
        std.mem.writeInt(u16, b[19..21], total_sectors, .little);
        b[21] = 0xF8; // fixed disk
        std.mem.writeInt(u16, b[22..24], fat_sectors, .little);
        std.mem.writeInt(u16, b[24..26], 32, .little); // sectors/track
        std.mem.writeInt(u16, b[26..28], 2, .little); // heads
        b[36] = 0x80;
        b[38] = 0x29;
        std.mem.writeInt(u32, b[39..43], 0x444B4C49, .little); // serial
        @memcpy(b[43..54], "DKLILO     ");
        @memcpy(b[54..62], "FAT12   ");
        b[510] = 0x55;
        b[511] = 0xAA;
        var img = Image{ .bytes = b };
        img.setFat(0, 0xFF8);
        img.setFat(1, 0xFFF);
        return img;
    }

    fn setFat(self: *Image, n: usize, value: u16) void {
        for (0..2) |copy| {
            const base = (reserved + copy * fat_sectors) * sector;
            const off = base + n * 3 / 2;
            if (n % 2 == 0) {
                self.bytes[off] = @truncate(value);
                self.bytes[off + 1] = (self.bytes[off + 1] & 0xF0) | @as(u8, @truncate(value >> 8 & 0x0F));
            } else {
                self.bytes[off] = (self.bytes[off] & 0x0F) | @as(u8, @truncate(value << 4));
                self.bytes[off + 1] = @truncate(value >> 4);
            }
        }
    }

    fn clusterOffset(c: u16) usize {
        return (data_start + (@as(usize, c) - 2) * spc) * sector;
    }

    /// Allocates a chain for `len` bytes (at least one cluster) and returns
    /// its first cluster.
    fn alloc(self: *Image, len: usize) Error!u16 {
        const csize = spc * sector;
        const n = @max(1, (len + csize - 1) / csize);
        if (@as(usize, self.next_cluster) - 2 + n > clusters) return error.TooBig;
        const first = self.next_cluster;
        for (0..n) |i| {
            const c: u16 = first + @as(u16, @intCast(i));
            self.setFat(c, if (i + 1 == n) 0xFFF else c + 1);
        }
        self.next_cluster += @intCast(n);
        return first;
    }

    fn writeEntry(slot: []u8, name: *const [11]u8, attr: u8, cluster: u16, size: u32) void {
        @memcpy(slot[0..11], name);
        slot[11] = attr;
        std.mem.writeInt(u16, slot[22..24], 0, .little); // time
        std.mem.writeInt(u16, slot[24..26], 0x5A21, .little); // date: 2025-01-01
        std.mem.writeInt(u16, slot[26..28], cluster, .little);
        std.mem.writeInt(u32, slot[28..32], size, .little);
    }

    /// Reserves `n` consecutive directory slots in the root (`parent == 0`) or
    /// in the directory in cluster `parent`, and returns the first.
    fn reserveSlots(self: *Image, parent: u16, n: usize) []u8 {
        if (parent == 0) {
            const base = (reserved + 2 * fat_sectors) * sector;
            const slots = self.bytes[base + self.root_used * 32 ..][0 .. n * 32];
            self.root_used += n;
            return slots;
        }
        const base = clusterOffset(parent);
        var i: usize = 0;
        while (self.bytes[base + i * 32] != 0) i += 1; // first free slot
        return self.bytes[base + i * 32 ..][0 .. n * 32];
    }

    /// Adds an entry to the root (`parent == 0`) or to the directory in
    /// cluster `parent`.
    fn addEntry(self: *Image, parent: u16, name: *const [11]u8, attr: u8, cluster: u16, size: u32) void {
        writeEntry(self.reserveSlots(parent, 1)[0..32], name, attr, cluster, size);
    }

    /// Creates a subdirectory (with "." and "..") and returns its cluster.
    pub fn mkdir(self: *Image, parent: u16, name: *const [11]u8) Error!u16 {
        const c = try self.alloc(1);
        const base = clusterOffset(c);
        writeEntry(self.bytes[base..][0..32], ".          ", 0x10, c, 0);
        writeEntry(self.bytes[base + 32 ..][0..32], "..         ", 0x10, parent, 0);
        self.addEntry(parent, name, 0x10, c, 0);
        return c;
    }

    /// Adds a file whose name may not fit 8.3. A name that does not fit also
    /// gets VFAT long-name entries (what firmware matches against), and a
    /// generated `BASE~1.EXT` short alias. `name` is ASCII, at most 255 bytes.
    pub fn addFileNamed(self: *Image, parent: u16, name: []const u8, data: []const u8) Error!void {
        const dot = std.mem.lastIndexOfScalar(u8, name, '.');
        const base = if (dot) |d| name[0..d] else name;
        const ext = if (dot) |d| name[d + 1 ..] else "";
        if (base.len <= 8 and ext.len <= 3 and base.len > 0) {
            var short: [11]u8 = @splat(' ');
            for (base, 0..) |ch, i| short[i] = std.ascii.toUpper(ch);
            for (ext, 0..) |ch, i| short[8 + i] = std.ascii.toUpper(ch);
            return self.addFile(parent, &short, data);
        }
        if (name.len > 255) return error.TooBig;
        var short: [11]u8 = @splat(' ');
        for (0..6) |i| short[i] = if (i < base.len) std.ascii.toUpper(base[i]) else ' ';
        short[6] = '~';
        short[7] = '1';
        for (0..@min(ext.len, 3)) |i| short[8 + i] = std.ascii.toUpper(ext[i]);

        const c = try self.alloc(data.len);
        @memcpy(self.bytes[clusterOffset(c)..][0..data.len], data);
        const parts = (name.len + 12) / 13;
        const slots = self.reserveSlots(parent, parts + 1);
        var sum: u8 = 0;
        for (short) |ch| sum = ((sum >> 1) | (sum << 7)) +% ch;
        // Long-name entries come first, last part first, each holding 13
        // UCS-2 characters: terminated by 0x0000 and padded with 0xFFFF.
        for (0..parts) |k| {
            const seq = parts - k; // entry k holds part `seq`
            const e = slots[k * 32 ..][0..32];
            @memset(e, 0);
            e[0] = @as(u8, @intCast(seq)) | (if (k == 0) @as(u8, 0x40) else 0);
            e[11] = 0x0F;
            e[13] = sum;
            const offs = [13]usize{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
            for (offs, 0..) |o, j| {
                const idx = (seq - 1) * 13 + j;
                const ch: u16 = if (idx < name.len) name[idx] else if (idx == name.len) 0 else 0xFFFF;
                std.mem.writeInt(u16, e[o..][0..2], ch, .little);
            }
        }
        writeEntry(slots[parts * 32 ..][0..32], &short, 0x20, c, @intCast(data.len));
    }

    pub fn addFile(self: *Image, parent: u16, name: *const [11]u8, data: []const u8) Error!void {
        const c = try self.alloc(data.len);
        @memcpy(self.bytes[clusterOffset(c)..][0..data.len], data);
        self.addEntry(parent, name, 0x20, c, @intCast(data.len));
    }
};

/// Builds the EFI boot image: `\EFI\BOOT\<file_name>` containing `loader`.
/// `file_name` is the removable-media loader name for an architecture
/// (`BOOTX64.EFI`, `BOOTAA64.EFI`, `BOOTRISCV64.EFI`, `BOOTARM.EFI`).
pub fn buildEfiImage(allocator: std.mem.Allocator, loader: []const u8, file_name: []const u8) Error![]u8 {
    var img = try Image.init(allocator);
    errdefer allocator.free(img.bytes);
    const efi = try img.mkdir(0, "EFI        ");
    const boot = try img.mkdir(efi, "BOOT       ");
    try img.addFileNamed(boot, file_name, loader);
    return img.bytes;
}

test "the image has the right geometry and the file chain is intact" {
    const gpa = std.testing.allocator;
    var loader: [5000]u8 = undefined;
    for (&loader, 0..) |*b, i| b.* = @truncate(i * 7);
    const img = try buildEfiImage(gpa, &loader, "BOOTX64.EFI");
    defer gpa.free(img);
    try std.testing.expectEqual(@as(usize, total_sectors * sector), img.len);
    try std.testing.expect(clusters < 4085); // FAT12
    try std.testing.expectEqual(@as(u8, 0x55), img[510]);
    // Root entry "EFI" -> cluster 2.
    const root = (reserved + 2 * fat_sectors) * sector;
    try std.testing.expectEqualStrings("EFI        ", img[root..][0..11]);
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, img[root + 26 ..][0..2], .little));
    // BOOT is in EFI's directory (cluster 2, entry 2), BOOTX64.EFI in BOOT's (cluster 3).
    const efi_dir = Image.clusterOffset(2);
    try std.testing.expectEqualStrings("BOOT       ", img[efi_dir + 64 ..][0..11]);
    const boot_dir = Image.clusterOffset(3);
    try std.testing.expectEqualStrings("BOOTX64 EFI", img[boot_dir + 64 ..][0..11]);
    try std.testing.expectEqual(@as(u32, 5000), std.mem.readInt(u32, img[boot_dir + 64 + 28 ..][0..4], .little));
    // 5000 bytes = 3 clusters of 2 KiB, chained 4 -> 5 -> 6 -> end.
    const first = std.mem.readInt(u16, img[boot_dir + 64 + 26 ..][0..2], .little);
    try std.testing.expectEqual(@as(u16, 4), first);
    try std.testing.expectEqualSlices(u8, &loader, img[Image.clusterOffset(4)..][0..5000]);
    const fat = reserved * sector;
    // FAT12 entry 6 = 0xFFF (end of chain): bytes at 6*3/2 = 9 (even index).
    try std.testing.expectEqual(@as(u8, 0xFF), img[fat + 9]);
}

test "a long loader name gets VFAT entries and a short alias" {
    const gpa = std.testing.allocator;
    const img = try buildEfiImage(gpa, "x", "BOOTRISCV64.EFI");
    defer gpa.free(img);
    const dir = img[Image.clusterOffset(3) + 64 ..]; // after "." and ".."
    // 15 characters = 2 long-name entries, last part first, then the alias.
    try std.testing.expectEqual(@as(u8, 0x42), dir[0]);
    try std.testing.expectEqual(@as(u8, 0x01), dir[32]);
    try std.testing.expectEqual(@as(u8, 0x0F), dir[11]);
    try std.testing.expectEqualStrings("BOOTRI~1EFI", dir[64..][0..11]);
    var sum: u8 = 0;
    for (dir[64..][0..11]) |ch| sum = ((sum >> 1) | (sum << 7)) +% ch;
    try std.testing.expectEqual(sum, dir[13]);
    try std.testing.expectEqual(sum, dir[32 + 13]);
    // Part 1 starts "BOOTR", part 2 holds "FI", a terminator, then padding.
    try std.testing.expectEqual(@as(u8, 'B'), dir[32 + 1]);
    try std.testing.expectEqual(@as(u8, 'F'), dir[1]);
    try std.testing.expectEqual(@as(u8, 'I'), dir[3]);
    try std.testing.expectEqual(@as(u8, 0), dir[5]);
    try std.testing.expectEqual(@as(u8, 0xFF), dir[7]);
}
