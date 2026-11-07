const std = @import("std");

pub fn build(b: *std.Build) void {
    // No target or optimize mode here: the module takes them from whichever
    // module imports it, so a bootloader build gets a freestanding reader.
    _ = b.addModule("fsread", .{
        .root_source_file = b.path("src/root.zig"),
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),
        }),
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
