# boot.S - both cores start here at PC 0 (core 1 only when DUAL = 1).
# Core 0 stack: 0x1001_F000-0x1001_FFFF, core 1 stack: 0x1001_E000-0x1001_EFFF.
# Core 0 clears .bss, then both meet at the hardware barrier and call spectra_main(id).
# BRAM is not reloaded by a soft reset, so nothing here may rely on initialised writable data.

    .section .text.boot, "ax"
    .globl _start
_start:
    li      t0, 0x20000000          # MMIO base
    lw      t1, 0(t0)               # CORE_ID
    li      sp, 0x10020000
    slli    t2, t1, 12              # 4 KB stack per core
    sub     sp, sp, t2
    bnez    t1, 2f
    la      a0, __bss_start
    la      a1, __bss_end
1:  bgeu    a0, a1, 2f
    sw      zero, 0(a0)
    addi    a0, a0, 4
    j       1b
2:  lw      t3, 12(t0)              # BARRIER (load into t3, not x0, so it is never optimised away)
    mv      a0, t1
    call    spectra_main
3:  j       3b
