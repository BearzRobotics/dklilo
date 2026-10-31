ENTRY(_start)
SECTIONS {
    . = 0x7C00;
    .text : { *(.text*) }
    /* The stub must fit in the first 2048-byte sector of eltorito.bin. */
    ASSERT(. <= 0x7C00 + 2048, "cdstub exceeds one CD sector")
    /DISCARD/ : { *(.eh_frame*) *(.comment) *(.note*) }
}
