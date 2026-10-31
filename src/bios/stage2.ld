ENTRY(_start)
SECTIONS {
    . = 0x8000;
    .text : { *(.text.entry) *(.text*) }
    .rodata : { *(.rodata*) }
    .data : { *(.data*) }
    __bss_start = .;
    .bss : { *(.bss*) *(COMMON) }
    __bss_end = .;
    /* Real-mode code can only address the first 64 KiB: the entry, GDT and
       trampoline data sit first and must stay below it. */
    ASSERT(ADDR(.text) + 0x400 <= 0x10000, "entry code too large")
    /* 0x88000 is where the disk bounce buffer starts (SPEC.md 5.1: 512 KiB). */
    ASSERT(. <= 0x88000, "stage2 exceeds 512 KiB")
    /DISCARD/ : { *(.eh_frame*) *(.comment) *(.note*) }
}
