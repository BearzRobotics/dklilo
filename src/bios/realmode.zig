//! The only 16-bit code in stage 2: the entry point that takes the CPU from
//! real mode into 32-bit protected mode, and the trampoline that lets 32-bit
//! Zig code call BIOS interrupts.
//!
//! Stage 1 far-jumps to `_start` (0000:8000) in real mode with the boot drive
//! in dl. Everything after `pm32_entry` runs in flat 32-bit protected mode.
//! `bios_int(vec)` drops back to real mode, executes `int vec` with registers
//! taken from (and returned in) the `Regs` block at `regs_addr`, and returns.
//!
//! LLVM quirk to remember when editing: in `.code16` use explicit bytes for
//! far control transfers; `retf` assembles as the 32-bit `retfd`.
//!
//! Low memory map (also in SPEC.md):
//!   0x00500-0x06EFF  real-mode stack (grows down from 0x6F00)
//!   0x06C00          scratch: E820 / drive-parameter results
//!   0x06E00          disk address packet
//!   0x06F00          Regs block
//!   0x08000-0x87FFF  stage 2 image
//!   0x88000-0x8FFFF  32 KiB disk bounce buffer
//!   0x90000          boot_params, 0x91000 kernel command line

pub const regs_addr = 0x6F00;
pub const scratch_addr = 0x6C00;
pub const dap_addr = 0x6E00;
pub const bounce_addr = 0x88000;
pub const bounce_size = 0x8000;
pub const boot_params_addr = 0x90000;
pub const cmdline_addr = 0x91000;

/// Register file passed to and returned from a BIOS call. Segment registers
/// are not part of it: ds = es = 0 on every call, so buffers the BIOS reads or
/// writes through ds:si / es:di live below 64 KiB.
pub const Regs = extern struct {
    eax: u32 = 0,
    ebx: u32 = 0,
    ecx: u32 = 0,
    edx: u32 = 0,
    esi: u32 = 0,
    edi: u32 = 0,
    ebp: u32 = 0,
    eflags: u32 = 0,

    pub fn carry(self: Regs) bool {
        return self.eflags & 1 != 0;
    }
    pub fn ah(self: Regs) u8 {
        return @truncate(self.eax >> 8);
    }
};

extern fn bios_int(vec: u32) callconv(.c) void;
extern fn jump_kernel(entry: u32, boot_params: u32) callconv(.c) noreturn;
extern fn chain_boot_sector(drive: u32, entry: u32) callconv(.c) noreturn;
extern var boot_drive: u8;

pub fn driveNumber() u8 {
    return boot_drive;
}

/// Calls BIOS interrupt `vec` with `in` and returns the resulting registers.
pub fn int(vec: u8, in: Regs) Regs {
    const block: *Regs = @ptrFromInt(regs_addr);
    block.* = in;
    bios_int(vec);
    return block.*;
}

/// Starts a Linux kernel with the 32-bit boot protocol: interrupts off, flat
/// segments (cs = 0x10, ds/es/ss = 0x18 as the protocol requires), esi =
/// `boot_params`, ebx = ebp = edi = 0, then jump to `entry`.
pub fn startKernel(entry: u32, boot_params: u32) noreturn {
    jump_kernel(entry, boot_params);
}

/// Where a chainloaded boot sector is loaded, and where the copy of its MBR
/// partition entry goes (ds:si points there, as an MBR would leave it).
pub const boot_sector_addr = 0x7C00;
pub const part_entry_addr = 0x7BE;

/// Hands the machine to the boot sector already loaded at `boot_sector_addr`:
/// back to real mode, dl = `drive`, ds:si = the partition entry, and a jump to
/// 0000:7C00. Never returns.
pub fn chainBootSector(drive: u8) noreturn {
    chain_boot_sector(drive, part_entry_addr);
}

comptime {
    asm (
        \\ .section .text.entry, "ax"
        \\ .code16
        \\ .intel_syntax noprefix
        \\ .global _start
        \\ _start:
        \\   .byte 0xEB, 0x08       # jmp over the signature below; the installer
        \\   .ascii "DKLILOS2"      # recognises an installed stage 2 by it
        \\   cli
        \\   xor ax, ax
        \\   mov ds, ax
        \\   mov es, ax
        \\   mov ss, ax
        \\   mov sp, 0x7C00
        \\   mov [boot_drive], dl   # stage 1 passed the boot drive in dl
        \\   in al, 0x92            # "fast A20": bit 1 of system control port A
        \\   or al, 2               # (bit 0 is the reset line; keep it clear)
        \\   and al, 0xFE
        \\   out 0x92, al
        \\   lgdt [gdtr]
        \\   mov eax, cr0
        \\   or al, 1               # PE: enter protected mode
        \\   mov cr0, eax
        \\   .byte 0xEA             # far jump: flush the prefetch queue and load
        \\   .word pm32_entry, 0x10 # cs with the flat 32-bit code selector
        \\ .code32
        \\ pm32_entry:
        \\   mov ax, 0x18           # flat 4 GiB data selector
        \\   mov ds, ax
        \\   mov es, ax
        \\   mov fs, ax
        \\   mov gs, ax
        \\   mov ss, ax
        \\   mov esp, 0x1F00000     # stack: just below the 32 MiB heap
        \\   call stage2_main
        \\ 1:
        \\   hlt
        \\   jmp 1b
        \\
        \\ # void bios_int(uint32 vec): run `int vec` in real mode.
        \\ .global bios_int
        \\ bios_int:
        \\   push ebp
        \\   push ebx
        \\   push esi
        \\   push edi
        \\   mov eax, [esp + 20]    # vec (four pushes + return address)
        \\   mov [int_op + 1], al   # patch the immediate of the int below
        \\   mov [saved_esp], esp
        \\   cli
        \\   .byte 0xEA             # far jump into the 16-bit code segment (0x08)
        \\   .long pm16
        \\   .word 0x08
        \\ .code16
        \\ pm16:
        \\   mov ax, 0x20           # 16-bit data selector: loads real-mode-sized
        \\   mov ds, ax             # segment limits (64 KiB) into the hidden
        \\   mov es, ax             # descriptor caches before PE is cleared
        \\   mov fs, ax
        \\   mov gs, ax
        \\   mov ss, ax
        \\   mov eax, cr0
        \\   and eax, 0xFFFFFFFE    # clear PE
        \\   mov cr0, eax
        \\   .byte 0xEA             # far jump to load a real-mode cs
        \\   .word rm16, 0
        \\ rm16:
        \\   xor ax, ax
        \\   mov ds, ax
        \\   mov es, ax
        \\   mov fs, ax
        \\   mov gs, ax
        \\   mov ss, ax
        \\   mov sp, 0x6F00         # real-mode stack below the Regs block
        \\   lidt [rm_idtr]         # the BIOS interrupt vector table at 0
        \\   mov eax, [0x6F00]
        \\   mov ebx, [0x6F04]
        \\   mov ecx, [0x6F08]
        \\   mov edx, [0x6F0C]
        \\   mov esi, [0x6F10]
        \\   mov edi, [0x6F14]
        \\   mov ebp, [0x6F18]
        \\   sti                    # the BIOS needs interrupts (timer, keyboard)
        \\ int_op:
        \\   .byte 0xCD, 0x00       # int imm8; the immediate is patched above
        \\   cli
        \\   push eax               # re-establish ds = es = 0 in case the BIOS
        \\   xor ax, ax             # changed them
        \\   mov ds, ax
        \\   mov es, ax
        \\   pop eax
        \\   mov [0x6F00], eax
        \\   mov [0x6F04], ebx
        \\   mov [0x6F08], ecx
        \\   mov [0x6F0C], edx
        \\   mov [0x6F10], esi
        \\   mov [0x6F14], edi
        \\   mov [0x6F18], ebp
        \\   pushfd
        \\   pop eax
        \\   mov [0x6F1C], eax      # flags after the call (carry = error)
        \\   lgdt [gdtr]
        \\   mov eax, cr0
        \\   or eax, 1              # PE on again
        \\   mov cr0, eax
        \\   .byte 0x66, 0xEA       # far jump with a 32-bit offset: back to the
        \\   .long pm32_ret         # flat 32-bit code segment
        \\   .word 0x10
        \\ .code32
        \\ pm32_ret:
        \\   mov ax, 0x18
        \\   mov ds, ax
        \\   mov es, ax
        \\   mov fs, ax
        \\   mov gs, ax
        \\   mov ss, ax
        \\   mov esp, [saved_esp]
        \\   pop edi
        \\   pop esi
        \\   pop ebx
        \\   pop ebp
        \\   ret
        \\
        \\ # void jump_kernel(uint32 entry, uint32 boot_params): never returns.
        \\ .global jump_kernel
        \\ jump_kernel:
        \\   mov eax, [esp + 4]
        \\   mov esi, [esp + 8]
        \\   cli
        \\   cld
        \\   xor ebx, ebx
        \\   xor ebp, ebp
        \\   xor edi, edi
        \\   jmp eax
        \\
        \\ # void chain_boot_sector(uint32 drive, uint32 entry): to real mode,
        \\ # then jump to the boot sector at 0000:7C00. Never returns.
        \\ .global chain_boot_sector
        \\ chain_boot_sector:
        \\   mov eax, [esp + 4]
        \\   mov [0x6F20], eax      # drive and entry survive the mode switch in
        \\   mov eax, [esp + 8]     # low memory (registers are reloaded below)
        \\   mov [0x6F24], eax
        \\   cli
        \\   .byte 0xEA
        \\   .long pm16c
        \\   .word 0x08
        \\ .code16
        \\ pm16c:
        \\   mov ax, 0x20
        \\   mov ds, ax
        \\   mov es, ax
        \\   mov fs, ax
        \\   mov gs, ax
        \\   mov ss, ax
        \\   mov eax, cr0
        \\   and eax, 0xFFFFFFFE
        \\   mov cr0, eax
        \\   .byte 0xEA
        \\   .word rm16c, 0
        \\ rm16c:
        \\   xor ax, ax
        \\   mov ds, ax
        \\   mov es, ax
        \\   mov fs, ax
        \\   mov gs, ax
        \\   mov ss, ax
        \\   mov sp, 0x7C00         # the boot sector expects its stack below itself
        \\   lidt [rm_idtr]
        \\   mov dl, [0x6F20]
        \\   mov si, [0x6F24]
        \\   sti
        \\   .byte 0xEA             # jmp 0000:7C00
        \\   .word 0x7C00, 0
        \\ .code32
        \\
        \\ .align 4
        \\ saved_esp: .long 0
        \\ .global boot_drive
        \\ boot_drive: .byte 0
        \\ .align 8
        \\ gdt:
        \\   .quad 0                    # 0x00 null
        \\   .quad 0x00009A000000FFFF   # 0x08 16-bit code, base 0, limit 64 KiB
        \\   .quad 0x00CF9A000000FFFF   # 0x10 32-bit code, flat 4 GiB (__BOOT_CS)
        \\   .quad 0x00CF92000000FFFF   # 0x18 32-bit data, flat 4 GiB (__BOOT_DS)
        \\   .quad 0x000092000000FFFF   # 0x20 16-bit data, base 0, limit 64 KiB
        \\ gdtr:
        \\   .word 5 * 8 - 1
        \\   .long gdt
        \\ rm_idtr:
        \\   .word 0x3FF
        \\   .long 0
    );
}
