//! Stage 1: the MBR boot code. The BIOS loads this to 0x7C00 in 16-bit real
//! mode. It reads stage 2 from disk using the one extent recorded in the
//! block list (written by the installer) and jumps to it at 0x0000:0x8000.
//!
//! Block list layout, at MBR offset 416 (see stage1.ld):
//!   u64 start LBA, u16 sector count.

comptime {
    asm (
        \\ .section .text
        \\ .code16
        \\ .intel_syntax noprefix
        \\ .global _start
        \\ _start:
        \\   cli
        \\   xor ax, ax            # flat segments: everything is offset from 0
        \\   mov ds, ax
        \\   mov es, ax
        \\   mov ss, ax
        \\   mov sp, 0x7C00        # stack grows down from below our own code
        \\   sti
        \\   push ax               # some BIOSes enter at 07C0:0000; force cs=0
        \\   push offset start2       # by far-returning to our own next instruction
        \\   .byte 0xCB            # retf. Written as a byte: LLVM encodes "retf" as retfd (66 cb)
        \\ start2:
        \\   mov [drive], dl       # BIOS passes the boot drive number in dl
        \\   mov eax, [bl_lba]     # copy the extent's start LBA into the DAP
        \\   mov [dap_lba], eax
        \\   mov eax, [bl_lba + 4]
        \\   mov [dap_lba + 4], eax
        \\   mov cx, [bl_count]    # cx = sectors still to read
        \\   test cx, cx           # an empty block list loads nothing
        \\   jz fail
        \\ 2:
        \\   test cx, cx
        \\   jz 4f
        \\   mov bx, 64            # read at most 64 sectors (32 KiB) per call;
        \\   cmp cx, bx            # some BIOSes cap the count lower than 127
        \\   jae 3f
        \\   mov bx, cx
        \\ 3:
        \\   mov byte ptr [tries], 3
        \\ read:
        \\   mov [dap_cnt], bx     # a failed read may have changed it
        \\   mov si, offset dap
        \\   mov dl, [drive]
        \\   mov ah, 0x42          # int 13h extended read (LBA)
        \\   int 0x13
        \\   jnc 6f
        \\   xor ax, ax            # reset the drive and try again
        \\   mov dl, [drive]
        \\   int 0x13
        \\   dec byte ptr [tries]
        \\   jnz read
        \\   jmp fail
        \\ 6:
        \\   sub cx, bx
        \\   movzx ebx, bx
        \\   add [dap_lba], ebx    # advance the 64-bit LBA
        \\   adc dword ptr [dap_lba + 4], 0
        \\   shl bx, 5             # sectors * 512 / 16 = paragraphs to advance
        \\   add [dap_seg], bx
        \\   jmp 2b
        \\ 4:                     # a stale block list would load something else:
        \\   cmp dword ptr [0x8002], 0x494C4B44   # stage 2 says "DKLILOS2"
        \\   jne fail
        \\   cmp dword ptr [0x8006], 0x32534F4C
        \\   jne fail
        \\   mov dl, [drive]       # stage 2 also wants the boot drive in dl
        \\   push 0
        \\   push 0x8000
        \\   .byte 0xCB            # retf: far jump to 0000:8000 (see note above)
        \\ fail:                  # say so, for a failed read to be visible
        \\   mov si, offset message
        \\ 7:
        \\   lodsb
        \\   test al, al
        \\   jz 5f
        \\   mov ah, 0x0E
        \\   xor bx, bx
        \\   int 0x10
        \\   jmp 7b
        \\ 5:
        \\   hlt
        \\   jmp 5b
        \\ message: .asciz "dklilo: cannot load stage 2"
        \\ tries: .byte 0
        \\ drive: .byte 0
        \\ dap:                    # disk address packet for int 13h ah=42h
        \\   .byte 0x10, 0
        \\ dap_cnt: .word 0
        \\   .word 0x0000          # buffer offset
        \\ dap_seg: .word 0x0800   # buffer segment: 0800:0000 = 0x8000
        \\ dap_lba: .quad 0
        \\ .section .blocklist, "a"
        \\ bl_lba: .quad 0
        \\ bl_count: .word 0
    );
}
