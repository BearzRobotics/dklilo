//! El Torito boot sector for the ISO. The BIOS loads the first 2048 bytes of
//! `eltorito.bin` (no-emulation) to 0x7C00 and jumps to it with the CD drive
//! in dl. `xorriso -boot-info-table` fills a table at offset 8 that includes
//! the LBA of this very file; stage 2 is stored in the file right after this
//! sector, so the stub reads it from there and jumps to it.
//!
//! Layout: 0x00 `jmp` over the table; 0x08-0x3F boot info table (xorriso);
//! 0x40 u16 stage 2 length in 2048-byte sectors (patched by `mkiso-images`);
//! 0x42 code.

comptime {
    asm (
        \\ .section .text
        \\ .code16
        \\ .intel_syntax noprefix
        \\ .global _start
        \\ _start:
        \\   .byte 0xEB, 0x40       # jmp short to 0x42, over the info table
        \\   .skip 0x3E             # 0x02-0x3F: table written by xorriso
        \\ s2_sectors: .word 0      # 0x40
        \\ entry:
        \\   cli
        \\   xor ax, ax
        \\   mov ds, ax
        \\   mov es, ax
        \\   mov ss, ax
        \\   mov sp, 0x7C00
        \\   push ax                # El Torito may enter at 07C0:0000; force cs=0
        \\   push offset resume
        \\   .byte 0xCB             # retf (LLVM would emit retfd)
        \\ resume:
        \\   sti
        \\   mov [drive], dl
        \\   mov eax, [0x7C0C]      # boot info table: LBA of this file
        \\   inc eax                # stage 2 starts in the next sector
        \\   mov [dap_lba], eax
        \\   mov cx, [s2_sectors]
        \\ 1:
        \\   test cx, cx
        \\   jz 3f
        \\   mov bx, 16             # at most 16 sectors (32 KiB) per call
        \\   cmp cx, bx
        \\   jae 2f
        \\   mov bx, cx
        \\ 2:
        \\   mov [dap_cnt], bx
        \\   mov si, offset dap
        \\   mov dl, [drive]
        \\   mov ah, 0x42           # int 13h extended read; LBAs are CD sectors
        \\   int 0x13
        \\   jc fail
        \\   sub cx, bx
        \\   movzx ebx, bx
        \\   add [dap_lba], ebx
        \\   shl bx, 7              # sectors * 2048 / 16 = paragraphs
        \\   add [dap_seg], bx
        \\   jmp 1b
        \\ 3:
        \\   mov dl, [drive]
        \\   push 0
        \\   push 0x8000
        \\   .byte 0xCB             # far jump to 0000:8000 (stage 2)
        \\ fail:
        \\   mov ax, 0x0E45         # print "E"
        \\   xor bx, bx
        \\   int 0x10
        \\ 4:
        \\   hlt
        \\   jmp 4b
        \\ drive: .byte 0
        \\ dap:
        \\   .byte 0x10, 0
        \\ dap_cnt: .word 0
        \\   .word 0
        \\ dap_seg: .word 0x0800
        \\ dap_lba: .long 0, 0
    );
}
