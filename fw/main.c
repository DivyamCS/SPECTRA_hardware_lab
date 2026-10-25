/* main.c - the demo image. Both cores run spectra_main(); SW6:5 (via CONFIG) picks the program. */
#include "spectra.h"
#include "golden.h"

int spectra_main(uint32_t id)
{
    uint32_t n = NCORES, prog = CFG_PROGRAM(CONFIG), cs, gold;

    if (prog == PROG_GOL) {
        cs = gol_run(id, n);
        gold = GOLD_GOL;
    } else if (prog == PROG_MATMUL) {
        cs = matmul_run(id, n);
        gold = GOLD_MATMUL;
    } else {
        cs = mandel_run(id, n, prog == PROG_MB_INTL);
        gold = GOLD_MANDEL;
    }

    if (id == 0u)
        finish(cs, gold);          /* never returns */
    for (;;)
        ;
}
