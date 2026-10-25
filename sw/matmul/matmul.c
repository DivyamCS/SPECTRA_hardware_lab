/* ============================================================
 * matmul.c  —  Distributed Dual-Core Matrix Multiplication
 * ============================================================
 * Computes C = A × B  for N×N matrices stored in DMEM.
 *
 * Work split:
 *   Core 0 computes rows  [0 .. N/2 - 1]
 *   Core 1 computes rows  [N/2 .. N-1]
 *
 * Synchronisation:
 *   1. Core 0 releases core 1 via CORE1_RELEASE MMIO.
 *   2. Both cores compute their half independently.
 *   3. Core 0 waits at a barrier for core 1 to finish.
 *   4. Core 0 streams result matrix over UART.
 *
 * Matrix size: N=8  (8×8 × 4 B = 256 B each → fits in cache)
 *
 * Compile: see sw/Makefile
 * ============================================================ */

#include <stdint.h>
#include "../include/mmio.h"

#define N  8   /* matrix dimension — keep small to fit in BRAM */

/* ---- Shared matrices in DMEM ---- */
static int32_t A[N][N];
static int32_t B[N][N];
static int32_t C[N][N];   /* result */

/* ---- Barrier flag: core 1 sets this when done ---- */
static volatile uint32_t core1_done = 0;

/* ------------------------------------------------------------
 * Initialise A and B with known values (identical on both cores
 * since they share DMEM).
 * A[i][j] = i*N + j + 1   (1..64)
 * B[i][j] = (i == j) ? 2 : 0   (2× identity → C = 2A)
 * ------------------------------------------------------------ */
static void init_matrices(void) {
    for (int i = 0; i < N; i++) {
        for (int j = 0; j < N; j++) {
            A[i][j] = (int32_t)(i * N + j + 1);
            B[i][j] = (i == j) ? 2 : 0;
        }
    }
}

/* ------------------------------------------------------------
 * Compute a slice of C: rows [row_start .. row_end)
 * ------------------------------------------------------------ */
static void matmul_slice(int row_start, int row_end) {
    for (int i = row_start; i < row_end; i++) {
        for (int j = 0; j < N; j++) {
            int32_t acc = 0;
            for (int k = 0; k < N; k++)
                acc += A[i][k] * B[k][j];
            C[i][j] = acc;
        }
    }
}

/* ------------------------------------------------------------
 * Print result matrix over UART
 * ------------------------------------------------------------ */
static void print_matrix(void) {
    uart_puts("\r\nC = A x B:\r\n");
    for (int i = 0; i < N; i++) {
        for (int j = 0; j < N; j++) {
            uart_putdec((uint32_t)C[i][j]);
            uart_putc(j == N-1 ? '\n' : '\t');
        }
    }
}

/* ------------------------------------------------------------
 * Verify: since B = 2I, we expect C[i][j] = 2 * A[i][j]
 * ------------------------------------------------------------ */
static void verify(void) {
    int errors = 0;
    for (int i = 0; i < N; i++) {
        for (int j = 0; j < N; j++) {
            int32_t expected = 2 * A[i][j];
            if (C[i][j] != expected) errors++;
        }
    }
    if (errors == 0)
        uart_puts("VERIFY: PASS (C == 2*A)\r\n");
    else {
        uart_puts("VERIFY: FAIL errors=");
        uart_putdec((uint32_t)errors);
        uart_puts("\r\n");
    }
}

/* ============================================================
 * Core 0 entry point
 * ============================================================ */
void main(void) {
    uart_puts("\r\n=== MatMul N=");
    uart_putdec(N); uart_puts(" dual-core ===\r\n");

    init_matrices();

    /* Release core 1 */
    (*(volatile uint32_t *)0x8000003CUL) = 1;

    uint32_t t0 = CYCLE_CNT;

    /* Core 0 computes top half */
    matmul_slice(0, N / 2);

    /* Wait for core 1 to finish */
    while (!core1_done) { asm volatile ("nop"); }

    uint32_t elapsed = CYCLE_CNT - t0;

    print_matrix();
    verify();

    uart_puts("cycles="); uart_putdec(elapsed); uart_puts("\r\n");
    uart_puts("=== MatMul DONE ===\r\n");
}

/* ============================================================
 * Core 1 entry point
 * ============================================================ */
void core1_main(void) {
    /* Bottom half */
    matmul_slice(N / 2, N);
    /* Signal done */
    core1_done = 1;
    while (1) { asm volatile ("wfi"); }
}
