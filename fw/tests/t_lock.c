/* t_lock.c - each running core adds 1 to a shared counter 10,000 times under LOCK.
 * Expected: 10,000 x NCORES. A broken lock (or a lost update in the cache/arbiter) gives less. */
#include "spectra.h"

#define ROUNDS 10000u

static volatile uint32_t counter;   /* .bss, cleared by boot.S */

int spectra_main(uint32_t id)
{
    uint32_t n = NCORES;
    if (id == 0u)
        RUN_START = 1u;
    barrier();
    for (uint32_t i = 0; i < ROUNDS; i++) {
        lock_acquire();
        uint32_t v = counter;
        counter = v + 1u;
        lock_release();
    }
    barrier();
    if (id == 0u)
        finish(counter, ROUNDS * n);
    for (;;)
        ;
}
