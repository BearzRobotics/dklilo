ENTRY(_start)
SECTIONS {
    . = 0x7C00;
    .text : { *(.text*) }
    .rodata : { *(.rodata*) }
    ASSERT(. <= 0x7C00 + 416, "stage1 code overlaps the block list")
    . = 0x7C00 + 416;
    .blocklist : { *(.blocklist) }
    ASSERT(. <= 0x7C00 + 440, "stage1 exceeds the 440-byte MBR code area")
    . = 0x7C00 + 510;
    .sig : { SHORT(0xAA55) }
    /DISCARD/ : { *(.eh_frame*) *(.comment) *(.note*) }
}
