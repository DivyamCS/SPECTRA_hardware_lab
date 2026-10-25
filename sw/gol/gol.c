/* ============================================================
 * gol.c  —  Conway's Game of Life (single-core, bare-metal)
 * ============================================================
 * Grid: ROWS x COLS  (fits in 4 KB D-cache working set)
 * Double-buffered: two static arrays cur[] / nxt[]
 *
 * Purpose (from Gantt chart):
 *   - Benchmark cache hit rate on a single core.
 *   - Output generation count + live-cell count over UART
 *     so host can compare against the golden reference.
 *
 * Compile:  see sw/Makefile
 * ============================================================ */

#include <stdint.h>
#include "../include/mmio.h"

/* ---- Grid dimensions ---- */
#define ROWS  16
#define COLS  16
#define GENS  64       /* number of generations to simulate     */

/* ---- Double buffers (static → placed in DMEM by linker) ---- */
static uint8_t cur[ROWS][COLS];
static uint8_t nxt[ROWS][COLS];

/* ------------------------------------------------------------
 * Neighbour count (toroidal wrap-around)
 * ------------------------------------------------------------ */
static int neighbours(int r, int c) {
    int cnt = 0;
    for (int dr = -1; dr <= 1; dr++) {
        for (int dc = -1; dc <= 1; dc++) {
            if (dr == 0 && dc == 0) continue;
            int rr = (r + dr + ROWS) % ROWS;
            int cc = (c + dc + COLS) % COLS;
            cnt += cur[rr][cc];
        }
    }
    return cnt;
}

/* ------------------------------------------------------------
 * Step one generation
 * ------------------------------------------------------------ */
static uint32_t step(void) {
    uint32_t live = 0;
    for (int r = 0; r < ROWS; r++) {
        for (int c = 0; c < COLS; c++) {
            int n = neighbours(r, c);
            if (cur[r][c]) {
                nxt[r][c] = (n == 2 || n == 3) ? 1 : 0;
            } else {
                nxt[r][c] = (n == 3) ? 1 : 0;
            }
            live += nxt[r][c];
        }
    }
    /* swap buffers */
    for (int r = 0; r < ROWS; r++)
        for (int c = 0; c < COLS; c++)
            cur[r][c] = nxt[r][c];
    return live;
}

/* ------------------------------------------------------------
 * Glider seed  (top-left corner)
 *   . X .
 *   . . X
 *   X X X
 * ------------------------------------------------------------ */
static void seed_glider(void) {
    cur[0][1] = 1;
    cur[1][2] = 1;
    cur[2][0] = 1; cur[2][1] = 1; cur[2][2] = 1;
}

/* ------------------------------------------------------------
 * main — called from startup.s on core 0
 * ------------------------------------------------------------ */
void main(void) {
    uart_puts("\r\n=== Game of Life (" );
    uart_putdec(ROWS); uart_putc('x'); uart_putdec(COLS);
    uart_puts(", "); uart_putdec(GENS); uart_puts(" gens) ===\r\n");

    seed_glider();

    uint32_t t0_cyc = CYCLE_CNT;

    for (int g = 0; g < GENS; g++) {
        uint32_t live = step();
        uart_puts("gen="); uart_putdec(g);
        uart_puts(" live="); uart_putdec(live);
        uart_puts("\r\n");
    }

    uint32_t elapsed = CYCLE_CNT - t0_cyc;
    uart_puts("cycles="); uart_putdec(elapsed); uart_puts("\r\n");
    uart_puts("=== GOL DONE ===\r\n");
}

/* Core 1 is not used in this benchmark; provide a stub */
void core1_main(void) {
    /* park */
    while (1) { asm volatile ("wfi"); }
}
