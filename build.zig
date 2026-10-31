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

    const common = b.createModule(.{ .root_source_file = b.path("src/common/root.zig") });
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
            .imports = &.{.{ .name = "common", .module = common }},
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
            .imports = &.{.{ .name = "common", .module = common }},
        }),
    });
    b.installArtifact(efi);

    // Size limits from SPEC.md 5.1, enforced on every build.
    for ([_]struct { name: []const u8, file: std.Build.LazyPath }{
        .{ .name = "dkliloX64.efi", .file = efi.getEmittedBin() },
        .{ .name = "stage2.bin", .file = stage2_bin.getOutput() },
    }) |item| {
        const check = b.addSystemCommand(&.{
            "sh",                                                                                 "-c",
            "[ \"$(stat -c%s \"$1\")\" -le 524288 ] || { echo \"$2 exceeds 512 KiB\"; exit 1; }", "sh",
        });
        check.addFileArg(item.file);
        check.addArg(item.name);
        b.getInstallStep().dependOn(&check.step);
    }

    // ---- tests: filesystem and partition readers against real images ----
    // Images are written to a fixed directory in the build cache so the
    // btrfs tests (128 MiB sparse files) can read them from disk instead of
    // embedding them.
    const fixtures_dir = ".zig-cache/dklilo-fixtures";
    const gen = b.addSystemCommand(&.{"sh"});
    gen.addFileArg(b.path("tests/images/make-fixtures.sh"));
    gen.addArg(fixtures_dir);

    const test_options = b.addOptions();
    test_options.addOption([]const u8, "fixtures_dir", fixtures_dir);

    const common_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/common/root.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    common_tests.root_module.addOptions("test_options", test_options);
    common_tests.step.dependOn(&gen.step);
    for ([_][]const u8{
        "manifest.txt", "ext4.img",        "ext4-1k.img", "ext4-64bit.img", "ext3.img",
        "ext2.img",     "ext4-inline.img", "mbr.img",     "gpt.img",
    }) |name| {
        const path = b.pathJoin(&.{ fixtures_dir, name });
        common_tests.root_module.addAnonymousImport(name, .{ .root_source_file = b.path(path) });
    }
    const test_step = b.step("test", "Run unit tests against real filesystem images");
    test_step.dependOn(&b.addRunArtifact(common_tests).step);

    // PID 1 for the Linux boot tests (tests/initramfs).
    const init = b.addExecutable(.{
        .name = "init",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/initramfs/init.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .none }),
            .optimize = .ReleaseSmall,
            .single_threaded = true,
            .strip = true,
        }),
    });
    b.installArtifact(init);
}
