/* ============================================================
 * startup.s  —  Dual-Core Bare-Metal RISC-V Startup
 * ============================================================
 * Supports RV32I with no OS.  Two cores are expected.
 *
 * Memory layout (matches mmio.h / linker script):
 *   0x0000_0000  IMEM (4 KB, instruction BRAM)
 *   0x0001_0000  DMEM (128 KB, data BRAM)
 *   0x8000_0000  MMIO
 *
 * Boot sequence:
 *   1. Both cores jump here after reset.
 *   2. Core 0: initialise .bss, set up stack, call main().
 *   3. Core 1: spin-wait until core 0 releases it via
 *              CORE1_RELEASE flag, then call core1_main().
 *   4. After main() returns, park the core in a WFI loop.
 * ============================================================ */

    .section .text.startup, "ax"
    .global _start
    .global _core1_entry

_start:
    /* ---- Determine hart ID ---- */
    /* MMIO_BASE + 0x20 = CORE_ID register */
    li   t0, 0x80000020
    lw   t1, 0(t0)              /* t1 = hart ID (0 or 1) */
    bnez t1, _core1_wait        /* core 1 → go wait      */

/* ===================== CORE 0 ONLY ===================== */
_core0_init:
    /* ---- Clear .bss ---- */
    la   t0, _bss_start
    la   t1, _bss_end
_bss_loop:
    bge  t0, t1, _bss_done
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    _bss_loop
_bss_done:

    /* ---- Copy .data from LMA to VMA ---- */
    la   t0, _data_lma          /* load address (in IMEM/flash)  */
    la   t1, _data_start        /* virtual address (in DMEM)     */
    la   t2, _data_end
_data_loop:
    bge  t1, t2, _data_done
    lw   t3, 0(t0)
    sw   t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    j    _data_loop
_data_done:

    /* ---- Set stack pointer for core 0 ---- */
    /* Stack grows down from top of DMEM; each core gets 4 KB */
    li   sp, 0x00018000         /* DMEM base + 32 KB – 0 = core0 top */

    /* ---- Call main() ---- */
    call main

_core0_park:
    wfi
    j    _core0_park

/* ===================== CORE 1 ONLY ===================== */
_core1_wait:
    /* Spin-poll CORE1_RELEASE flag (MMIO_BASE + 0x3C) */
    li   t0, 0x8000003C
_c1_spin:
    lw   t1, 0(t0)
    beqz t1, _c1_spin

    /* ---- Set stack pointer for core 1 (separate 4 KB region) ---- */
    li   sp, 0x00014000         /* DMEM base + 16 KB = core1 top */

    /* ---- Call core1_main() ---- */
    call core1_main

_core1_park:
    wfi
    j    _core1_park
