//! Converts a linked RISC-V 64-bit ELF (a position-independent static
//! executable) into a PE32+ EFI application.
//!
//! Zig 0.17.1's COFF linker cannot target riscv64 (docs/zig-uefi-targets.md),
//! so for that architecture dklilo links an ELF with `ld.lld -pie` and this
//! tool re-wraps it, the way gnu-efi's `objcopy -O pei-*` step does.
//!
//! Usage: elf2efi <machine> <in.elf> <out.efi>      (machine: riscv64)
//!
//! What it does, and what it relies on:
//!  * Each PT_LOAD segment becomes one PE section (flags from p_flags).
//!    Memory beyond p_filesz (.bss) becomes VirtualSize > SizeOfRawData.
//!  * Every address is moved up by `delta` (one page) so the PE headers fit
//!    before the first segment, which the linker placed at address 0. Code is
//!    position independent, so a uniform shift is safe.
//!  * The only dynamic relocation kind accepted is R_RISCV_RELATIVE (type 3).
//!    Its addend is written into the image and the location is listed in a
//!    PE base-relocation table as IMAGE_REL_BASED_DIR64, so the firmware
//!    loader can apply the load address. Anything else is an error.
//!  * ImageBase is 0, so a stored value is just the RVA.
//!
//! References: PE Format (Microsoft), "PE32+ optional header", "Base
//! relocation table"; ELF-64 object file format; RISC-V ELF psABI
//! (R_RISCV_RELATIVE = 3); UEFI 2.10 section 2.3.6 (RISC-V binding: PE machine
//! type 0x5064).

const std = @import("std");

const delta: u64 = 0x1000;
const section_align: u32 = 0x1000;
const file_align: u32 = 0x200;

const machine_riscv64: u16 = 0x5064;

const R_RISCV_RELATIVE = 3;
const PT_LOAD = 1;
const PT_DYNAMIC = 2;
const SHT_RELA = 4;

fn rd(comptime T: type, b: []const u8, off: usize) T {
    return std.mem.readInt(T, b[off..][0..@sizeOf(T)], .little);
}

fn alignUp(v: u64, a: u64) u64 {
    return (v + a - 1) & ~(a - 1);
}

const Seg = struct { vaddr: u64, offset: u64, filesz: u64, memsz: u64, flags: u32 };

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4 or !std.mem.eql(u8, args[1], "riscv64")) {
        std.debug.print("usage: elf2efi riscv64 <in.elf> <out.efi>\n", .{});
        return 2;
    }
    const elf = try std.Io.Dir.cwd().readFileAlloc(io, args[2], gpa, .limited(64 << 20));
    defer gpa.free(elf);

    if (elf.len < 64 or !std.mem.eql(u8, elf[0..4], "\x7fELF") or elf[4] != 2 or elf[5] != 1)
        return fail("not a little-endian ELF64 file");
    if (rd(u16, elf, 18) != 243) return fail("not a RISC-V ELF (e_machine != 243)");
    if (rd(u16, elf, 16) != 3) return fail("not position independent (e_type != ET_DYN); link with -pie");
    const entry = rd(u64, elf, 24);
    const phoff = rd(u64, elf, 32);
    const shoff = rd(u64, elf, 40);
    const phentsize = rd(u16, elf, 54);
    const phnum = rd(u16, elf, 56);
    const shentsize = rd(u16, elf, 58);
    const shnum = rd(u16, elf, 60);

    var segs: std.ArrayList(Seg) = .empty;
    defer segs.deinit(gpa);
    for (0..phnum) |i| {
        const ph = phoff + i * phentsize;
        if (rd(u32, elf, ph) != PT_LOAD) continue;
        try segs.append(gpa, .{
            .flags = rd(u32, elf, ph + 4),
            .offset = rd(u64, elf, ph + 8),
            .vaddr = rd(u64, elf, ph + 16),
            .filesz = rd(u64, elf, ph + 32),
            .memsz = rd(u64, elf, ph + 40),
        });
    }
    if (segs.items.len == 0) return fail("no PT_LOAD segments");
    if (segs.items.len > 6) return fail("too many segments");

    // Image in memory (RVAs), starting after the headers.
    var image_end: u64 = 0;
    for (segs.items) |s| image_end = @max(image_end, alignUp(s.vaddr + delta + s.memsz, section_align));
    const mem = try gpa.alloc(u8, image_end);
    defer gpa.free(mem);
    @memset(mem, 0);
    for (segs.items) |s| @memcpy(mem[s.vaddr + delta ..][0..s.filesz], elf[s.offset..][0..s.filesz]);

    // Relocations: every SHT_RELA section of the ELF (.rela.dyn).
    var relocs: std.ArrayList(u64) = .empty; // RVAs of 64-bit fixups
    defer relocs.deinit(gpa);
    for (0..shnum) |i| {
        const sh = shoff + i * shentsize;
        if (rd(u32, elf, sh + 4) != SHT_RELA) continue;
        const off = rd(u64, elf, sh + 24);
        const size = rd(u64, elf, sh + 32);
        var p: u64 = 0;
        while (p + 24 <= size) : (p += 24) {
            const r_offset = rd(u64, elf, off + p);
            const r_info = rd(u64, elf, off + p + 8);
            const addend = rd(i64, elf, off + p + 16);
            if (r_info & 0xFFFF_FFFF != R_RISCV_RELATIVE or r_info >> 32 != 0)
                return fail("unsupported dynamic relocation (only R_RISCV_RELATIVE is handled)");
            const rva = r_offset + delta;
            if (rva + 8 > mem.len) return fail("relocation outside the image");
            std.mem.writeInt(u64, mem[rva..][0..8], @as(u64, @bitCast(addend)) +% delta, .little);
            try relocs.append(gpa, rva);
        }
    }
    std.mem.sort(u64, relocs.items, {}, std.sort.asc(u64));

    // Base relocation blocks: one per 4 KiB page; entries are
    // (type << 12 | offset), type 10 = IMAGE_REL_BASED_DIR64.
    var reloc: std.ArrayList(u8) = .empty;
    defer reloc.deinit(gpa);
    var i: usize = 0;
    while (i < relocs.items.len) {
        const page = relocs.items[i] & ~@as(u64, 0xFFF);
        var j = i;
        while (j < relocs.items.len and relocs.items[j] & ~@as(u64, 0xFFF) == page) j += 1;
        const count = j - i;
        const padded = count + (count & 1); // blocks are 4-byte aligned
        const block_size: u32 = @intCast(8 + padded * 2);
        try reloc.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, @intCast(page))));
        try reloc.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, block_size)));
        for (relocs.items[i..j]) |rva| {
            const e: u16 = (10 << 12) | @as(u16, @intCast(rva & 0xFFF));
            try reloc.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, e)));
        }
        if (count & 1 == 1) try reloc.appendSlice(gpa, &.{ 0, 0 }); // IMAGE_REL_BASED_ABSOLUTE pad
        i = j;
    }

    // File layout: headers, then each section's raw data, then .reloc.
    const nsec = segs.items.len + 1;
    const headers_size: u64 = alignUp(0x80 + 4 + 20 + 112 + 16 * 8 + nsec * 40, file_align);
    const out_size_estimate = headers_size + image_end + alignUp(reloc.items.len, file_align);
    const out = try gpa.alloc(u8, out_size_estimate);
    defer gpa.free(out);
    @memset(out, 0);

    // DOS header: "MZ" and e_lfanew = 0x80.
    out[0] = 'M';
    out[1] = 'Z';
    std.mem.writeInt(u32, out[0x3C..][0..4], 0x80, .little);
    var p: usize = 0x80;
    @memcpy(out[p..][0..4], "PE\x00\x00");
    p += 4;
    // COFF file header.
    std.mem.writeInt(u16, out[p..][0..2], machine_riscv64, .little);
    std.mem.writeInt(u16, out[p + 2 ..][0..2], @intCast(nsec), .little);
    std.mem.writeInt(u16, out[p + 16 ..][0..2], 112 + 16 * 8, .little); // SizeOfOptionalHeader
    std.mem.writeInt(u16, out[p + 18 ..][0..2], 0x0022, .little); // EXECUTABLE_IMAGE | LARGE_ADDRESS_AWARE
    p += 20;
    // Optional header (PE32+).
    const opt = p;
    std.mem.writeInt(u16, out[opt..][0..2], 0x20B, .little);
    std.mem.writeInt(u32, out[opt + 16 ..][0..4], @intCast(entry + delta), .little); // AddressOfEntryPoint
    std.mem.writeInt(u64, out[opt + 24 ..][0..8], 0, .little); // ImageBase
    std.mem.writeInt(u32, out[opt + 32 ..][0..4], section_align, .little);
    std.mem.writeInt(u32, out[opt + 36 ..][0..4], file_align, .little);
    const reloc_rva = image_end;
    std.mem.writeInt(u32, out[opt + 56 ..][0..4], @intCast(alignUp(reloc_rva + reloc.items.len, section_align)), .little); // SizeOfImage
    std.mem.writeInt(u32, out[opt + 60 ..][0..4], @intCast(headers_size), .little); // SizeOfHeaders
    std.mem.writeInt(u16, out[opt + 68 ..][0..2], 10, .little); // Subsystem: EFI application
    std.mem.writeInt(u32, out[opt + 108 ..][0..4], 16, .little); // NumberOfRvaAndSizes
    // Data directory 5 = base relocation table.
    std.mem.writeInt(u32, out[opt + 112 + 5 * 8 ..][0..4], @intCast(reloc_rva), .little);
    std.mem.writeInt(u32, out[opt + 112 + 5 * 8 + 4 ..][0..4], @intCast(reloc.items.len), .little);
    p += 112 + 16 * 8;

    // Section table and raw data. Sections are written in order; RVA is the
    // in-memory address, PointerToRawData is the running file offset.
    var file_off: u64 = headers_size;
    var code_size: u32 = 0;
    var init_size: u32 = 0;
    var first_code: u32 = 0;
    for (segs.items, 0..) |s, k| {
        const rva = s.vaddr + delta;
        const raw = alignUp(s.filesz, file_align);
        const sh = out[p + k * 40 ..][0..40];
        const name = if (s.flags & 1 != 0) ".text" else if (s.flags & 2 != 0) ".data" else ".rdata";
        @memcpy(sh[0..name.len], name);
        std.mem.writeInt(u32, sh[8..12], @intCast(s.memsz), .little); // VirtualSize
        std.mem.writeInt(u32, sh[12..16], @intCast(rva), .little);
        std.mem.writeInt(u32, sh[16..20], @intCast(raw), .little);
        std.mem.writeInt(u32, sh[20..24], @intCast(file_off), .little);
        var ch: u32 = 0x00000040; // initialized data
        if (s.flags & 1 != 0) ch = 0x00000020 | 0x20000000; // code | execute
        if (s.flags & 4 != 0) ch |= 0x40000000; // read
        if (s.flags & 2 != 0) ch |= 0x80000000; // write
        std.mem.writeInt(u32, sh[36..40], ch, .little);
        if (s.flags & 1 != 0) {
            code_size += @intCast(raw);
            if (first_code == 0) first_code = @intCast(rva);
        } else init_size += @intCast(raw);
        @memcpy(out[file_off..][0..s.filesz], mem[rva..][0..s.filesz]);
        file_off += raw;
    }
    {
        const sh = out[p + segs.items.len * 40 ..][0..40];
        @memcpy(sh[0..6], ".reloc");
        std.mem.writeInt(u32, sh[8..12], @intCast(reloc.items.len), .little);
        std.mem.writeInt(u32, sh[12..16], @intCast(reloc_rva), .little);
        const raw = alignUp(reloc.items.len, file_align);
        std.mem.writeInt(u32, sh[16..20], @intCast(raw), .little);
        std.mem.writeInt(u32, sh[20..24], @intCast(file_off), .little);
        std.mem.writeInt(u32, sh[36..40], 0x42000040, .little); // initialized, discardable, read
        init_size += @intCast(raw);
        @memcpy(out[file_off..][0..reloc.items.len], reloc.items);
        file_off += raw;
    }
    std.mem.writeInt(u32, out[opt + 4 ..][0..4], code_size, .little);
    std.mem.writeInt(u32, out[opt + 8 ..][0..4], init_size, .little);
    std.mem.writeInt(u32, out[opt + 20 ..][0..4], first_code, .little); // BaseOfCode

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[3], .data = out[0..file_off] });
    return 0;
}

fn fail(msg: []const u8) u8 {
    std.debug.print("elf2efi: {s}\n", .{msg});
    return 1;
}
