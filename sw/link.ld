/* ============================================================
 * link.ld  —  Linker Script for CAMEO bare-metal RISC-V
 * ============================================================
 * Memory map (matches mmio.h and Gantt chart):
 *   0x0000_0000  IMEM  4 KB  (instruction BRAM)
 *   0x0001_0000  DMEM  128 KB (data BRAM)
 *   0x8000_0000  MMIO  (peripheral registers, not allocated here)
 * ============================================================ */
ENTRY(_start)

MEMORY {
    IMEM (rx)  : ORIGIN = 0x00000000, LENGTH = 4K
    DMEM (rwx) : ORIGIN = 0x00010000, LENGTH = 128K
}

SECTIONS {

    /* ---- Startup + text ---- */
    .text : {
        *(.text.startup)    /* _start must be first word */
        *(.text .text.*)
        *(.rodata .rodata.*)
        . = ALIGN(4);
    } > IMEM

    /* Symbol used by startup.s to copy .data */
    _data_lma = LOADADDR(.data);

    /* ---- Initialised data (loaded into IMEM, copied to DMEM) ---- */
    .data : AT(_data_lma) {
        _data_start = .;
        *(.data .data.*)
        . = ALIGN(4);
        _data_end = .;
    } > DMEM

    /* ---- Zero-initialised data ---- */
    .bss : {
        _bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > DMEM

    /* ---- Stack: top of DMEM, grows downward ---- */
    /* Core 0 stack: 0x0001_8000 – 0x0001_4000  (16 KB) */
    /* Core 1 stack: 0x0001_4000 – 0x0001_0000  (16 KB) */
    /* (startup.s sets sp manually — no explicit section needed) */
}
