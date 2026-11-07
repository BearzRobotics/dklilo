const std = @import("std");

pub fn build(b: *std.Build) void {
    // `zig build` installs only bin/dklilo (it embeds every boot image).
    // `zig build dev` also installs the loose images and the test fixtures
    // that tests/qemu/*.sh expect under zig-out/.
    const dev_step = b.step("dev", "Also install loose boot images and test fixtures");
    dev_step.dependOn(b.getInstallStep());

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
    dev_step.dependOn(&b.addInstallFile(bin.getOutput(), "stage1.bin").step);

    // El Torito boot sector for the ISO: reads stage 2 from the next CD sector.
    const cdstub = b.addExecutable(.{
        .name = "cdstub.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bios/cdstub.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
            .single_threaded = true,
        }),
    });
    cdstub.entry = .{ .symbol_name = "_start" };
    cdstub.setLinkerScript(b.path("src/bios/cdstub.ld"));
    const cdstub_bin = b.addObjCopy(cdstub.getEmittedBin(), .{ .format = .binary });

    const fsread = b.dependency("fsread", .{}).module("fsread");
    const common = b.createModule(.{
        .root_source_file = b.path("src/common/root.zig"),
        .imports = &.{.{ .name = "fsread", .module = fsread }},
    });
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
    dev_step.dependOn(&b.addInstallFile(stage2_bin.getOutput(), "stage2.bin").step);

    // One UEFI loader per architecture. The source is architecture-neutral
    // (it talks to UEFI protocols only), so the same entry file is built for
    // each target; no per-arch source file is needed.
    const efi_targets = [_]struct { arch: std.Target.Cpu.Arch, tag: []const u8 }{
        .{ .arch = .x86_64, .tag = "X64" },
        .{ .arch = .aarch64, .tag = "AA64" },
        // 32-bit ARM UEFI is Thumb-2 only, so the Zig target is `thumb`
        // (`arm-uefi` is rejected by the COFF linker).
        .{ .arch = .thumb, .tag = "ARM" },
        // riscv64 is built differently, below.
    };
    const efi_tags = [_][]const u8{ "X64", "AA64", "ARM", "RISCV64" };
    var efi_files: [efi_tags.len]std.Build.LazyPath = undefined;
    for (efi_targets, 0..) |t, i| {
        const exe = b.addExecutable(.{
            .name = b.fmt("dklilo{s}", .{t.tag}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/uefi/main.zig"),
                .target = b.resolveTargetQuery(.{ .cpu_arch = t.arch, .os_tag = .uefi, .abi = .msvc }),
                .optimize = .ReleaseSmall,
                .imports = &.{.{ .name = "common", .module = common }},
            }),
        });
        dev_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
        efi_files[i] = exe.getEmittedBin();
    }

    // RISC-V: Zig 0.17.1's COFF linker has no riscv64 support
    // (docs/zig-uefi-targets.md), so compile to a PIC object, link a
    // position-independent ELF with lld, and re-wrap it as a PE with
    // tools/elf2efi.zig.
    {
        const obj = b.addObject(.{
            .name = "dkliloRISCV64",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/uefi/main.zig"),
                .target = b.resolveTargetQuery(.{ .cpu_arch = .riscv64, .os_tag = .uefi, .abi = .msvc }),
                .optimize = .ReleaseSmall,
                .pic = true,
                .imports = &.{.{ .name = "common", .module = common }},
            }),
        });
        obj.bundle_compiler_rt = true;
        const link = b.addSystemCommand(&.{
            b.graph.zig_exe,      "ld.lld",
            "-pie",               "-e",
            "EfiMain",            "-Bsymbolic",
            "--gc-sections",      "-z",
            "norelro",            "-z",
            "separate-code",      "-z",
            "max-page-size=4096", "-o",
        });
        const elf = link.addOutputFileArg("dkliloRISCV64.elf");
        link.addFileArg(obj.getEmittedBin());
        const tool = b.addExecutable(.{
            .name = "elf2efi",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/elf2efi.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseSafe,
            }),
        });
        const conv = b.addRunArtifact(tool);
        conv.addArg("riscv64");
        conv.addFileArg(elf);
        const riscv_efi = conv.addOutputFileArg("dkliloRISCV64.efi");
        dev_step.dependOn(&b.addInstallFile(riscv_efi, "bin/dkliloRISCV64.efi").step);
        efi_files[3] = riscv_efi;
    }

    // The installer embeds the boot images, so it is one static file.
    const installer = b.addExecutable(.{
        .name = "dklilo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/installer/main.zig"),
            // x86_64 by default; `-Dtarget=aarch64-linux-none` builds the tool for
            // a Raspberry Pi or other ARM machine. It embeds every loader either way.
            .target = b.standardTargetOptions(.{
                .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .none },
            }),
            .optimize = .ReleaseSmall,
            .imports = &.{.{ .name = "common", .module = common }},
        }),
    });
    installer.root_module.addAnonymousImport("stage1.bin", .{ .root_source_file = bin.getOutput() });
    installer.root_module.addAnonymousImport("cdstub.bin", .{ .root_source_file = cdstub_bin.getOutput() });
    installer.root_module.addAnonymousImport("stage2.bin", .{ .root_source_file = stage2_bin.getOutput() });
    for (efi_tags, efi_files) |tag, file| {
        installer.root_module.addAnonymousImport(b.fmt("dklilo{s}.efi", .{tag}), .{ .root_source_file = file });
    }
    b.installArtifact(installer);

    // Size limits from SPEC.md 5.1, enforced on every build.
    var size_checks: [efi_tags.len + 1]struct { name: []const u8, file: std.Build.LazyPath } = undefined;
    for (efi_tags, efi_files, 0..) |tag, file, i| {
        size_checks[i] = .{ .name = b.fmt("dklilo{s}.efi", .{tag}), .file = file };
    }
    size_checks[efi_tags.len] = .{ .name = "stage2.bin", .file = stage2_bin.getOutput() };
    for (size_checks) |item| {
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
            .imports = &.{.{ .name = "fsread", .module = fsread }},
        }),
    });
    common_tests.root_module.addOptions("test_options", test_options);
    common_tests.step.dependOn(&gen.step);
    for ([_][]const u8{
        "manifest.txt", "manifest-fat.txt", "ext4.img", "ext4-1k.img", "ext4-64bit.img", "ext3.img",
        "ext2.img",     "ext4-inline.img",  "mbr.img",  "gpt.img",
    }) |name| {
        const path = b.pathJoin(&.{ fixtures_dir, name });
        common_tests.root_module.addAnonymousImport(name, .{ .root_source_file = b.path(path) });
    }
    const test_step = b.step("test", "Run unit tests against real filesystem images");
    test_step.dependOn(&b.addRunArtifact(common_tests).step);

    const installer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/installer/root.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{.{ .name = "common", .module = common }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(installer_tests).step);

    // A stand-in for Windows Boot Manager (tests/fake).
    const fake_bootmgr = b.addExecutable(.{
        .name = "fake-bootmgfw",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fake/bootmgfw.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .uefi, .abi = .msvc }),
            .optimize = .ReleaseSmall,
        }),
    });
    dev_step.dependOn(&b.addInstallArtifact(fake_bootmgr, .{}).step);

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
    dev_step.dependOn(&b.addInstallArtifact(init, .{}).step);

    // The same PID 1 for AArch64 kernels (installed as init-aa64).
    const init_aa64 = b.addExecutable(.{
        .name = "init-aa64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/initramfs/init.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .none }),
            .optimize = .ReleaseSmall,
            .single_threaded = true,
            .strip = true,
        }),
    });
    dev_step.dependOn(&b.addInstallArtifact(init_aa64, .{}).step);
}
