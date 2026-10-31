//! Stage 2 (BIOS loader), L0 skeleton. Stage 1 loads this flat binary to
//! 0x8000 and far-jumps to its first byte in 16-bit real mode with the boot
//! drive in dl. The entry code enables A20, loads a flat GDT and switches to
//! 32-bit protected mode, then calls `main32`, which prints over COM1.
//! The real-mode trampoline for BIOS calls arrives with L1/L3.

comptime {
    asm (
        \\ .section .text.entry, "ax"
        \\ .code16
        \\ .intel_syntax noprefix
        \\ .global _start
        \\ _start:
        \\   cli
        \\   xor ax, ax
        \\   mov ds, ax
        \\   mov es, ax
        \\   mov ss, ax
        \\   mov sp, 0x7C00
        \\   in al, 0x92           # "fast A20": set bit 1 of system control port A
        \\   or al, 2              # (bit 0 is the reset line; keep it clear)
        \\   and al, 0xFE
        \\   out 0x92, al
        \\   lgdt [gdtr]
        \\   mov eax, cr0
        \\   or al, 1              # PE: enter protected mode
        \\   mov cr0, eax
        \\   .byte 0xEA            # far jump to flush the prefetch queue and
        \\   .word pm32, 0x08      # load cs with the 32-bit code selector
        \\ .code32
        \\ pm32:
        \\   mov ax, 0x10          # flat 4 GiB data selector
        \\   mov ds, ax
        \\   mov es, ax
        \\   mov fs, ax
        \\   mov gs, ax
        \\   mov ss, ax
        \\   mov esp, 0x7C00
        \\   call main32
        \\ 1:
        \\   hlt
        \\   jmp 1b
        \\ .align 8
        \\ gdt:
        \\   .quad 0                    # null descriptor
        \\   .quad 0x00CF9A000000FFFF   # 0x08: 32-bit code, base 0, limit 4 GiB
        \\   .quad 0x00CF92000000FFFF   # 0x10: 32-bit data, base 0, limit 4 GiB
        \\ gdtr:
        \\   .word 3 * 8 - 1
        \\   .long gdt
    );
}

const com1: u16 = 0x3F8;

fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[v], %[p]"
        :
        : [v] "{al}" (value),
          [p] "{dx}" (port),
    );
}

fn inb(port: u16) u8 {
    return asm volatile ("inb %[p], %[v]"
        : [v] "={al}" (-> u8),
        : [p] "{dx}" (port),
    );
}

/// Programs COM1 for 115200 8N1 with FIFOs. QEMU ignores this, real UARTs don't.
fn serialInit() void {
    outb(com1 + 1, 0x00); // no interrupts
    outb(com1 + 3, 0x80); // DLAB on
    outb(com1 + 0, 0x01); // divisor 1 = 115200 baud
    outb(com1 + 1, 0x00);
    outb(com1 + 3, 0x03); // 8N1, DLAB off
    outb(com1 + 2, 0xC7); // enable and clear FIFOs
    outb(com1 + 4, 0x03); // DTR + RTS
}

fn serialWrite(s: []const u8) void {
    for (s) |c| {
        while (inb(com1 + 5) & 0x20 == 0) {} // wait for transmit-empty
        outb(com1, c);
    }
}

/// First Zig code to run: reached in 32-bit protected mode from the entry asm.
export fn main32() callconv(.c) noreturn {
    serialInit();
    serialWrite("dklilo stage2 (32-bit)\r\n");
    while (true) asm volatile ("hlt");
}
