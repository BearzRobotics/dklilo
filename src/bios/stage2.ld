ENTRY(_start)
SECTIONS {
    . = 0x8000;
    .text : { *(.text.entry) *(.text*) }
    .rodata : { *(.rodata*) }
    .data : { *(.data*) }
    ASSERT(. <= 0x8000 + 512 * 1024, "stage2 exceeds 512 KiB")
    /DISCARD/ : { *(.eh_frame*) *(.comment) *(.note*) }
}
