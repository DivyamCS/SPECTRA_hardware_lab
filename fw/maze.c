/* maze.c - maze mode: a dual-core raycaster (docs/spec/raycaster_demo.md).
 *
 * The same integer operations as tools/raycast.py, the golden model, in the same order, so every
 * column's (height, side) is equal bit for bit (tools/mazecmp.py checks it): Q16.16, camera-plane
 * DDA (the perpendicular distance: no fisheye), 32-bit unsigned divisions only.
 *
 * Each frame: core 0 writes the frame header (seq, pose) into COLUMNS and decides how many cores
 * draw (2 when DUAL and SW2 is up now: SW2 is read live); BARRIER; core k draws the columns
 * k, k + n, k + 2n, ... into COLUMNS (height, side | core << 1); BARRIER; core 0 writes the
 * frame's cycle count (CYCLES now - CYCLES at the frame's start) to MAZEFRAME, and the streamer
 * sends the MAZEFRAME packet; then the input (BTNL / BTNR turn, BTNU / BTND walk) moves the player
 * for the next frame by a step that follows real time (the TIMER cycles since the last frame), so
 * the walk is equally fast with 1 or 2 cores and only the frame rate - the smoothness - changes.
 * The lights: every column also casts MAZE_SHADOW_N shadow rays from the wall point it sees to each
 * of two lights, the lantern that trails the player (its position 1 s earlier; on the scripted
 * path, the position MAZE_LIGHT_LAG_SCRIPT frames earlier) and the beacon, and sends the light level
 * 0..63 in attr bits 7:2. These rays are most of a frame's work: enough that the frame rate falls
 * into the range the eye (and the 1 Mbaud UART) can follow, so flipping SW2 visibly doubles it.
 * The game (Light Hunt): five orbs to pick up in any order, then the exit. The beacon stands on the
 * lowest orb not yet picked up (on the exit once all are), so its glow on the walls shows the way.
 * Each pickup sends a new MAZEMAP packet (the orbs left, the exit closed or open); the board shows
 * the orbs on LED15..11 and "orbs   seconds" on the 7-segment display. The exit with every orb:
 * "d0nE" and the time, STATS (checksum = the game time in ms); BTNC starts a new game.
 * Detail mode (SW5 up at reset): with 1 core drawing, the frame has MAZE_COLS_LOW = 80 columns
 * over the same view (each shown twice as wide), so 1 and 2 cores keep the same frame rate and the
 * difference shows as detail; without SW5, 160 columns and 1 core runs at half the frame rate.
 * Race mode (SW14 + SW6 at reset): the autopilot plays the game (tools/raycast.py race_script): its
 * targets are the orbs in order, a fixed step per frame, and the run ends with the checksum at the
 * pickup of orb MAZE_RACE_ORBS - 1. With fewer frames per second the race ends later.
 * Angles: 0..65535 a turn; the sine table is indexed by the top 10 bits.
 * Live mode: BTNC starts a new game at the start pose, and the player moves only on a press.
 * Scripted mode (SW14 up at reset): the autopilot with large steps from the start pose - the
 * reference's scripted path, which picks up orb 0 - and after MAZE_SCRIPT_N frames core 0 posts
 * the checksum of every column's (height, side, light) against MAZE_GOLD (LED1 = equal), then shows
 * the counters. So the checksum also proves the C autopilot and the game equal to the reference. */
#include "spectra.h"
#include "maze_data.h"

/* PROTOCOL.md section 11 (MAZEFRAME / MAZEMAP: spectra.h) */
#define MAZE_MAP_RAM  ((volatile uint8_t *)0x1000A000u)
#define MAZE_COLS_RAM ((volatile uint8_t *)0x1000A800u)
#define GAME_ALL ((1u << MAZE_N_ORBS) - 1u)

static volatile int32_t g_x, g_y, g_a;            /* the pose of the frame being drawn */
static volatile int32_t g_lx, g_ly;               /* the lantern of the frame being drawn */
static volatile int32_t g_bx, g_by;               /* the beacon (the game's target) */
static volatile uint32_t g_ncols_cores;           /* cores drawing this frame: 1 or 2 */
static volatile uint32_t g_ncols;                 /* columns this frame: 160, or 80 in detail mode with 1 core */
static const int32_t *volatile g_camx;            /* their camera x table */

static inline int32_t mulq(int32_t a, int32_t b) { return (int32_t)(((int64_t)a * b) >> 16); }
static inline uint32_t umulq(uint32_t a, uint32_t b) { return (uint32_t)(((uint64_t)a * b) >> 16); }
static inline uint32_t sat_add(uint32_t a, uint32_t b) { uint32_t s = a + b; return s < a ? 0xFFFFFFFFu : s; }
static inline int32_t iabs(int32_t v) { return v < 0 ? -v : v; }

/* tools/raycast.py shadow_visible(): 1 if the segment from P (inside free cell cx, cy) to Q crosses
 * no wall cell before Q (grid DDA in segment units, t = 1.0 at Q) */
static uint32_t shadow_visible(int32_t px, int32_t py, int32_t cx, int32_t cy, int32_t qx, int32_t qy)
{
    int32_t dx = qx - px, dy = qy - py;
    uint32_t ddx = dx ? 0xFFFFFFFFu / (uint32_t)iabs(dx) : 0xFFFFFFFFu;
    uint32_t ddy = dy ? 0xFFFFFFFFu / (uint32_t)iabs(dy) : 0xFFFFFFFFu;
    int32_t sx, sy;
    uint32_t sdx, sdy;
    if (dx < 0) { sx = -1; sdx = umulq((uint32_t)(px - (cx << 16)), ddx); }
    else        { sx = 1;  sdx = umulq((uint32_t)(((cx + 1) << 16) - px), ddx); }
    if (dy < 0) { sy = -1; sdy = umulq((uint32_t)(py - (cy << 16)), ddy); }
    else        { sy = 1;  sdy = umulq((uint32_t)(((cy + 1) << 16) - py), ddy); }
    for (int i = 0; i < MAZE_SHADOW_STEPS; i++) {
        if (sdx >= 65536u && sdy >= 65536u)
            return 1u;
        if (sdx <= sdy) { sdx = sat_add(sdx, ddx); cx += sx; }
        else            { sdy = sat_add(sdy, ddy); cy += sy; }
        if (maze_map[cy * MAZE_N + cx])
            return 0u;
    }
    return 0u;
}

/* tools/raycast.py light_level(): 0..63 for the wall point a column sees, from MAZE_SHADOW_N shadow
 * rays to the light's disc x distance falloff x facing. Every ray is traced: a steady cost. */
static uint32_t light_level(int32_t x, int32_t y, int32_t rx, int32_t ry, int32_t mx, int32_t my,
                            uint32_t side, int32_t sx, int32_t sy, uint32_t perp, int32_t lx, int32_t ly)
{
    int32_t px, py, cx, cy;
    if (side == 0u) {
        px = (sx > 0 ? (mx << 16) : ((mx + 1) << 16)) - sx * MAZE_EPS;
        py = y + mulq(ry, (int32_t)perp);
        if (py < (my << 16) + MAZE_EPS) py = (my << 16) + MAZE_EPS;
        if (py > ((my + 1) << 16) - MAZE_EPS) py = ((my + 1) << 16) - MAZE_EPS;
        cx = mx - sx; cy = my;
    } else {
        py = (sy > 0 ? (my << 16) : ((my + 1) << 16)) - sy * MAZE_EPS;
        px = x + mulq(rx, (int32_t)perp);
        if (px < (mx << 16) + MAZE_EPS) px = (mx << 16) + MAZE_EPS;
        if (px > ((mx + 1) << 16) - MAZE_EPS) px = ((mx + 1) << 16) - MAZE_EPS;
        cx = mx; cy = my - sy;
    }
    int32_t vx = lx - px, vy = ly - py;
    int32_t dn = side == 0u ? -sx * vx : -sy * vy;
    int32_t d2 = mulq(vx, vx) + mulq(vy, vy);
    uint32_t fall = (63u << 16) / (uint32_t)(65536 + (d2 >> 3));
    uint32_t lam = dn > 0 ? ((uint32_t)dn << 8) / (uint32_t)(iabs(vx) + iabs(vy)) : 0u;
    uint32_t vis = 0;
    for (uint32_t k = 0; k < MAZE_SHADOW_N; k++)
        vis += shadow_visible(px, py, cx, cy, lx + maze_light_disc[k][0], ly + maze_light_disc[k][1]);
    return (fall * lam * vis) / ((uint32_t)MAZE_SHADOW_N << 8);
}

static void cast_columns(uint32_t first, uint32_t step, uint32_t core)
{
    int32_t x = g_x, y = g_y, a = g_a, lx = g_lx, ly = g_ly, bx = g_bx, by = g_by;
    uint32_t ncols = g_ncols;
    const int32_t *camx = g_camx;
    int32_t dx = maze_sin[((a >> 6) + 256) & 1023], dy = maze_sin[a >> 6];
    int32_t px = mulq(-dy, MAZE_PLANE), py = mulq(dx, MAZE_PLANE);
    for (uint32_t c = first; c < ncols; c += step) {
        int32_t rx = dx + mulq(px, camx[c]);
        int32_t ry = dy + mulq(py, camx[c]);
        int32_t mx = x >> 16, my = y >> 16;
        uint32_t ddx = rx ? 0xFFFFFFFFu / (uint32_t)(rx < 0 ? -rx : rx) : 0xFFFFFFFFu;
        uint32_t ddy = ry ? 0xFFFFFFFFu / (uint32_t)(ry < 0 ? -ry : ry) : 0xFFFFFFFFu;
        int32_t sx, sy;
        uint32_t sdx, sdy;
        if (rx < 0) { sx = -1; sdx = umulq((uint32_t)(x - (mx << 16)), ddx); }
        else        { sx = 1;  sdx = umulq((uint32_t)(((mx + 1) << 16) - x), ddx); }
        if (ry < 0) { sy = -1; sdy = umulq((uint32_t)(y - (my << 16)), ddy); }
        else        { sy = 1;  sdy = umulq((uint32_t)(((my + 1) << 16) - y), ddy); }
        uint32_t side = 0;
        for (int i = 0; i < 64; i++) {
            if (sdx <= sdy) { sdx = sat_add(sdx, ddx); mx += sx; side = 0; }
            else            { sdy = sat_add(sdy, ddy); my += sy; side = 1; }
            if (maze_map[my * MAZE_N + mx])
                break;
        }
        uint32_t perp = side ? sdy - ddy : sdx - ddx;
        if (perp < 1u)
            perp = 1u;
        uint32_t h = ((uint32_t)MAZE_SCREEN_H << 16) / perp;
        uint32_t lvl = light_level(x, y, rx, ry, mx, my, side, sx, sy, perp, lx, ly) +
                       light_level(x, y, rx, ry, mx, my, side, sx, sy, perp, bx, by);
        if (lvl > 63u)
            lvl = 63u;
        MAZE_COLS_RAM[16 + 2 * c] = (uint8_t)(h > 255u ? 255u : h);
        MAZE_COLS_RAM[17 + 2 * c] = (uint8_t)(side | (core << 1) | (lvl << 2));
    }
}

static void move(int32_t *x, int32_t *y, int32_t *a, uint32_t btn, int32_t speed, int32_t turn)
{
    if (btn & BTN_L)
        *a = (*a - turn) & 0xFFFF;
    if (btn & BTN_R)
        *a = (*a + turn) & 0xFFFF;
    int32_t sgn = (btn & BTN_U) ? 1 : (btn & BTN_D) ? -1 : 0;
    if (sgn) {
        int32_t vx = sgn * mulq(maze_sin[((*a >> 6) + 256) & 1023], speed);
        int32_t vy = sgn * mulq(maze_sin[*a >> 6], speed);
        int32_t tx = *x + vx + (vx > 0 ? MAZE_MARGIN : vx < 0 ? -MAZE_MARGIN : 0);
        if (vx && maze_map[(*y >> 16) * MAZE_N + (tx >> 16)] == 0)
            *x += vx;
        int32_t ty = *y + vy + (vy > 0 ? MAZE_MARGIN : vy < 0 ? -MAZE_MARGIN : 0);
        if (vy && maze_map[(ty >> 16) * MAZE_N + (*x >> 16)] == 0)
            *y += vy;
    }
}

/* ---- the autopilot (the scripted test path): tools/raycast.py's
 * Autopilot, step for step - xorshift32 targets among the free cells, the BFS shortest path
 * (neighbours E, S, W, N), quarter turns, walk until the next cell's centre is passed. */
static uint32_t ap_rng;                                     /* set by ap_reset(): .data must stay empty (BTNC) */
static uint32_t ap_target;                                  /* race mode: the next target cell; else 0xFFFF (random) */
static uint16_t ap_path[MAZE_N * MAZE_N], ap_len, ap_pos;    /* cells y * 24 + x */
static uint16_t ap_prev[MAZE_N * MAZE_N], ap_queue[MAZE_N * MAZE_N];
static uint16_t ap_free[MAZE_N * MAZE_N], ap_nfree;

static void ap_reset(void)
{
    ap_rng = 2026u;
    ap_len = ap_pos = 0;
    ap_nfree = 0;
    for (uint32_t i = 0; i < MAZE_N * MAZE_N; i++)
        if (maze_map[i] == 0)
            ap_free[ap_nfree++] = (uint16_t)i;
}

static uint32_t ap_rand(void)
{
    uint32_t v = ap_rng;
    v ^= v << 13;
    v ^= v >> 17;
    v ^= v << 5;
    ap_rng = v;
    return v;
}

static void ap_bfs(uint32_t from, uint32_t to)
{
    static const int8_t dxy[4][2] = {{1, 0}, {0, 1}, {-1, 0}, {0, -1}};
    for (uint32_t i = 0; i < MAZE_N * MAZE_N; i++)
        ap_prev[i] = 0xFFFFu;
    uint32_t head = 0, tail = 0;
    ap_prev[from] = (uint16_t)from;
    ap_queue[tail++] = (uint16_t)from;
    while (head < tail) {
        uint32_t c = ap_queue[head++];
        if (c == to)
            break;
        for (uint32_t d = 0; d < 4; d++) {
            uint32_t n = (uint32_t)((int32_t)c + dxy[d][0] + MAZE_N * dxy[d][1]);
            if (maze_map[n] == 0 && ap_prev[n] == 0xFFFFu) {
                ap_prev[n] = (uint16_t)c;
                ap_queue[tail++] = (uint16_t)n;
            }
        }
    }
    uint32_t n = 0;
    for (uint32_t c = to; c != from; c = ap_prev[c])
        ap_queue[n++] = (uint16_t)c;               /* reversed path, reusing the queue */
    ap_len = (uint16_t)n;
    ap_pos = 0;
    for (uint32_t i = 0; i < n; i++)
        ap_path[i] = ap_queue[n - 1 - i];
}

static uint32_t ap_step(int32_t x, int32_t y, int32_t a)
{
    for (;;) {
        uint32_t cx = (uint32_t)(x >> 16), cy = (uint32_t)(y >> 16), cell = cy * MAZE_N + cx;
        while (ap_pos == ap_len) {
            uint32_t t = ap_target != 0xFFFFu ? ap_target : ap_free[ap_rand() % ap_nfree];
            if (t != cell)
                ap_bfs(cell, t);
        }
        uint32_t nx = ap_path[ap_pos] % MAZE_N, ny = ap_path[ap_pos] / MAZE_N;
        if (nx == cx && ny == cy) {                /* inside the next cell: walk to its centre */
            int32_t ctrx = (int32_t)(nx << 16) + 32768, ctry = (int32_t)(ny << 16) + 32768;
            int32_t dx = maze_sin[((a >> 6) + 256) & 1023], dy = maze_sin[a >> 6];
            int64_t past = (int64_t)(x - ctrx) * dx + (int64_t)(y - ctry) * dy;
            if (past >= 0) {
                ap_pos++;
                if (ap_pos != ap_len)
                    continue;                      /* the next cell, from the same pose */
                return 0u;
            }
            return BTN_U;
        }
        int32_t want = (nx == cx + 1u) ? 0 : (ny == cy + 1u) ? 16384 : (nx + 1u == cx) ? 32768 : 49152;
        if (a != want)
            return (((want - a) & 0xFFFF) < 32768) ? BTN_R : BTN_L;
        return BTN_U;
    }
}

static uint32_t frame_hash(uint32_t h)
{
    for (uint32_t c = 0; c < g_ncols; c++) {
        h = (h ^ MAZE_COLS_RAM[16 + 2 * c]) * 0x01000193u;
        h = (h ^ (MAZE_COLS_RAM[17 + 2 * c] & 0xFDu)) * 0x01000193u;   /* side | light << 2, not the core */
    }
    return h;
}

/* the light trails the player: one past position per frame; scripted: the one MAZE_LIGHT_LAG_SCRIPT
 * frames earlier (tools/raycast.py light_script), live: the newest one at least 1 s old */
static int32_t lt_x[MAZE_LIGHT_RING], lt_y[MAZE_LIGHT_RING];
static uint32_t lt_t[MAZE_LIGHT_RING];

static void light_pick(uint32_t k, uint32_t scripted, uint32_t now)
{
    uint32_t j;
    if (scripted) {
        j = k >= MAZE_LIGHT_LAG_SCRIPT ? k - MAZE_LIGHT_LAG_SCRIPT : 0u;
    } else {
        uint32_t oldest = k >= MAZE_LIGHT_RING - 1u ? k - (MAZE_LIGHT_RING - 1u) : 0u;
        j = k;
        while (j > oldest && now - lt_t[j % MAZE_LIGHT_RING] < MAZE_LIGHT_LAG_TICKS)
            j--;
    }
    g_lx = lt_x[j % MAZE_LIGHT_RING];
    g_ly = lt_y[j % MAZE_LIGHT_RING];
}

/* ---- the game (Light Hunt, tools/raycast.py got_after / beacon / map_packet) ---- */
static void game_map(uint32_t got)                /* the map with the game state -> MAZEMAP packet */
{
    for (uint32_t i = 0; i < MAZE_N * MAZE_N; i++)
        MAZE_MAP_RAM[i] = maze_map[i];
    for (uint32_t i = 0; i < MAZE_N_ORBS; i++)
        if (!((got >> i) & 1u))
            MAZE_MAP_RAM[maze_orb[i]] = (uint8_t)(MAZE_CELL_ORB + i);
    MAZE_MAP_RAM[MAZE_EXIT] = got == GAME_ALL ? MAZE_CELL_OPEN : MAZE_CELL_EXIT;
    MAZEMAP = 1u;
}

static void game_beacon(uint32_t got)
{
    uint32_t c = MAZE_EXIT;
    for (uint32_t i = MAZE_N_ORBS; i-- > 0;)
        if (!((got >> i) & 1u))
            c = maze_orb[i];
    g_bx = (int32_t)((c % MAZE_N) << 16) + 32768;
    g_by = (int32_t)((c / MAZE_N) << 16) + 32768;
}

static uint32_t popcount(uint32_t v)
{
    uint32_t n = 0;
    for (; v; v &= v - 1u)
        n++;
    return n;
}

/* the game clock in ms from TIMER (CYCLES, 32 bits, wraps after 86 s) */
static uint32_t gm_ms, gm_sub, gm_t;

static void game_tick(void)
{
    uint32_t t = TIMER;
    gm_sub += t - gm_t;
    gm_t = t;
    gm_ms += gm_sub / 50000u;
    gm_sub %= 50000u;
}

/* the board: LED15..11 = orbs picked up, LED10 = the exit open; 7-segment "n   ttt.t": orbs, seconds */
static void game_show(uint32_t got)
{
    uint32_t n = popcount(got), tenths = gm_ms / 100u;
    if (tenths > 9999u)
        tenths = 9999u;
    uint32_t leds = 0;
    for (uint32_t i = 0; i < MAZE_N_ORBS; i++)
        leds |= ((got >> i) & 1u) << (15u - i);
    LEDS = leds | (got == GAME_ALL ? 1u << 10 : 0u);
    SEG7 = n * 10000000u + tenths;
    SEG7_TXT = 0x0FFF0000u | (n ? 0u : 11u << 28);    /* digits 6..4 blank; "0" for no orb yet */
    SEG7_DP = 0x02u;
}

/* every orb and the exit: "d0nE" and the time on the 7-segment display, STATS (checksum = the
 * game time in ms since BTNC), the LEDs blink; BTNC starts a new game */
static void game_won(void)
{
    game_tick();
    uint32_t tenths = gm_ms / 100u;
    SEG7 = tenths > 9999u ? 9999u : tenths;
    SEG7_TXT = 0x5B6E0000u;                          /* d 0 n E */
    SEG7_DP = 0x02u;
    RUN_STOP = 1u;
    CHECKSUM = gm_ms;
    for (;;)
        LEDS = ((TIMER >> 24) & 1u) ? 0xFFFBu : 0x0400u;
}

uint32_t maze_run(uint32_t id, uint32_t ncores)
{
    uint32_t cfg = CONFIG;
    uint32_t scripted = (cfg >> 14) & 1u;
    uint32_t detail = (cfg >> 5) & 1u;            /* SW5: detail mode (1 core = 80 columns) */
    uint32_t race = scripted & (cfg >> 6);        /* SW14 + SW6: race mode */
    if (id != 0u) {
        for (;;) {                                /* core 1: draw when asked, every frame */
            (void)BARRIER;
            if (g_ncols_cores == 2u)
                cast_columns(1u, 2u, 1u);
            (void)BARRIER;
        }
    }
    int32_t x = MAZE_START_X, y = MAZE_START_Y, a = MAZE_START_A;   /* BTNC: a new game */
    uint32_t got = 0u;
    RUN_START = 1u;
    gm_ms = gm_sub = 0u;                          /* the game clock starts */
    gm_t = TIMER;
    game_map(got);                                /* the map for the dashboard's minimap */
    uint32_t hash = 0x811C9DC5u;
    uint32_t t_prev = TIMER;
    ap_reset();
    ap_target = 0xFFFFu;
    for (uint32_t k = 0;; k++) {
        uint32_t t0 = CYCLES, now = TIMER;
        uint32_t cell = (uint32_t)(y >> 16) * MAZE_N + (uint32_t)(x >> 16), was = got;
        for (uint32_t i = 0; i < MAZE_N_ORBS; i++)
            if (cell == maze_orb[i])
                got |= 1u << i;
        if (race && (got & ((1u << MAZE_RACE_ORBS) - 1u)) == (1u << MAZE_RACE_ORBS) - 1u)
            finish(hash, MAZE_GOLD_RACE);         /* the race is over; never returns */
        if (!scripted && got == GAME_ALL && cell == MAZE_EXIT)
            game_won();                           /* never returns */
        if (got != was)
            game_map(got);
        game_beacon(got);
        game_tick();
        game_show(got);
        g_x = x; g_y = y; g_a = a;
        lt_x[k % MAZE_LIGHT_RING] = x;
        lt_y[k % MAZE_LIGHT_RING] = y;
        lt_t[k % MAZE_LIGHT_RING] = now;
        light_pick(k, scripted, now);
        g_ncols_cores = (ncores == 2u && ((SWITCHES >> 2) & 1u)) ? 2u : 1u;
        g_ncols = (detail && g_ncols_cores == 1u) ? MAZE_COLS_LOW : MAZE_COLS;
        g_camx = g_ncols == MAZE_COLS ? maze_camx : maze_camx_low;
        MAZE_COLS_RAM[0] = (uint8_t)k;
        MAZE_COLS_RAM[1] = (uint8_t)g_ncols;
        MAZE_COLS_RAM[4] = (uint8_t)(x >> 8);  MAZE_COLS_RAM[5] = (uint8_t)(x >> 16);
        MAZE_COLS_RAM[6] = (uint8_t)(y >> 8);  MAZE_COLS_RAM[7] = (uint8_t)(y >> 16);
        MAZE_COLS_RAM[8] = (uint8_t)a;         MAZE_COLS_RAM[9] = (uint8_t)(a >> 8);
        (void)BARRIER;
        cast_columns(0u, g_ncols_cores, 0u);
        (void)BARRIER;
        MAZEFRAME = CYCLES - t0;                  /* the measurement: cycles of this frame */
        if (scripted) {                           /* the autopilot with large steps: the test path */
            hash = frame_hash(hash);
            if (race) {                           /* the next target: the lowest orb not picked up */
                uint32_t i = 0;
                while ((got >> i) & 1u)
                    i++;
                ap_target = maze_orb[i];
                move(&x, &y, &a, ap_step(x, y, a), MAZE_RACE_SPEED, MAZE_RACE_TURN);
            } else {
                if (k + 1u == MAZE_SCRIPT_N)
                    finish(hash, g_ncols == MAZE_COLS ? MAZE_GOLD : MAZE_GOLD_LOW);   /* never returns */
                move(&x, &y, &a, ap_step(x, y, a), MAZE_SPEED_SCRIPT, MAZE_TURN_SCRIPT);
            }
        } else {                                  /* steps follow real time: the walk and the light */
            uint32_t tn = TIMER, dt = tn - t_prev;   /* move at the same speed with 1 or 2 cores; */
            t_prev = tn;                          /* only the frame rate (smoothness) differs */
            int32_t speed = (int32_t)((dt >> MAZE_SPEED_SHIFT) + (dt >> (MAZE_SPEED_SHIFT + 1)));
            int32_t turn = (int32_t)((dt >> MAZE_TURN_SHIFT) + (dt >> (MAZE_TURN_SHIFT + 1)));
            if (speed > MAZE_SPEED_CAP) speed = MAZE_SPEED_CAP;
            if (turn > MAZE_TURN_CAP) turn = MAZE_TURN_CAP;
            move(&x, &y, &a, BUTTONS, speed, turn);   /* only the player's presses move it */
        }
    }
}
