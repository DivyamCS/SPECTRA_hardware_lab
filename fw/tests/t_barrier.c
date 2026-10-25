/* t_barrier.c - 1,000 rounds: each core writes its round number, meets the other at the
 * barrier, then checks the other core's slot. Checksum = number of mismatches (golden 0). */
#include "spectra.h"

#define ROUNDS 1000u

static volatile uint32_t slot[2];
static volatile uint32_t errors[2];

int spectra_main(uint32_t id)
{
    uint32_t n = NCORES;
    if (id == 0u)
        RUN_START = 1u;
    barrier();
    for (uint32_t r = 1; r <= ROUNDS; r++) {
        slot[id] = r;
        barrier();
        if (n == 2u && slot[id ^ 1u] != r)
            errors[id] = errors[id] + 1u;
        barrier();                           /* nobody overwrites a slot before it is checked */
    }
    barrier();
    if (id == 0u)
        finish(errors[0] + errors[1], 0u);
    for (;;)
        ;
}
