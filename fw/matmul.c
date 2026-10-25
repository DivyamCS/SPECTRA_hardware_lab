/* matmul.c - C = A x B, 32x32 int32, i-k-j order (B and C read row by row).
 * A and B: values 0..15 from an LCG (seed 0x5EED1234), filled through the cache before the
 * timed region, C cleared. Rows of C are split evenly between the running cores.
 * After each row of C the core writes MROW_DONE so the streamer can send it. */
#include "spectra.h"

#define N 32

static void fill(volatile int32_t *m, uint32_t *s)
{
    for (uint32_t i = 0; i < N * N; i++) {
        *s = *s * 1664525u + 1013904223u;
        m[i] = (int32_t)((*s >> 24) & 15u);
    }
}

uint32_t matmul_run(uint32_t id, uint32_t ncores)
{
    if (id == 0u) {                            /* not timed */
        uint32_t s = 0x5EED1234u;
        fill(MATA, &s);
        fill(MATB, &s);
        for (uint32_t i = 0; i < N * N; i++)
            MATC[i] = 0;
        RUN_START = 1u;
    }
    barrier();

    uint32_t r0 = id * N / ncores, r1 = (id + 1u) * N / ncores;
    for (uint32_t i = r0; i < r1; i++) {
        volatile int32_t *c = &MATC[i * N];
        for (uint32_t k = 0; k < N; k++) {
            int32_t a = MATA[i * N + k];
            const volatile int32_t *b = &MATB[k * N];
            for (uint32_t j = 0; j < N; j++)
                c[j] += a * b[j];
        }
        MROW_DONE = i;
    }

    barrier();
    if (id != 0u)
        return 0u;
    RUN_STOP = 1u;                             /* timed region ends at the last barrier */
    return fnv1a((const volatile uint8_t *)MATC, N * N * 4u);
}
