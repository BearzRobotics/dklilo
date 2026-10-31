const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const stage1 = b.addExecutable(.{
        .name = "stage1.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bios/stage1.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
            .single_threaded = true,
        }),
    });
    stage1.entry = .{ .symbol_name = "_start" };
    stage1.setLinkerScript(b.path("src/bios/stage1.ld"));

    const bin = b.addObjCopy(stage1.getEmittedBin(), .{ .format = .binary });
    b.getInstallStep().dependOn(&b.addInstallFile(bin.getOutput(), "stage1.bin").step);

    const stage2 = b.addExecutable(.{
        .name = "stage2.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bios/stage2.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .x86,
                .os_tag = .freestanding,
                .abi = .none,
                // No SSE etc.: nothing enables it in our protected-mode setup.
                .cpu_model = .{ .explicit = &std.Target.x86.cpu.i586 },
            }),
            .optimize = .ReleaseSmall,
            .single_threaded = true,
            .red_zone = false,
            .stack_protector = false,
        }),
    });
    stage2.entry = .{ .symbol_name = "_start" };
    stage2.setLinkerScript(b.path("src/bios/stage2.ld"));
    const stage2_bin = b.addObjCopy(stage2.getEmittedBin(), .{ .format = .binary });
    b.getInstallStep().dependOn(&b.addInstallFile(stage2_bin.getOutput(), "stage2.bin").step);

    const efi = b.addExecutable(.{
        .name = "dkliloX64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/uefi/main.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .x86_64,
                .os_tag = .uefi,
                .abi = .msvc,
            }),
            .optimize = .ReleaseSmall,
        }),
    });
    b.installArtifact(efi);

    // ---- tests: filesystem and partition readers against real images ----
    const gen = b.addSystemCommand(&.{"sh"});
    gen.addFileArg(b.path("tests/images/make-fixtures.sh"));
    const fixtures = gen.addOutputDirectoryArg("fixtures");

    const common_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/common/root.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    for ([_][]const u8{
        "manifest.txt", "ext4.img",        "ext4-1k.img", "ext4-64bit.img", "ext3.img",
        "ext2.img",     "ext4-inline.img", "mbr.img",     "gpt.img",
    }) |name| {
        common_tests.root_module.addAnonymousImport(name, .{ .root_source_file = fixtures.path(b, name) });
    }
    const test_step = b.step("test", "Run unit tests against real filesystem images");
    test_step.dependOn(&b.addRunArtifact(common_tests).step);
}
