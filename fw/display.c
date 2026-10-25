/* display.c - run report, the 7-segment tour and the counter browser (core 0 only, after the run).
 *
 * The program runs once; afterwards these loops only show the counters it left (frozen at
 * RUN_STOP). TIMER (never frozen) is the time base.
 *
 * Tour (on after every run; BTNU starts it again): one item every 3 s, in a loop -
 *   cycles in thousands; then for each running core its I-cache hit % (when IC = 1), D-cache
 *   hit % (when DC = 1) and CPI; then, with two cores, each core's arbiter wait %.
 * Moving SW15:14 or pressing BTNL / BTNR leaves the tour for the manual browser:
 *
 * SW15:14  count mode (default)          rate mode (BTNL toggles), 2 decimals
 *   00     cycles, in thousands           CPI of the selected core
 *   01     D-cache hits (selected core)   D-cache hit rate %
 *   10     D-cache misses                 I-cache hit rate %
 *   11     arbiter wait cycles            arbiter wait as % of cycles
 * BTNR toggles core 0 / core 1 (core 1 only when DUAL = 1).
 * Every value carries a label on the left (SEG7_TXT letters), the number right-aligned after it,
 * percentages and CPI with 2 decimals: "Cy  70337" cycles in thousands, "IH  99.98" I-cache hit %,
 * "dH  99.25" D-cache hit % or hits, "dn" D-cache misses, "CPI  2.20", "Ar" arbiter wait; with two
 * cores the core number and a dot follow the label ("IH1. 99.99"). A count too long for its digits is shown
 * in thousands (LED12).
 * LEDs: 0 done, 1 checksum OK, 10 tour on, 11 rate mode, 12 value in thousands, 13 core 1,
 * 15:14 = the selector of the value shown (SW15:14 in the browser; in the tour, the browser
 * setting that shows the same value). LED2 is driven by hardware (address-decode error). */
#include "spectra.h"

#define TOUR_TICKS 150000000u          /* 3 s at 50 MHz */

static uint32_t g_ok;

void finish(uint32_t checksum, uint32_t golden)
{
    RUN_STOP = 1u;                 /* counters are frozen before STATS is sent */
    CHECKSUM = checksum;           /* hardware sends the STATS packet */
    g_ok = (checksum == golden) ? 1u : 0u;
    LEDS = 1u | (g_ok << 1);
    SEG7 = CYCLES / 1000u;
    SEG7_DP = 0u;
    display_browser();
}

static uint32_t rate(uint32_t part, uint32_t whole, uint32_t scale)
{
    if (whole == 0u)
        return 0u;
    return udiv64_32((uint64_t)part * scale, whole);
}

/* SEG7_TXT letter codes (PROTOCOL.md section 3) */
#define L_C 1u
#define L_Y 2u
#define L_I 3u
#define L_H 4u
#define L_D 5u
#define L_N 6u
#define L_P 7u
#define L_A 8u
#define L_R 9u
#define L_0 11u

/* The label on the left of the display: "Cy" cycles, "dH" D-cache hits / hit %, "dn" D-cache
 * misses, "Ar" arbiter wait, "CPI", "IH" I-cache hit %; with two cores the core number follows
 * and a decimal point (except after "Cy", the whole run). Returns SEG7_TXT; *free = the digits
 * left for the number, *ldp = the label's decimal point. */
static uint32_t label(uint32_t sel, uint32_t rmode, uint32_t core, uint32_t dual, uint32_t *free, uint32_t *ldp)
{
    static const uint8_t two[2][4][2] = {
        {{L_C, L_Y}, {L_D, L_H}, {L_D, L_N}, {L_A, L_R}},            /* count mode */
        {{L_C, L_P}, {L_D, L_H}, {L_I, L_H}, {L_A, L_R}},            /* rate mode ("CP" + "I") */
    };
    uint32_t txt = ((uint32_t)two[rmode][sel][0] << 28) | ((uint32_t)two[rmode][sel][1] << 24);
    uint32_t used = 2u;
    if (rmode && sel == 0u) {                                        /* CPI */
        txt |= L_I << 20;
        used = 3u;
    }
    *ldp = 0u;
    if (dual && !(sel == 0u && !rmode)) {                            /* core number, then a dot */
        txt |= (L_0 + core) << (28u - 4u * used);
        used++;
        *ldp = 1u << (8u - used);                                    /* "dH0." keeps it apart */
    }
    *free = 8u - used;
    return txt;
}

/* The value the browser shows for selector sel, mode rmode and core: SEG7, SEG7_DP, SEG7_TXT
 * and the "in thousands" flag. */
static void show(uint32_t sel, uint32_t rmode, uint32_t core, uint32_t auto_on)
{
    uint32_t cyc = CYCLES;
    uint32_t val = 0u, dp = 0u, thousands = 0u, free, ldp;
    uint32_t txt = label(sel, rmode, core, (NCORES == 2u) ? 1u : 0u, &free, &ldp);
    uint32_t maxv = 1u;
    for (uint32_t i = 0u; i < free; i++)
        maxv *= 10u;
    maxv -= 1u;                                    /* the largest number that fits */

    if (!rmode) {
        if (sel == 0u) {
            val = cyc / 1000u;
            thousands = 1u;
        } else {
            val = (sel == 1u) ? CNT(core, C_DHIT) : (sel == 2u) ? CNT(core, C_DMISS) : CNT(core, C_ARBWAIT);
            if (val > maxv) {
                val /= 1000u;
                thousands = 1u;
            }
        }
        if (val > maxv)
            val = maxv;
    } else {
        dp = 1u << 2;                      /* xx.xx */
        if (sel == 0u) {
            val = rate(cyc, CNT(core, C_INSTRET), 100u);
        } else if (sel == 1u) {
            uint32_t h = CNT(core, C_DHIT), m = CNT(core, C_DMISS);
            val = rate(h, h + m, 10000u);
        } else if (sel == 2u) {
            uint32_t h = CNT(core, C_IHIT), m = CNT(core, C_IMISS);
            val = rate(h, h + m, 10000u);
        } else {
            val = rate(CNT(core, C_ARBWAIT), cyc, 10000u);
        }
        if (val > maxv)
            val = maxv;
    }

    SEG7 = val;
    SEG7_DP = dp | ldp;
    SEG7_TXT = txt;
    LEDS = 1u | (g_ok << 1) | (auto_on << 10) | (rmode << 11) | (thousands << 12) | (core << 13) | (sel << 14);
}

/* Tour items as browser settings: sel | rmode << 2 | core << 3. */
#define ITEM(sel, rmode, core) ((sel) | ((rmode) << 2) | ((core) << 3))

void display_browser(void)
{
    uint32_t cfg = CONFIG;
    uint32_t dual = (NCORES == 2u) ? 1u : 0u;
    uint32_t items[10], n = 0u;

    items[n++] = ITEM(0u, 0u, 0u);                                   /* cycles, thousands */
    for (uint32_t k = 0u; k <= dual; k++) {
        if (CFG_IC(cfg))
            items[n++] = ITEM(2u, 1u, k);                            /* I-cache hit % */
        if (CFG_DC(cfg))
            items[n++] = ITEM(1u, 1u, k);                            /* D-cache hit % */
        items[n++] = ITEM(0u, 1u, k);                                /* CPI */
    }
    if (dual) {
        items[n++] = ITEM(3u, 1u, 0u);                               /* arbiter wait % */
        items[n++] = ITEM(3u, 1u, 1u);
    }

    uint32_t core = 0u, rmode = 0u, tour = 1u, idx = 0u;
    uint32_t prev = BUTTONS;
    uint32_t prev_sel = (SWITCHES >> 14) & 3u;
    uint32_t t_last = TIMER;

    for (;;) {
        uint32_t b = BUTTONS;
        uint32_t rise = b & ~prev;
        prev = b;
        uint32_t sel = (SWITCHES >> 14) & 3u;

        if (rise & BTN_U) {                                          /* tour again, from the top */
            tour = 1u;
            idx = 0u;
            t_last = TIMER;
        } else if (tour && ((rise & (BTN_L | BTN_R)) || sel != prev_sel)) {
            tour = 0u;                                               /* to the manual browser */
        }
        prev_sel = sel;

        if (tour) {
            if (TIMER - t_last >= TOUR_TICKS) {
                t_last += TOUR_TICKS;
                idx = (idx + 1u == n) ? 0u : idx + 1u;
            }
            uint32_t it = items[idx];
            show(it & 3u, (it >> 2) & 1u, (it >> 3) & 1u, 1u);
        } else {
            if ((rise & BTN_R) && dual)
                core ^= 1u;
            if (rise & BTN_L)
                rmode ^= 1u;
            show(sel, rmode, core, 0u);
        }
    }
}
