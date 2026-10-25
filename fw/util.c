/* util.c - helpers shared by every program. */
#include "spectra.h"

/* The compilers may turn loops into calls to these, even with -ffreestanding. */
void *memset(void *d, int c, unsigned n)
{
    unsigned char *p = d;
    while (n--)
        *p++ = (unsigned char)c;
    return d;
}

void *memcpy(void *d, const void *s, unsigned n)
{
    unsigned char *p = d;
    const unsigned char *q = s;
    while (n--)
        *p++ = *q++;
    return d;
}

void lock_acquire(void)
{
    while (LOCK != 0u)
        ;
}

void lock_release(void)
{
    LOCK = 0u;
}

uint32_t fnv1a(const volatile uint8_t *p, uint32_t n)
{
    uint32_t h = 0x811C9DC5u;
    for (uint32_t i = 0; i < n; i++) {
        h ^= p[i];
        h *= 0x01000193u;
    }
    return h;
}

/* 64-by-32 unsigned division by shift-subtract, so no libgcc/compiler-rt is needed.
 * The quotient must fit in 32 bits (true for every rate the display shows). */
uint32_t udiv64_32(uint64_t n, uint32_t d)
{
    uint64_t r = 0;
    uint32_t q = 0;
    if (d == 0u)
        return 0u;
    for (int i = 63; i >= 0; i--) {
        r = (r << 1) | ((n >> i) & 1u);
        if (r >= d) {
            r -= d;
            if (i < 32)
                q |= 1u << i;
        }
    }
    return q;
}
