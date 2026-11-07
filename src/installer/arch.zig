//! The CPU architectures the UEFI loader is built for, and the file names UEFI
//! gives each one. The UEFI specification (section 3.5.1.1, "Removable Media
//! Boot Behavior") names the fallback loader `\EFI\BOOT\BOOT<arch>.EFI`; dklilo's
//! own copy is `\EFI\dklilo\dklilo<arch>.efi`.

const std = @import("std");
const builtin = @import("builtin");

pub const Arch = enum {
    x64,
    aa64,
    arm,
    riscv64,

    /// The suffix UEFI uses for this architecture: `X64`, `AA64`, `ARM` or `RISCV64`.
    pub fn tag(self: Arch) []const u8 {
        return switch (self) {
            .x64 => "X64",
            .aa64 => "AA64",
            .arm => "ARM",
            .riscv64 => "RISCV64",
        };
    }
};

pub const all = [_]Arch{ .x64, .aa64, .arm };

/// The architecture this tool was built for; x64 for anything unsupported
/// (the tool still runs, and `--arch` can name the target).
pub fn native() Arch {
    return switch (builtin.cpu.arch) {
        .aarch64 => .aa64,
        .arm, .thumb => .arm,
        .riscv64 => .riscv64,
        else => .x64,
    };
}

/// Accepts the UEFI names and the usual aliases, case-insensitively.
pub fn parse(s: []const u8) ?Arch {
    const names = [_]struct { []const u8, Arch }{
        .{ "x64", .x64 },   .{ "x86_64", .x64 },      .{ "amd64", .x64 },
        .{ "aa64", .aa64 }, .{ "aarch64", .aa64 },    .{ "arm64", .aa64 },
        .{ "arm", .arm },   .{ "riscv64", .riscv64 },
    };
    for (names) |n| if (std.ascii.eqlIgnoreCase(s, n[0])) return n[1];
    return null;
}

/// `dkliloX64.efi`
pub fn installedName(buf: []u8, a: Arch) []const u8 {
    return std.fmt.bufPrint(buf, "dklilo{s}.efi", .{a.tag()}) catch unreachable;
}

/// `BOOTX64.EFI`
pub fn fallbackName(buf: []u8, a: Arch) []const u8 {
    return std.fmt.bufPrint(buf, "BOOT{s}.EFI", .{a.tag()}) catch unreachable;
}

test "names and parsing" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("BOOTAA64.EFI", fallbackName(&b, .aa64));
    try std.testing.expectEqualStrings("dkliloX64.efi", installedName(&b, .x64));
    try std.testing.expectEqual(Arch.aa64, parse("ARM64").?);
    try std.testing.expectEqual(@as(?Arch, null), parse("mips"));
}
