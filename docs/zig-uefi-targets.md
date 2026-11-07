# UEFI targets in Zig 0.17.1

Status as of Zig 0.17.1 (the toolchain this project is pinned to), written so
it can be raised upstream.

The dklilo UEFI loader (`src/uefi/main.zig`) is architecture-neutral: it uses
only UEFI protocols, so the same entry file is built once per target in
`build.zig`. No per-architecture source file is needed.

| UEFI arch | Zig target | How it is built | Tested |
|---|---|---|---|
| X64 | `x86_64-uefi-msvc` | Zig's own COFF linker | boots Linux under OVMF |
| AA64 | `aarch64-uefi-msvc` | Zig's own COFF linker | boots Debian's arm64 6.1 kernel with a 2-file initramfs under AAVMF (edk2) on QEMU |
| ARM | `thumb-uefi-msvc` | Zig's own COFF linker | builds, PE machine type checked; **not run** (no 32-bit ARM edk2 firmware on the dev machine) |
| RISCV64 | `riscv64-uefi-msvc` (object) | **ELF + `tools/elf2efi.zig`** (see below) | boots Debian's riscv64 6.12 kernel with a 2-file initramfs under edk2 on QEMU `virt` |

## 32-bit ARM needs `thumb`, not `arm`

UEFI on 32-bit ARM is Thumb-2 only (UEFI specification, section 2.3.5). With
`-target arm-uefi` the compiler reports
`Function 'start.EfiMain' uses ARM instructions, but the target does not support ARM mode execution`,
and the COFF linker rejects the machine type. `-target thumb-uefi` links and
produces a PE32 file with machine type ARMNT. It is easy to miss, because the
0.17.0 release notes list `arm-uefi` under "Additional Platforms".

## RISC-V: the COFF linker has no riscv64 support

`-target riscv64-uefi` fails even for a program that does nothing:

    pub fn main() uefi.Status { return .success; }   // zig build-exe -target riscv64-uefi
    error: failed to open output binary: UnsupportedCoffArchitecture

The same happens with `-fllvm`, `-fllvm -flld`, `-fno-llvm` and the `-gnu` ABI
(checked on 0.17.1; 0.17.0 itself was not tested). Zig's bundled `lld-link`
does not know riscv64 either (`unknown /machine argument: riscv64`), and
`clang --target=riscv64-unknown-windows-coff` emits an ELF object, so LLVM
tooling cannot produce a RISC-V PE. The standard library does define
`IMAGE_FILE_MACHINE_RISCV64` (0x5064) in `std/coff.zig`; what is missing is the
linker.

Wanted: PE/COFF output for `riscv64` in Zig's COFF linker.

### The workaround dklilo uses

1. Compile `main.zig` for `riscv64-uefi` as an **object** with `-fPIC` and
   `bundle_compiler_rt` (Zig writes an ELF object for this target).
2. Link it with `zig ld.lld -pie -e EfiMain -Bsymbolic --gc-sections
   -z separate-code -z max-page-size=4096`, giving a static position-independent
   ELF whose only dynamic relocations are `R_RISCV_RELATIVE`.
3. `tools/elf2efi.zig` wraps that ELF as PE32+ (machine 0x5064, subsystem
   EFI application): one PE section per `PT_LOAD` segment, a `.reloc` table
   with one `IMAGE_REL_BASED_DIR64` entry per `R_RISCV_RELATIVE`. It refuses any
   other relocation type.

It is what gnu-efi does with `objcopy -O pei-*`, in about 200 lines of Zig.
When Zig can link riscv64 PE directly, delete the tool and make RISC-V another
row in the `efi_targets` table in `build.zig`.

Limits of what was verified: the result loads, runs and boots a Linux kernel
under edk2 on QEMU `virt` (`tests/qemu/l12-riscv-arm.sh`). It has not been run
on real hardware.

## Other notes

* The FAT image writer (`src/installer/fat12.zig`) writes VFAT long names, which
  `BOOTRISCV64.EFI` needs (its base name is longer than 8 characters). Checked by
  a unit test and by reading the image back with `mtools`.
* `thumb-uefi` and `riscv64` binaries are 125 KB and 323 KB (limit 512 KiB).
  The RISC-V one is larger mostly because compiler-rt is bundled.

## edk2 RISC-V `virt`: the device tree gets overwritten (not a Zig issue)

Observed, not fully root-caused. On edk2's RISC-V `virt` firmware the device
tree (the `EFI_DTB_TABLE_GUID` configuration table) was at `0x83ff8000`, intact
when dklilo started, and zeroed by the time dklilo started the kernel; the
kernel's EFI stub then printed `Invalid header detected on UEFI supplied FDT`
and the boot hung. Booting the kernel straight from the firmware, with no
loader in between, worked.

A debugger watchpoint (QEMU gdbstub + lldb) showed the firmware's own stack
pointer on both sides of that address, so the tree appears to sit inside the
range the firmware stack grows through, and a loader that uses more than a few
tens of KB of stack overwrites it. dklilo's fix is to copy the tree into
allocated memory and re-publish it before doing anything else
(`protectDeviceTree` in `src/uefi/main.zig`). This is worth reporting to edk2
(the `RiscVVirt` platform); I have not reported it or confirmed the layout in
the edk2 sources.
