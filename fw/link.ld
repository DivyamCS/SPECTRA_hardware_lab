/* link.ld - SPECTRA memory map. Instructions in IMEM, everything else in the first 32 KB of DMEM. */
ENTRY(_start)

MEMORY
{
    IMEM (rx) : ORIGIN = 0x00000000, LENGTH = 16K
    DMEM (rw) : ORIGIN = 0x10000000, LENGTH = 32K
}

SECTIONS
{
    .text : { *(.text.boot) *(.text .text.*) } > IMEM
    .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > DMEM
    /* .data must stay empty: a soft reset does not reload BRAM (build.py checks this) */
    .data : { *(.data .data.* .sdata .sdata.*) } > DMEM
    .bss (NOLOAD) : ALIGN(4)
    {
        __bss_start = .;
        *(.bss .bss.* .sbss .sbss.* COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > DMEM
    /DISCARD/ : { *(.comment) *(.note*) *(.riscv.attributes) *(.eh_frame*) }
}
