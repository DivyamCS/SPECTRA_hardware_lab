/* rv32sim.c - SPECTRA "simulated board": two RV32IM harts, the SPECTRA MMIO block, the
 * shared 4-way D-cache, private 2-way I-caches, the round-robin data port, the counters and
 * the UART result streamer. Instruction results are exact; cycle counts come from a
 * cycle-APPROXIMATE timing model (docs/PROTOCOL.md section 7). The RTL is the real timing.
 *
 * Build:  cc -O2 -o rv32sim sim/rv32sim.c        (or: python -m ziglang cc -O2 ...)
 * Run:    rv32sim [options] IMAGE_DIR            (IMAGE_DIR holds imem.hex and dmem.hex)
 *   -c HEX     CONFIG word = SW[15:0] at reset (default 0x0097: FWD DC DUAL IC, L=8, GoL)
 *   -u FILE    write the UART byte stream to FILE ("-" = stdout)
 *   -t PREFIX  commit traces PREFIX0.txt and PREFIX1.txt (one per hart)
 *   -m FILE    data-access trace for tools/cache_model.py
 *   -b SCRIPT  drive the 7-seg browser after the run, e.g. "0,1,2,3,R,1,L,1,2"
 *              digit = set SW15:14 and sample; R = press BTNR; L = press BTNL; U = press
 *              BTNU; W = let 3 s pass (150,000,000 cycles: one step of the 7-seg tour)
 *   -n CYCLES  stop with an error after this many cycles (default 4e9)
 *   -j         print the summary as one JSON object
 *   -F FAULT   inject a hardware bug to prove the tests catch it: stale1 (no forwarding),
 *              stale2 (register file not write-through), nosquash (instruction after a taken
 *              branch executes). Faults act only between RUN_START and RUN_STOP, so boot
 *              and setup still work and the test program itself meets the bug.
 */
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

#define IMEM_SIZE 0x4000u
#define DMEM_BASE 0x10000000u
#define DMEM_SIZE 0x20000u
#define MMIO_BASE 0x20000000u
#define UART_CYCLES_PER_BYTE 500u      /* 10 bits at 1 Mbaud, 50 MHz clock */
#define ROW_FIFO 256                   /* row records (core, row, cycle stamp); never fills in one run */

static uint8_t imem[IMEM_SIZE], dmem[DMEM_SIZE];
static uint32_t config, L, ncores;
static int opt_json;
static uint64_t max_cycles = 4000000000ull;

/* ---------------- caches ---------------- */
typedef struct {
    int sets, ways;
    uint32_t tag[64][4];
    uint8_t valid[64][4], dirty[64][4];
    uint8_t plru[64], fifo[64];
} cache_t;

static cache_t dcache, icache[2];

static void plru_touch(cache_t *c, int s, int w)
{
    uint8_t b = c->plru[s];
    if (w < 2)
        b = (uint8_t)((b | 1u) & ~2u) | (uint8_t)((w == 0) << 1);
    else
        b = (uint8_t)((b & ~1u) & ~4u) | (uint8_t)((w == 2) << 2);
    c->plru[s] = b;
}

static int pick_victim(cache_t *c, int s, unsigned allowed, int fifo)
{
    for (int w = 0; w < c->ways; w++)
        if ((allowed >> w & 1u) && !c->valid[s][w])
            return w;
    if (fifo) {
        int w = c->fifo[s];
        while (!(allowed >> w & 1u))
            w = (w + 1) & 3;
        return w;
    }
    uint8_t b = c->plru[s];
    int left_ok = (allowed & 3u) != 0, right_ok = (allowed & 12u) != 0;
    int right = (b & 1u) ? 1 : 0;
    if (right && !right_ok) right = 0;
    if (!right && !left_ok) right = 1;
    int w = right ? (2 + ((b >> 2) & 1u)) : ((b >> 1) & 1u);
    if (!(allowed >> w & 1u))
        w ^= 1;
    return w;
}

/* result codes */
enum { C_HIT = 0, C_MISS = 1, C_MISS_DIRTY = 2 };

static int cache_access(cache_t *c, uint32_t addr, int write, unsigned allowed, int fifo)
{
    int s = (int)((addr >> 4) & (uint32_t)(c->sets - 1));
    uint32_t tag = addr >> (4 + (c->sets == 64 ? 6 : 0));
    for (int w = 0; w < c->ways; w++)
        if (c->valid[s][w] && c->tag[s][w] == tag) {
            if (!fifo)
                plru_touch(c, s, w);
            if (write)
                c->dirty[s][w] = 1;
            return C_HIT;
        }
    int w = pick_victim(c, s, allowed, fifo);
    int res = (c->valid[s][w] && c->dirty[s][w]) ? C_MISS_DIRTY : C_MISS;
    c->valid[s][w] = 1;
    c->tag[s][w] = tag;
    c->dirty[s][w] = (uint8_t)write;
    if (fifo) {                                      /* FIFO: the pointer moves past the way filled */
        int n = (w + 1) & 3;
        while (!(allowed >> n & 1u))
            n = (n + 1) & 3;
        c->fifo[s] = (uint8_t)n;
    } else {
        plru_touch(c, s, w);
    }
    return res;
}

/* ---------------- harts, counters, MMIO ---------------- */
enum { K_INSTRET, K_DHIT, K_DMISS, K_IHIT, K_IMISS, K_ARB, K_BAR, K_N };

typedef struct {
    uint32_t x[32], pc;
    int hist_rd[2];                 /* rd written 1 and 2 instructions ago (fault injection) */
    uint32_t hist_old[2];           /* the value that register had before that write */
    int squash_pending;
    uint32_t squash_target;
    uint64_t t;
    int active, at_barrier, last_rd;
    uint32_t cnt[K_N];
    FILE *trace;
} hart_t;

static hart_t H[2];
static int counting;
static uint64_t run_t0, cycles_frozen;
static uint64_t port_free;
static int last_grant = 1;
static uint32_t leds, seg7, seg7_dp, seg7_txt, checksum_val;
static int have_checksum, lock_held, decode_error;
static int barrier_count;
static uint64_t barrier_last;
static uint32_t switches_live, buttons_live;
static int browser_entered, seg7_writes;
static FILE *mtrace;
static int fault_stale, fault_nosquash;
static const char *program_names[4] = {"gol", "mandel_halves", "mandel_interleaved", "matmul"};

/* ---------------- UART streamer ---------------- */
static FILE *uart;
static uint64_t uart_free, frame_busy_until;

static uint8_t crc8(const uint8_t *p, size_t n)
{
    uint8_t c = 0;
    for (size_t i = 0; i < n; i++) {
        c ^= p[i];
        for (int b = 0; b < 8; b++)
            c = (uint8_t)((c & 0x80u) ? ((unsigned)c << 1) ^ 0x07u : (unsigned)c << 1);
    }
    return c;
}

static uint64_t send_packet(uint64_t now, uint8_t type, const uint8_t *pl, uint16_t len)
{
    uint8_t hdr[4] = {0xA5, type, (uint8_t)len, (uint8_t)(len >> 8)};
    uint8_t buf[4 + 1024];
    memcpy(buf, hdr, 4);
    memcpy(buf + 4, pl, len);
    buf[4 + len] = crc8(buf + 1, 3u + len);
    uint64_t start = now > uart_free ? now : uart_free;
    uart_free = start + (uint64_t)(len + 5u) * UART_CYCLES_PER_BYTE;
    if (uart)
        fwrite(buf, 1, len + 5u, uart);
    return uart_free;
}

static void put16(uint8_t *p, uint32_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void put32(uint8_t *p, uint32_t v) { put16(p, v); put16(p + 2, v >> 16); }

static uint32_t run_cycles(uint64_t now)
{
    if (counting)
        return (uint32_t)(now - run_t0);
    return (uint32_t)cycles_frozen;
}

static uint32_t rd32(uint32_t a) { uint32_t v; memcpy(&v, &dmem[a - DMEM_BASE], 4); return v; }

/* ---------------- MMIO ---------------- */
static uint32_t mmio_read(int id, uint32_t off, uint64_t now)
{
    switch (off) {
    case 0x00: return (uint32_t)id;
    case 0x04: return ncores;
    case 0x08: return config;
    case 0x0C: return 0;                               /* blocking handled by the caller */
    case 0x10: { uint32_t v = (uint32_t)lock_held; lock_held = 1; return v; }
    case 0x34: return run_cycles(now);
    case 0x38: browser_entered = 1; return switches_live;
    case 0x3C: { uint32_t v = buttons_live; buttons_live = 0; return v; }
    case 0x44: return (uint32_t)now;                  /* TIMER: cycles since reset, never frozen */
    default:
        if (off >= 0x50 && off < 0x90 && ((off - 0x50) & 0x1Fu) < 0x1Cu) {
            int k = (int)((off - 0x50) >> 5);
            return H[k].cnt[((off - 0x50) & 0x1Fu) >> 2];
        }
        decode_error = 1;
        return 0;
    }
}

static void mmio_write(int id, uint32_t off, uint32_t v, uint64_t now)
{
    uint8_t pl[600];
    switch (off) {
    case 0x10: if (v == 0) lock_held = 0; break;
    case 0x14:
        for (int k = 0; k < 2; k++)
            memset(H[k].cnt, 0, sizeof H[k].cnt);
        counting = 1;
        run_t0 = now;
        if (mtrace) fprintf(mtrace, "RUN_START\n");
        put16(pl, config); pl[2] = (uint8_t)ncores; pl[3] = (uint8_t)((config >> 5) & 3u);
        send_packet(now, 0x01, pl, 4);
        break;
    case 0x18:
        if (counting) {
            cycles_frozen = now - run_t0;
            counting = 0;
            if (mtrace) fprintf(mtrace, "RUN_STOP\n");
        }
        break;
    case 0x1C: {                                        /* GoL frame capture */
        if (now < frame_busy_until)
            break;                                      /* streamer busy: frame skipped */
        uint32_t base = (v >> 16) & 1u ? 0x10009000u : 0x10008000u;
        put16(pl, v & 0xFFFFu);
        put32(pl + 2, run_cycles(now));
        memset(pl + 6, 0, 512);
        for (int i = 0; i < 4096; i++)
            if (dmem[base - DMEM_BASE + (uint32_t)i])
                pl[6 + i / 8] |= (uint8_t)(1u << (i % 8));
        frame_busy_until = send_packet(now, 0x02, pl, 518);
        break;
    }
    case 0x20: {
        checksum_val = v;
        have_checksum = 1;
        put16(pl, config); pl[2] = (uint8_t)ncores; pl[3] = (uint8_t)((config >> 5) & 3u);
        put32(pl + 4, (uint32_t)cycles_frozen);
        put32(pl + 8, v);
        for (int k = 0; k < 2; k++)
            for (int j = 0; j < K_N; j++)
                put32(pl + 12 + 4 * (7 * k + j), H[k].cnt[j]);
        send_packet(now, 0x05, pl, 68);
        break;
    }
    case 0x24: leds = (v & ~4u) | (decode_error ? 4u : 0u); break;
    case 0x28: seg7 = v; seg7_writes++; break;
    case 0x2C: {                                        /* Mandelbrot row */
        uint32_t r = v % 144u;
        pl[0] = (uint8_t)id; put16(pl + 1, r); put32(pl + 3, run_cycles(now));
        memcpy(pl + 7, &dmem[0x10010000u - DMEM_BASE + r * 192u], 192);
        send_packet(now, 0x03, pl, 199);              /* data comes from the streamer's shadow image */
        break;
    }
    case 0x30: {                                        /* MatMul row of C */
        uint32_t r = v % 32u;
        pl[0] = (uint8_t)id; pl[1] = (uint8_t)r; put32(pl + 2, run_cycles(now));
        for (int j = 0; j < 32; j++) {
            uint32_t c = rd32(0x10018000u + (r * 32u + (uint32_t)j) * 4u);
            pl[6 + j] = (uint8_t)((c >> 5) > 255u ? 255u : (c >> 5));
        }
        send_packet(now, 0x04, pl, 38);               /* data comes from the streamer's shadow of C */
        break;
    }
    case 0x40: seg7_dp = v & 0xFFu; break;
    case 0x48: seg7_txt = v; break;                    /* SEG7_TXT: letters per digit */
    default: decode_error = 1; break;
    }
}

/* ---------------- data-port timing ---------------- */
/* Returns MEM/WB cycles of this access (2 = hit) and books the shared port. */
static uint64_t dport(int id, uint32_t addr, int write, uint64_t req, uint64_t *wait)
{
    uint64_t occ;
    int cacheable = addr >= DMEM_BASE && addr < DMEM_BASE + DMEM_SIZE;
    int dc = (config >> 1) & 1u;
    if (!cacheable) {
        occ = 2;                                       /* MMIO: answered at once */
    } else if (!dc) {
        occ = 2 + L + 1;                               /* bypass: one-word burst */
    } else {
        int r = cache_access(&dcache, addr, write, 15u, 0);   /* D-cache: write-back, PLRU, 4 ways */
        if (counting) H[id].cnt[r == C_HIT ? K_DHIT : K_DMISS]++;
        if (mtrace) fprintf(mtrace, "%d %c %08" PRIx32 "\n", id, write ? 'W' : 'R', addr);
        if (r == C_HIT)
            occ = 2;
        else
            occ = 2 + (L + 4) * (r == C_MISS_DIRTY ? 2u : 1u);
    }
    uint64_t start = req > port_free ? req : port_free;   /* ties are resolved by pick() */
    *wait = start - req;
    port_free = start + occ;
    last_grant = id;
    return occ;
}

/* ---------------- one instruction ---------------- */
static void trace_line(hart_t *h, uint32_t pc, uint32_t ins, int rd, uint32_t val, int kind, uint32_t addr, uint32_t sdata)
{
    if (!h->trace) return;
    fprintf(h->trace, "%08" PRIx32 " %08" PRIx32, pc, ins);
    if (rd) fprintf(h->trace, " x%d=%08" PRIx32, rd, val);
    if (kind == 1) fprintf(h->trace, " ld %08" PRIx32, addr);
    if (kind == 2) fprintf(h->trace, " st %08" PRIx32 " %08" PRIx32, addr, sdata);
    fputc('\n', h->trace);
}

static void die(const char *msg, int id, uint32_t pc, uint32_t ins)
{
    fprintf(stderr, "rv32sim: %s (hart %d, pc %08" PRIx32 ", instr %08" PRIx32 ")\n", msg, id, pc, ins);
    exit(2);
}

static int32_t sx(uint32_t v, int bits) { return (int32_t)(v << (32 - bits)) >> (32 - bits); }

static uint32_t mem_load(int id, uint32_t a, int size, int sign, uint64_t now)
{
    uint32_t v = 0;
    if (a >= DMEM_BASE && a - DMEM_BASE <= DMEM_SIZE - (uint32_t)size) {   /* no wrap-around */
        memcpy(&v, &dmem[a - DMEM_BASE], (size_t)size);
    } else if (a >= MMIO_BASE && a < MMIO_BASE + 0x100u && size == 4) {
        v = mmio_read(id, a - MMIO_BASE, now);
    } else {
        decode_error = 1;
        return 0;
    }
    if (sign && size < 4) v = (uint32_t)sx(v, size * 8);
    return v;
}

static void mem_store(int id, uint32_t a, int size, uint32_t v, uint64_t now)
{
    if (a >= DMEM_BASE && a - DMEM_BASE <= DMEM_SIZE - (uint32_t)size)
        memcpy(&dmem[a - DMEM_BASE], &v, (size_t)size);
    else if (a >= MMIO_BASE && a < MMIO_BASE + 0x100u && size == 4)
        mmio_write(id, a - MMIO_BASE, v, now);
    else
        decode_error = 1;
}

static void step(int id)
{
    hart_t *h = &H[id];
    uint32_t pc = h->pc;
    if (pc >= IMEM_SIZE || (pc & 3u)) die("fetch outside IMEM or misaligned", id, pc, 0);
    uint32_t ins;
    memcpy(&ins, &imem[pc], 4);
    uint64_t cost = 1;
    int fwd = config & 1u, ic = (config >> 7) & 1u;

    if (ic) {
        int r = cache_access(&icache[id], pc, 0, 3u, 1);          /* I-cache: FIFO, 2 ways */
        if (counting) h->cnt[r == C_HIT ? K_IHIT : K_IMISS]++;
        if (r != C_HIT) cost += L + 4;
    } else {
        cost += L + 1;                                  /* every fetch is a one-word burst */
    }

    uint32_t op = ins & 0x7Fu, rd = (ins >> 7) & 31u, f3 = (ins >> 12) & 7u, rs1 = (ins >> 15) & 31u,
             rs2 = (ins >> 20) & 31u, f7 = ins >> 25;
    uint32_t a = h->x[rs1], b = h->x[rs2];
    if (fault_stale && counting)                       /* injected bug (inside the timed run only) */
        for (int k = 0; k < 2; k++)
            if (fault_stale == k + 1 && h->hist_rd[k]) {
                if ((int)rs1 == h->hist_rd[k]) a = h->hist_old[k];
                if ((int)rs2 == h->hist_rd[k]) b = h->hist_old[k];
            }
    int32_t imm_i = sx(ins >> 20, 12);
    int32_t imm_s = sx(((ins >> 25) << 5) | ((ins >> 7) & 31u), 12);
    int32_t imm_b = sx(((ins >> 31) << 12) | (((ins >> 7) & 1u) << 11) | (((ins >> 25) & 63u) << 5) | (((ins >> 8) & 15u) << 1), 13);
    int32_t imm_j = sx(((ins >> 31) << 20) | (((ins >> 12) & 255u) << 12) | (((ins >> 20) & 1u) << 11) | (((ins >> 21) & 1023u) << 1), 21);
    uint32_t next = pc + 4, val = 0, addr = 0, sdata = 0;
    int writes = 0, uses1 = 0, uses2 = 0, kind = 0, taken = 0;

    switch (op) {
    case 0x37: val = ins & 0xFFFFF000u; writes = 1; break;                       /* LUI */
    case 0x17: val = pc + (ins & 0xFFFFF000u); writes = 1; break;                /* AUIPC */
    case 0x6F: val = pc + 4; next = pc + (uint32_t)imm_j; writes = 1; taken = 1; break;
    case 0x67:
        if (f3) die("illegal JALR", id, pc, ins);
        uses1 = 1; val = pc + 4; next = (a + (uint32_t)imm_i) & ~1u; writes = 1; taken = 1; break;
    case 0x63: {
        uses1 = uses2 = 1;
        int c;
        switch (f3) {
        case 0: c = a == b; break;
        case 1: c = a != b; break;
        case 4: c = (int32_t)a < (int32_t)b; break;
        case 5: c = (int32_t)a >= (int32_t)b; break;
        case 6: c = a < b; break;
        case 7: c = a >= b; break;
        default: die("illegal branch", id, pc, ins); c = 0;
        }
        if (c) { next = pc + (uint32_t)imm_b; taken = 1; }
        break;
    }
    case 0x03: {
        uses1 = 1; addr = a + (uint32_t)imm_i; kind = 1; writes = 1;
        int size = (f3 & 3u) == 0 ? 1 : (f3 & 3u) == 1 ? 2 : 4;
        if (f3 == 3 || f3 > 5) die("illegal load", id, pc, ins);
        if (addr & (uint32_t)(size - 1)) die("misaligned load", id, pc, ins);
        uint64_t wait;
        uint64_t req = h->t + cost;
        uint64_t occ = dport(id, addr, 0, req, &wait);
        int is_barrier = (addr == MMIO_BASE + 0x0Cu);
        uint64_t when = req + wait;
        val = mem_load(id, addr, size, !(f3 & 4u), when);
        cost += wait + (occ - 1);
        if (counting) h->cnt[K_ARB] += (uint32_t)wait;
        if (is_barrier) {
            h->t += cost;
            h->at_barrier = 1;
            barrier_count++;
            if (h->t > barrier_last) barrier_last = h->t;
            cost = 0;
            if ((uint32_t)barrier_count == ncores) {
                for (int k = 0; k < (int)ncores; k++) {
                    if (counting) H[k].cnt[K_BAR] += (uint32_t)(barrier_last - H[k].t);
                    H[k].t = barrier_last;
                    H[k].at_barrier = 0;
                }
                barrier_count = 0;
                barrier_last = 0;
            }
        }
        break;
    }
    case 0x23: {
        uses1 = uses2 = 1; addr = a + (uint32_t)imm_s; kind = 2;
        int size = f3 == 0 ? 1 : f3 == 1 ? 2 : f3 == 2 ? 4 : 0;
        if (!size) die("illegal store", id, pc, ins);
        if (addr & (uint32_t)(size - 1)) die("misaligned store", id, pc, ins);
        sdata = size == 4 ? b : b & ((1u << (8 * size)) - 1u);
        uint64_t wait, req = h->t + cost;
        uint64_t occ = dport(id, addr, 1, req, &wait);
        uint64_t when = req + wait;
        mem_store(id, addr, size, sdata, when + 1);      /* the streamer never makes a core wait */
        cost += wait + (occ - 1);
        if (counting) h->cnt[K_ARB] += (uint32_t)wait;
        break;
    }
    case 0x13: {
        uses1 = 1; writes = 1;
        uint32_t sh = rs2;
        switch (f3) {
        case 0: val = a + (uint32_t)imm_i; break;
        case 2: val = (int32_t)a < imm_i; break;
        case 3: val = a < (uint32_t)imm_i; break;
        case 4: val = a ^ (uint32_t)imm_i; break;
        case 6: val = a | (uint32_t)imm_i; break;
        case 7: val = a & (uint32_t)imm_i; break;
        case 1: if (f7) die("illegal SLLI", id, pc, ins); val = a << sh; break;
        case 5:
            if (f7 == 0x00) val = a >> sh;
            else if (f7 == 0x20) val = (uint32_t)((int32_t)a >> sh);
            else die("illegal SRxI", id, pc, ins);
            break;
        }
        break;
    }
    case 0x33: {
        uses1 = uses2 = 1; writes = 1;
        if (f7 == 0x01) {
            int64_t sa = (int32_t)a, sb = (int32_t)b;
            uint64_t ua = a, ub = b;
            switch (f3) {
            case 0: val = (uint32_t)(sa * sb); break;
            case 1: val = (uint32_t)((uint64_t)(sa * sb) >> 32); break;
            case 2: val = (uint32_t)((uint64_t)(sa * (int64_t)ub) >> 32); break;
            case 3: val = (uint32_t)((ua * ub) >> 32); break;
            case 4: val = b == 0 ? 0xFFFFFFFFu : (a == 0x80000000u && b == 0xFFFFFFFFu) ? a : (uint32_t)((int32_t)a / (int32_t)b); break;
            case 5: val = b == 0 ? 0xFFFFFFFFu : a / b; break;
            case 6: val = b == 0 ? a : (a == 0x80000000u && b == 0xFFFFFFFFu) ? 0 : (uint32_t)((int32_t)a % (int32_t)b); break;
            case 7: val = b == 0 ? a : a % b; break;
            }
            cost += (f3 < 4) ? 2 : 33;                 /* MUL 3 cycles in EX, DIV 34 */
        } else if (f7 == 0x00 || (f7 == 0x20 && (f3 == 0 || f3 == 5))) {
            switch (f3) {
            case 0: val = f7 ? a - b : a + b; break;
            case 1: val = a << (b & 31u); break;
            case 2: val = (int32_t)a < (int32_t)b; break;
            case 3: val = a < b; break;
            case 4: val = a ^ b; break;
            case 5: val = f7 ? (uint32_t)((int32_t)a >> (b & 31u)) : a >> (b & 31u); break;
            case 6: val = a | b; break;
            case 7: val = a & b; break;
            }
        } else {
            die("illegal OP", id, pc, ins);
        }
        break;
    }
    default:
        die("illegal or unsupported instruction (only RV32IM, no FENCE/ECALL/CSR)", id, pc, ins);
    }

    if (!fwd && h->last_rd && ((uses1 && (int)rs1 == h->last_rd) || (uses2 && (int)rs2 == h->last_rd)))
        cost += 1;                                       /* FWD = 0: 1-cycle interlock */
    if (taken) cost += 2;                                /* 2 instructions squashed */

    h->hist_rd[1] = h->hist_rd[0];
    h->hist_old[1] = h->hist_old[0];
    h->hist_rd[0] = (writes && rd) ? (int)rd : 0;
    h->hist_old[0] = h->x[rd];
    if (writes && rd) h->x[rd] = val;
    h->last_rd = (writes && rd) ? (int)rd : 0;
    if (fault_nosquash && (counting || h->squash_pending)) {   /* injected bug: next instruction runs */
        if (h->squash_pending) {
            h->squash_pending = 0;
            next = h->squash_target;
        } else if (taken) {
            h->squash_pending = 1;
            h->squash_target = next;
            next = pc + 4;
        }
    }
    trace_line(h, pc, ins, writes ? (int)rd : 0, val, kind, addr, sdata);
    h->pc = next;
    h->t += cost;
    if (counting) h->cnt[K_INSTRET]++;
}

/* ---------------- loader ---------------- */
static void load_hex(const char *path, uint8_t *mem, size_t size)
{
    FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "rv32sim: cannot open %s\n", path); exit(2); }
    char line[64];
    size_t i = 0;
    while (fgets(line, sizeof line, f)) {
        if (line[0] == '\n' || line[0] == '\r' || line[0] == '/') continue;
        uint32_t w = (uint32_t)strtoul(line, NULL, 16);
        if (i + 4 > size) { fprintf(stderr, "rv32sim: %s too long\n", path); exit(2); }
        memcpy(&mem[i], &w, 4);
        i += 4;
    }
    fclose(f);
}

static int pick(void)
{
    int a0 = H[0].active && !H[0].at_barrier, a1 = H[1].active && !H[1].at_barrier;
    if (a0 && a1) {
        if (H[0].t != H[1].t) return H[0].t < H[1].t ? 0 : 1;
        return last_grant ^ 1;
    }
    if (a0) return 0;
    if (a1) return 1;
    return -1;
}

static void print_summary(void)
{
    static const char *kn[K_N] = {"instret", "dhit", "dmiss", "ihit", "imiss", "arbwait", "barwait"};
    uint32_t prog = (config >> 5) & 3u;
    if (opt_json) {
        printf("{\"config\":%" PRIu32 ",\"program\":\"%s\",\"ncores\":%" PRIu32 ",\"L\":%" PRIu32 ",\"checksum\":%" PRIu32
               ",\"have_checksum\":%d,\"leds\":%" PRIu32 ",\"seg7\":%" PRIu32 ",\"cycles\":%" PRIu64 ",\"cores\":[",
               config, program_names[prog], ncores, L, checksum_val, have_checksum, leds, seg7, cycles_frozen);
        for (int k = 0; k < 2; k++) {
            printf("%s{", k ? "," : "");
            for (int j = 0; j < K_N; j++) printf("%s\"%s\":%" PRIu32, j ? "," : "", kn[j], H[k].cnt[j]);
            printf("}");
        }
        printf("]}\n");
        return;
    }
    printf("config=0x%04" PRIx32 " program=%s cores=%" PRIu32 " L=%" PRIu32 " checksum=0x%08" PRIx32 " %s cycles=%" PRIu64
           " seg7=%" PRIu32 " leds=0x%04" PRIx32 "\n", config, program_names[prog], ncores, L, checksum_val,
           (leds & 2u) ? "golden=OK" : "golden=FAIL", cycles_frozen, seg7, leds);
    for (int k = 0; k < (int)ncores; k++) {
        printf("  core%d:", k);
        for (int j = 0; j < K_N; j++) printf(" %s=%" PRIu32, kn[j], H[k].cnt[j]);
        printf("\n");
    }
}

static void browse(const char *script)
{
    char tok[16];
    for (const char *p = script; *p;) {
        size_t n = strcspn(p, ",");
        if (n >= sizeof tok) n = sizeof tok - 1;
        memcpy(tok, p, n);
        tok[n] = 0;
        p += n;
        if (*p == ',') p++;
        if (!n) continue;
        if (tok[0] >= '0' && tok[0] <= '3')
            switches_live = (switches_live & 0x3FFFu) | ((uint32_t)(tok[0] - '0') << 14);
        else if (tok[0] == 'R')
            buttons_live = 2u;
        else if (tok[0] == 'L')
            buttons_live = 1u;
        else if (tok[0] == 'U')
            buttons_live = 4u;
        else if (tok[0] == 'W') {
            uint64_t t_end = H[0].t + 150000000ull;    /* 3 s at 50 MHz */
            while (H[0].t < t_end) {
                step(0);
                if (H[0].t > max_cycles) die("cycle limit in browser", 0, H[0].pc, 0);
            }
        }
        int target = seg7_writes + 2;
        while (seg7_writes < target) {
            step(0);
            if (H[0].t > max_cycles) die("cycle limit in browser", 0, H[0].pc, 0);
        }
        printf("browse %s: seg7=%" PRIu32 " dp=0x%02" PRIx32 " leds=0x%04" PRIx32 " txt=0x%08" PRIx32 "\n", tok, seg7, seg7_dp, leds, seg7_txt);
    }
}

int main(int argc, char **argv)
{
    const char *dir = NULL, *uart_path = NULL, *trace_prefix = NULL, *mtrace_path = NULL, *script = NULL;
    config = 0x0097u;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-c") && i + 1 < argc) config = (uint32_t)strtoul(argv[++i], NULL, 16) & 0xFFFFu;
        else if (!strcmp(argv[i], "-u") && i + 1 < argc) uart_path = argv[++i];
        else if (!strcmp(argv[i], "-t") && i + 1 < argc) trace_prefix = argv[++i];
        else if (!strcmp(argv[i], "-m") && i + 1 < argc) mtrace_path = argv[++i];
        else if (!strcmp(argv[i], "-b") && i + 1 < argc) script = argv[++i];
        else if (!strcmp(argv[i], "-n") && i + 1 < argc) max_cycles = strtoull(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "-j")) opt_json = 1;
        else if (!strcmp(argv[i], "-F") && i + 1 < argc) {
            const char *f = argv[++i];
            if (!strcmp(f, "stale1")) fault_stale = 1;
            else if (!strcmp(f, "stale2")) fault_stale = 2;
            else if (!strcmp(f, "nosquash")) fault_nosquash = 1;
            else { fprintf(stderr, "rv32sim: unknown fault %s\n", f); return 2; }
        }
        else if (argv[i][0] != '-' && !dir) dir = argv[i];
        else { fprintf(stderr, "usage: rv32sim [-c HEX] [-u FILE] [-t PREFIX] [-m FILE] [-b SCRIPT] [-n CYCLES] [-j] [-F FAULT] IMAGE_DIR\n"); return 2; }
    }
    if (!dir) { fprintf(stderr, "rv32sim: no image directory\n"); return 2; }
    char path[1024];
    snprintf(path, sizeof path, "%s/imem.hex", dir); load_hex(path, imem, sizeof imem);
    snprintf(path, sizeof path, "%s/dmem.hex", dir); load_hex(path, dmem, 0x8000u);

    static const uint32_t lat[4] = {5, 6, 8, 10};
    L = lat[(config >> 3) & 3u];
    ncores = ((config >> 2) & 1u) ? 2u : 1u;
    switches_live = config;
    dcache.sets = 64; dcache.ways = 4;
    for (int k = 0; k < 2; k++) { icache[k].sets = 64; icache[k].ways = 2; }
    if (uart_path) {
        uart = strcmp(uart_path, "-") ? fopen(uart_path, "wb") : stdout;
#ifdef _WIN32
        if (uart == stdout) _setmode(_fileno(stdout), _O_BINARY);
#endif
        if (!uart) { fprintf(stderr, "rv32sim: cannot write %s\n", uart_path); return 2; }
    }
    if (mtrace_path) mtrace = fopen(mtrace_path, "w");
    for (int k = 0; k < (int)ncores; k++) {
        H[k].active = 1;
        if (trace_prefix) {
            snprintf(path, sizeof path, "%s%d.txt", trace_prefix, k);
            H[k].trace = fopen(path, "w");
        }
    }

    while (!browser_entered) {
        int k = pick();
        if (k < 0) die("deadlock: every running core waits at the barrier", 0, H[0].pc, 0);
        step(k);
        if (H[k].t > max_cycles) die("cycle limit reached", k, H[k].pc, 0);
    }
    if (uart && uart != stdout) fclose(uart);
    if (uart == stdout) fflush(stdout);
    if (!uart || uart != stdout) print_summary();
    if (script) browse(script);
    for (int k = 0; k < 2; k++) if (H[k].trace) fclose(H[k].trace);
    if (mtrace) fclose(mtrace);
    return (leds & 2u) ? 0 : 1;
}
