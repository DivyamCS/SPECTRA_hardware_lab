/* mandel.c - Mandelbrot set, 192x144, iteration count per pixel (max 64), Q4.12 fixed point.
 * Halves: core 0 rows 0..71, core 1 rows 72..143 (unbalanced on purpose).
 * Interleaved: core k takes rows k, k+2, k+4, ... (balanced).
 * After each row the core writes ROW_DONE so the streamer can send the row. */
#include "spectra.h"

#define MW 192
#define MH 144
#define MAXIT 64
#define FRAC 12
#define X0 (-8192)          /* -2.0  */
#define Y0 (-4392)          /* about -1.07 */
#define STEP 61             /* about 0.0149 */

static uint8_t pixel(int32_t cr, int32_t ci)
{
    int32_t zr = 0, zi = 0;
    uint32_t n = 0;
    while (n < MAXIT) {
        int32_t zr2 = (zr * zr) >> FRAC, zi2 = (zi * zi) >> FRAC;
        if (zr2 + zi2 > (4 << FRAC))
            break;
        zi = ((zr * zi) >> (FRAC - 1)) + ci;
        zr = zr2 - zi2 + cr;
        n++;
    }
    return (uint8_t)n;
}

static void row(uint32_t r)
{
    int32_t ci = Y0 + (int32_t)r * STEP;
    volatile uint8_t *out = IMAGE + r * MW;
    for (uint32_t c = 0; c < MW; c++)
        out[c] = pixel(X0 + (int32_t)c * STEP, ci);
    ROW_DONE = r;
}

uint32_t mandel_run(uint32_t id, uint32_t ncores, int interleaved)
{
    if (id == 0u)
        RUN_START = 1u;
    barrier();

    if (interleaved) {
        for (uint32_t r = id; r < MH; r += ncores)
            row(r);
    } else {
        uint32_t r0 = id * MH / ncores, r1 = (id + 1u) * MH / ncores;
        for (uint32_t r = r0; r < r1; r++)
            row(r);
    }

    barrier();
    if (id != 0u)
        return 0u;
    RUN_STOP = 1u;                             /* timed region ends at the last barrier */
    return fnv1a(IMAGE, MW * MH);
}
