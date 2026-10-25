/* gol.c - Conway's Game of Life, 64x64 bytes (1 = alive), dead border, 400 generations.
 * Interior rows 1..62 are split evenly between the running cores; a hardware barrier ends
 * every generation. Core 0 then writes GEN_DONE so the streamer can send that frame.
 * tools/golden.py implements exactly the same thing in Python. */
#include "spectra.h"

#define W 64
#define H 64
#define GENS 400

static void gol_init(void)
{
    uint32_t s = 0xC0FFEE11u;
    for (uint32_t i = 0; i < W * H; i++) {
        uint32_t r = i / W, c = i % W;
        s = s * 1664525u + 1013904223u;
        uint8_t alive = (uint8_t)(((s >> 28) < 4u) && r > 0u && r < H - 1u && c > 0u && c < W - 1u);
        GRID0[i] = alive;
        GRID1[i] = 0u;
    }
}

uint32_t gol_run(uint32_t id, uint32_t ncores)
{
    if (id == 0u) {                            /* not timed */
        gol_init();
        RUN_START = 1u;
        GEN_DONE = 0u;                         /* frame 0 = the start pattern */
    }
    barrier();

    uint32_t r0 = 1u + id * (H - 2u) / ncores;
    uint32_t r1 = 1u + (id + 1u) * (H - 2u) / ncores;

    for (uint32_t g = 0; g < GENS; g++) {
        const volatile uint8_t *src = (g & 1u) ? GRID1 : GRID0;
        volatile uint8_t *dst = (g & 1u) ? GRID0 : GRID1;
        for (uint32_t r = r0; r < r1; r++) {
            const volatile uint8_t *up = src + (r - 1u) * W, *mid = src + r * W, *dn = src + (r + 1u) * W;
            volatile uint8_t *out = dst + r * W;
            for (uint32_t c = 1; c < W - 1u; c++) {
                uint32_t n = up[c - 1] + up[c] + up[c + 1] + mid[c - 1] + mid[c + 1] + dn[c - 1] + dn[c] + dn[c + 1];
                out[c] = (uint8_t)(n == 3u || (n == 2u && mid[c]));
            }
        }
        barrier();
        if (id == 0u)
            GEN_DONE = (((g + 1u) & 1u) << 16) | (g + 1u);
    }

    barrier();
    if (id != 0u)
        return 0u;
    RUN_STOP = 1u;                             /* timed region ends at the last barrier */
    return fnv1a((GENS & 1u) ? GRID1 : GRID0, W * H);
}
