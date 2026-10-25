/* t_mext.c - all 8 M-extension instructions on edge cases and on LCG-random operands.
 * Inline assembly forces the exact instruction (a compiler could otherwise fold or replace it).
 * Every result is folded into an FNV-style hash; tools/golden.py computes the same hash from
 * the RISC-V specification (tools/mext_ref.py). Core 0 only. */
#include "spectra.h"
#include "golden.h"

#define OP(name)                                                                 \
    static uint32_t op_##name(uint32_t a, uint32_t b)                            \
    {                                                                            \
        uint32_t r;                                                              \
        __asm__ volatile(#name " %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));        \
        return r;                                                                \
    }
OP(mul) OP(mulh) OP(mulhsu) OP(mulhu) OP(div) OP(divu) OP(rem) OP(remu)

static const uint32_t edge[] = {
    0x00000000u, 0x00000001u, 0xFFFFFFFFu, 0x00000002u, 0xFFFFFFFEu, 0x80000000u, 0x7FFFFFFFu,
    0x00007FFFu, 0x00008000u, 0x0000FFFFu, 0x00010000u, 0x00003039u, 0xFFFE7E33u,
};
#define NEDGE (sizeof(edge) / sizeof(edge[0]))
#define NRAND 1000u

static uint32_t h;
static void fold(uint32_t r)
{
    h = (h ^ r) * 0x01000193u;
}

static void all_ops(uint32_t a, uint32_t b)
{
    fold(op_mul(a, b));
    fold(op_mulh(a, b));
    fold(op_mulhsu(a, b));
    fold(op_mulhu(a, b));
    fold(op_div(a, b));
    fold(op_divu(a, b));
    fold(op_rem(a, b));
    fold(op_remu(a, b));
}

int spectra_main(uint32_t id)
{
    if (id != 0u)
        for (;;)
            ;
    RUN_START = 1u;
    h = 0x811C9DC5u;
    for (uint32_t i = 0; i < NEDGE; i++)
        for (uint32_t j = 0; j < NEDGE; j++)
            all_ops(edge[i], edge[j]);
    uint32_t s = 0x13579BDFu;
    for (uint32_t i = 0; i < NRAND; i++) {
        s = s * 1664525u + 1013904223u;
        uint32_t a = s;
        s = s * 1664525u + 1013904223u;
        uint32_t b = s >> (s & 31u);         /* small and large divisors, sometimes 0 */
        all_ops(a, b);
    }
    finish(h, GOLD_MEXT);
    return 0;
}
