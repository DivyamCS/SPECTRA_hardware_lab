/* ============================================================
 * mmio.h  —  Memory-Mapped I/O Addresses
 * ============================================================
 * All MMIO registers are 32-bit word-aligned.
 * Matches the address map agreed in the block diagram report.
 * ============================================================ */
#ifndef MMIO_H
#define MMIO_H

#include <stdint.h>

/* ---- Base addresses ---- */
#define IMEM_BASE   0x00000000UL   /* 4 KB instruction BRAM  */
#define DMEM_BASE   0x00010000UL   /* 128 KB data BRAM       */
#define MMIO_BASE   0x80000000UL   /* MMIO region start      */

/* ---- UART ---- */
#define UART_TX_DATA    (*(volatile uint32_t *)(MMIO_BASE + 0x00)) /* write byte → TX */
#define UART_TX_STATUS  (*(volatile uint32_t *)(MMIO_BASE + 0x04)) /* bit[0] = busy   */

/* ---- 7-segment display ---- */
#define SEG7_VALUE  (*(volatile uint32_t *)(MMIO_BASE + 0x10)) /* BCD word to display */

/* ---- Core identity ---- */
#define CORE_ID     (*(volatile uint32_t *)(MMIO_BASE + 0x20)) /* read → hart ID (0/1) */

/* ---- Synchronisation (lock / barrier) ---- */
#define LOCK_ADDR   (*(volatile uint32_t *)(MMIO_BASE + 0x30)) /* test-and-set spinlock */
#define BARRIER_CNT (*(volatile uint32_t *)(MMIO_BASE + 0x34)) /* barrier counter       */
#define BARRIER_REL (*(volatile uint32_t *)(MMIO_BASE + 0x38)) /* barrier release flag  */

/* ---- Performance counters ---- */
#define CYCLE_CNT   (*(volatile uint32_t *)(MMIO_BASE + 0x40)) /* cycle counter lo      */
#define INSTRET_CNT (*(volatile uint32_t *)(MMIO_BASE + 0x44)) /* retired-instr counter */

/* ---- Cache control (stretch) ---- */
#define CACHE_CTRL  (*(volatile uint32_t *)(MMIO_BASE + 0x50)) /* bit[0]=en, bit[1]=wp  */

/* ---- Helpers ---- */
static inline void uart_putc(char c) {
    while (UART_TX_STATUS & 1U);   /* wait until not busy */
    UART_TX_DATA = (uint32_t)(unsigned char)c;
}

static inline void uart_puts(const char *s) {
    while (*s) uart_putc(*s++);
}

static inline void uart_puthex(uint32_t v) {
    const char hex[] = "0123456789ABCDEF";
    uart_puts("0x");
    for (int i = 28; i >= 0; i -= 4)
        uart_putc(hex[(v >> i) & 0xF]);
}

static inline void uart_putdec(uint32_t v) {
    if (v == 0) { uart_putc('0'); return; }
    char buf[10]; int i = 0;
    while (v) { buf[i++] = '0' + (v % 10); v /= 10; }
    while (i--) uart_putc(buf[i]);
}

#endif /* MMIO_H */
