/* spectra.h - SPECTRA hardware interface for the firmware.
 * Single source of truth on the software side; docs/PROTOCOL.md holds the same tables
 * and tools/check_maps.py fails if the two ever disagree. */
#ifndef SPECTRA_H
#define SPECTRA_H
#include <stdint.h>

/* ---------------- memory map ---------------- */
#define IMEM_BASE   0x00000000u   /* 16 KB instructions, true dual-port BRAM */
#define DMEM_BASE   0x10000000u   /* 128 KB data BRAM, cached by the shared D-cache */
#define DMEM_SIZE   0x00020000u
#define MMIO_BASE   0x20000000u   /* never cached */

#define GRID0   ((volatile uint8_t *)0x10008000u)   /* Game of Life 64x64 bytes, snooped */
#define GRID1   ((volatile uint8_t *)0x10009000u)   /* Game of Life 64x64 bytes, snooped */
#define IMAGE   ((volatile uint8_t *)0x10010000u)   /* Mandelbrot 192x144 bytes, snooped */
#define MATA    ((volatile int32_t *)0x10010000u)   /* MatMul A 32x32 (other program than IMAGE) */
#define MATB    ((volatile int32_t *)0x10014000u)   /* MatMul B 32x32 */
#define MATC    ((volatile int32_t *)0x10018000u)   /* MatMul C 32x32, snooped */

/* ---------------- MMIO registers ---------------- */
#define MMIO(off)   (*(volatile uint32_t *)(MMIO_BASE + (off)))

#define CORE_ID     MMIO(0x00)   /* R : 0 or 1 */
#define NCORES      MMIO(0x04)   /* R : 1 or 2 (DUAL switch) */
#define CONFIG      MMIO(0x08)   /* R : SW[15:0] sampled at reset */
#define BARRIER     MMIO(0x0C)   /* R : completes when every running core has issued it; returns 0 */
#define LOCK        MMIO(0x10)   /* R : test-and-set, 0 = acquired, 1 = busy.  W 0 : release */
#define RUN_START   MMIO(0x14)   /* W : clear and start all counters, send BEGIN */
#define RUN_STOP    MMIO(0x18)   /* W : freeze all counters */
#define GEN_DONE    MMIO(0x1C)   /* W : {buffer << 16 | generation}, GoL frame capture */
#define CHECKSUM    MMIO(0x20)   /* W : latch checksum, send STATS */
#define LEDS        MMIO(0x24)   /* W : LED[15:0]; LED2 is driven by hardware (decode error) */
#define SEG7        MMIO(0x28)   /* W : 0..99,999,999 shown in decimal, leading zeros blank */
#define ROW_DONE    MMIO(0x2C)   /* W : Mandelbrot row finished -> ROW packet */
#define MROW_DONE   MMIO(0x30)   /* W : MatMul row of C finished -> MROW packet */
#define CYCLES      MMIO(0x34)   /* R : run cycle counter */
#define SWITCHES    MMIO(0x38)   /* R : live SW[15:0] */
#define BUTTONS     MMIO(0x3C)   /* R : bit0 BTNL, bit1 BTNR, bit2 BTNU, bit3 BTND (debounced) */
#define SEG7_DP     MMIO(0x40)   /* W : decimal-point mask, bit n = digit n (digit 0 = rightmost) */
#define TIMER       MMIO(0x44)   /* R : clock cycles since reset, free-running (never frozen) */
#define SEG7_TXT    MMIO(0x48)   /* W : letters, nibble n = digit n (0 = the SEG7 digit; codes below) */

/* per-core counters: core k at 0x50 + 0x20*k */
#define CNT(k, off) MMIO(0x50u + 0x20u * (k) + (off))
#define C_INSTRET   0x00u
#define C_DHIT      0x04u
#define C_DMISS     0x08u
#define C_IHIT      0x0Cu
#define C_IMISS     0x10u
#define C_ARBWAIT   0x14u
#define C_BARWAIT   0x18u

#define BTN_L 1u
#define BTN_R 2u
#define BTN_U 4u
#define BTN_D 8u

/* ---------------- CONFIG / switch fields ---------------- */
#define CFG_FWD(c)      (((c) >> 0) & 1u)
#define CFG_DC(c)       (((c) >> 1) & 1u)
#define CFG_DUAL(c)     (((c) >> 2) & 1u)
#define CFG_LAT(c)      (((c) >> 3) & 3u)    /* 0..3 -> L = 5, 6, 8, 10 cycles */
#define CFG_PROGRAM(c)  (((c) >> 5) & 3u)    /* 0 GoL, 1 Mandelbrot halves, 2 Mandelbrot interleaved, 3 MatMul */
#define CFG_IC(c)       (((c) >> 7) & 1u)
#define CFG_WPOL(c)     (((c) >> 9) & 1u)    /* 0 = write-back, 1 = write-through */
#define CFG_WAYS(c)     (((c) >> 10) & 15u)  /* way mask: 0000 = all 4 */
#define CFG_DISPLAY(c)  (((c) >> 14) & 3u)   /* 7-segment counter select (read live from SWITCHES) */

#define PROG_GOL     0u
#define PROG_MB_HALF 1u
#define PROG_MB_INTL 2u
#define PROG_MATMUL  3u

/* ---------------- shared helpers (util.c) ---------------- */
static inline void barrier(void) { (void)BARRIER; }
void lock_acquire(void);
void lock_release(void);
uint32_t fnv1a(const volatile uint8_t *p, uint32_t n);
uint32_t udiv64_32(uint64_t n, uint32_t d);        /* no libgcc needed */
void finish(uint32_t checksum, uint32_t golden);   /* core 0: stop, report, then the display browser */
void display_browser(void);                        /* never returns */

/* entry point called by boot.S on both cores (deliberately not "main") */
int spectra_main(uint32_t id);

/* programs */
uint32_t gol_run(uint32_t id, uint32_t ncores);
uint32_t mandel_run(uint32_t id, uint32_t ncores, int interleaved);
uint32_t matmul_run(uint32_t id, uint32_t ncores);

#endif
