/* t_hazard.c - runs the assembly hazard suite on core 0. Checksum = failed checks (golden 0). */
#include "spectra.h"

uint32_t hazard_suite(void);

int spectra_main(uint32_t id)
{
    if (id != 0u)
        for (;;)
            ;
    RUN_START = 1u;
    uint32_t fails = hazard_suite();
    finish(fails, 0u);
    return 0;
}
