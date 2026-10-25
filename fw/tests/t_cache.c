/* t_cache.c - D-cache stress. Checksum = number of wrong values read back (golden 0).
 *  1. five lines that map to the same set of the 4-way cache (1 KB apart), read and rewritten
 *     for 200 rounds: forces evictions of dirty lines every round;
 *  2. byte and half-word stores into a line that is then evicted and reloaded;
 *  3. a 16 KB sequential sweep (four times the cache), written then read back.
 * Uses 0x1001_0000..0x1001_3FFF, which only the MatMul/Mandelbrot programs use. */
#include "spectra.h"

#define AREA     ((volatile uint32_t *)0x10010000u)
#define AREA8    ((volatile uint8_t *)0x10010000u)
#define AREA16   ((volatile uint16_t *)0x10010000u)
#define WAY_SPAN 256u                     /* words: 1 KB = one way of the 4 KB 4-way cache */

static uint32_t errors;

static void expect(uint32_t got, uint32_t want)
{
    if (got != want)
        errors++;
}

int spectra_main(uint32_t id)
{
    if (id != 0u)
        for (;;)
            ;
    RUN_START = 1u;

    /* 1. five conflicting lines */
    for (uint32_t k = 0; k < 5u; k++)
        AREA[k * WAY_SPAN] = 0x01010101u * k;
    for (uint32_t r = 1; r <= 200u; r++) {
        for (uint32_t k = 0; k < 5u; k++) {
            uint32_t line = (r & 1u) ? k : 4u - k;      /* forward, then backward */
            uint32_t idx = line * WAY_SPAN;
            expect(AREA[idx], 0x01010101u * line + (r - 1u));
            AREA[idx] = AREA[idx] + 1u;
        }
    }

    /* 2. byte and half-word stores, then eviction by four other lines of the same set */
    volatile uint32_t *w = &AREA[16];
    *w = 0u;
    AREA8[64] = 0x11u;
    AREA8[65] = 0x22u;
    AREA16[33] = 0x4433u;
    for (uint32_t k = 1; k <= 4u; k++)          /* four more lines in the same set */
        AREA[16u + k * WAY_SPAN] = 0xA0000000u + k;
    expect(*w, 0x44332211u);                    /* the merged word survives eviction */
    for (uint32_t k = 1; k <= 4u; k++)
        expect(AREA[16u + k * WAY_SPAN], 0xA0000000u + k);

    /* 3. sequential sweep over 16 KB */
    for (uint32_t i = 0; i < 4096u; i++)
        AREA[i] = i * 2654435761u;
    for (uint32_t i = 0; i < 4096u; i++)
        expect(AREA[i], i * 2654435761u);

    finish(errors, 0u);
    return 0;
}
