ENTRY(_start)
SECTIONS {
    . = 0x8000;
    .text : { *(.text.entry) *(.text*) }
    .rodata : { *(.rodata*) }
    .data : { *(.data*) }
    __bss_start = .;
    .bss : { *(.bss*) *(COMMON) }
    __bss_end = .;
    /* Real-mode code can only address the first 64 KiB: the entry, the
       trampolines and their data (all before realmode_end) must stay below. */
    ASSERT(realmode_end <= 0x10000, "real-mode code and data end above 64 KiB")
    /* 0x88000 is where the disk bounce buffer starts (SPEC.md 5.1: 512 KiB). */
    ASSERT(. <= 0x88000, "stage2 exceeds 512 KiB")
    /DISCARD/ : { *(.eh_frame*) *(.comment) *(.note*) }
}
