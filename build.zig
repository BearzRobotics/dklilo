const std = @import("std");

pub fn build(b: *std.Build) void {
    // Manual pages (Markdown, read by dkman and dkde-help): share/man/manN/NAME.N.md.
    // The section N is the number in the file name.
    if (b.option(bool, "man", "Install the manual pages (default: on)") orelse true) {
        const pages = [_][]const u8{ "dklilo.1.md", "dklilo.conf.5.md" };
        for (pages) |page| {
            const stem = page[0 .. page.len - ".md".len];
            const section = stem[std.mem.lastIndexOfScalar(u8, stem, '.').? + 1 ..];
            b.getInstallStep().dependOn(&b.addInstallFileWithDir(
                b.path(b.fmt("docs/manpages/{s}", .{page})),
                .{ .custom = b.fmt("share/man/man{s}", .{section}) },
                page,
            ).step);
        }
    }

    // `zig build` installs only bin/dklilo (it embeds every boot image).
    // `zig build dev` also installs the loose images and the test fixtures
    // that tests/qemu/*.sh expect under zig-out/.
    const dev_step = b.step("dev", "Also install loose boot images and test fixtures");
    dev_step.dependOn(b.getInstallStep());

    // Everything shipped that reads disks, configurations or other untrusted
    // data keeps its safety checks: an out-of-bounds index or an overflow stops
    // with a message instead of corrupting memory. (Stage 1 and the CD boot
    // sector are assembly.)
    const shipped_mode: std.builtin.OptimizeMode = .ReleaseSafe;

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
            .optimize = shipped_mode,
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
                .optimize = shipped_mode,
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
                .optimize = shipped_mode,
                // To stay within the size limit: nothing reads unwind tables,
                // and the debug information is of no use in this image.
                .strip = true,
                .unwind_tables = .none,
                .omit_frame_pointer = true,
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
            .optimize = shipped_mode,
            .strip = true,
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
            "sh",                                                                               "-c",
            "[ \"$(wc -c < \"$1\")\" -le 524288 ] || { echo \"$2 exceeds 512 KiB\"; exit 1; }", "sh",
        });
        check.addFileArg(item.file);
        check.addArg(item.name);
        b.getInstallStep().dependOn(&check.step);
    }

    // ---- tests: filesystem and partition readers against real images ----
    // Images are written to a fixed directory in the build cache so the
    // btrfs tests (128 MiB sparse files) can read them from disk instead of
    // embedding them.
    // The images are a build output, so they live in the cache like any other
    // (wherever --cache-dir puts it) and are made again when the script changes.
    const gen = b.addSystemCommand(&.{"sh"});
    gen.addFileArg(b.path("tests/images/make-fixtures.sh"));
    const fixtures_dir = gen.addOutputDirectoryArg("dklilo-fixtures");

    // The tests run inside that directory, wherever the cache puts it.
    const test_options = b.addOptions();
    test_options.addOption([]const u8, "fixtures_dir", ".");

    const common_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/common/root.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{.{ .name = "fsread", .module = fsread }},
        }),
    });
    common_tests.root_module.addOptions("test_options", test_options);
    for ([_][]const u8{
        "manifest.txt", "manifest-fat.txt", "ext4.img", "ext4-1k.img", "ext4-64bit.img", "ext3.img",
        "ext2.img",     "ext4-inline.img",  "mbr.img",  "gpt.img",     "ext4-holes.img", "ext4-holes.bin",
    }) |name| {
        common_tests.root_module.addAnonymousImport(name, .{ .root_source_file = fixtures_dir.path(b, name) });
    }
    const test_step = b.step("test", "Run unit tests against real filesystem images");
    const run_common = b.addRunArtifact(common_tests);
    run_common.setCwd(fixtures_dir);
    test_step.dependOn(&run_common.step);

    // The BIOS loader is 32-bit, where `usize` arithmetic on values read from
    // a disk can wrap. Run the same reader tests as a 32-bit program too; an
    // x86_64 Linux host runs it directly.
    if (b.graph.host.result.cpu.arch == .x86_64 and b.graph.host.result.os.tag == .linux) {
        const tests32 = b.addTest(.{
            .name = "test32",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/common/root.zig"),
                .target = b.resolveTargetQuery(.{ .cpu_arch = .x86, .os_tag = .linux, .abi = .none }),
                .optimize = .Debug,
                .imports = &.{.{ .name = "fsread", .module = fsread }},
            }),
        });
        tests32.root_module.addOptions("test_options", test_options);
        tests32.root_module.import_table = common_tests.root_module.import_table.clone(b.allocator) catch @panic("OOM");
        const run32 = b.addRunArtifact(tests32);
        run32.skip_foreign_checks = true;
        run32.setCwd(fixtures_dir);
        test_step.dependOn(&run32.step);
    }

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

    // The same PID 1 for the other architectures' kernels (init-aa64, init-riscv64).
    for ([_]struct { arch: std.Target.Cpu.Arch, name: []const u8 }{
        .{ .arch = .aarch64, .name = "init-aa64" },
        .{ .arch = .riscv64, .name = "init-riscv64" },
    }) |t| {
        const exe = b.addExecutable(.{
            .name = t.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/initramfs/init.zig"),
                .target = b.resolveTargetQuery(.{ .cpu_arch = t.arch, .os_tag = .linux, .abi = .none }),
                .optimize = .ReleaseSmall,
                .single_threaded = true,
                .strip = true,
            }),
        });
        dev_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }
}
