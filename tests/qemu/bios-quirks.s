# A PC option ROM that makes the BIOS behave in ways real ones may, to test the
# loader (l3-bios-hardening.sh). Assembled with one of these symbols defined:
#
#   SET_DF      int 13h returns with the direction flag set
#   NO_E820     int 15h ax=E820h fails
#   LITTLE_RAM  int 12h reports 560 KiB of conventional memory
#
# Each one only applies to calls from the loader's own code (cs = 0, at 0x8000
# or above), so that the BIOS and stage 1 are not disturbed. It prints "quirk
# installed" on COM1 when it loads.
.code16
.intel_syntax noprefix
.text
.global _start
_start:
    .byte 0x55, 0xAA, 1             # one 512-byte block
init:
    pusha
    push ds
    cld
    mov si, offset banner
    mov dx, 0x3F8
1:  .byte 0x2E, 0xAC                # lods byte ptr cs:[si]
    test al, al
    jz 2f
    out dx, al
    jmp 1b
2:  xor ax, ax
    mov ds, ax
.ifdef SET_DF
    mov eax, [0x13 * 4]
    mov cs:[old], eax
    mov word ptr [0x13 * 4], offset hook
    mov [0x13 * 4 + 2], cs
.endif
.ifdef NO_E820
    mov eax, [0x15 * 4]
    mov cs:[old], eax
    mov word ptr [0x15 * 4], offset hook
    mov [0x15 * 4 + 2], cs
.endif
.ifdef LITTLE_RAM
    mov eax, [0x12 * 4]
    mov cs:[old], eax
    mov word ptr [0x12 * 4], offset hook
    mov [0x12 * 4 + 2], cs
.endif
    pop ds
    popa
    retf

# At entry the stack holds the caller's ip, cs and flags.
hook:
.ifdef NO_E820
    cmp ax, 0xE820
    jne chain
.endif
    push bp
    mov bp, sp
    cmp word ptr [bp + 4], 0
    jne 3f
    cmp word ptr [bp + 2], 0x8000
    jb 3f
    pop bp
.ifdef SET_DF
    pushf
    .byte 0x2E, 0xFF, 0x1E          # call far cs:[old]
    .word old
    std
    retf 2                          # keep the flags as they are now
.endif
.ifdef NO_E820
    mov ah, 0x86
    stc
    retf 2
.endif
.ifdef LITTLE_RAM
    mov ax, 560
    iret
.endif
3:  pop bp
chain:
    .byte 0x2E, 0xFF, 0x2E          # jmp far cs:[old]
    .word old
old:
    .long 0
banner:
    .asciz "quirk installed\r\n"
