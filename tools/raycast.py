"""raycast.py - the reference raycaster of maze mode (docs/spec/raycaster_demo.md).

    python tools/raycast.py --check              self-test
    python tools/raycast.py --header FILE        write the C header the firmware uses (fw/maze_data.h)
    python tools/raycast.py --golden FILE [N]    write the golden columns of the first N frames
                                                 (default 240) of the scripted path

The golden model. The firmware (fw/maze.c) must give the same (height, attr) for every column of
every frame, bit for bit, so every operation below is integer and exactly specified:

* Fixed point Q16.16 in 32 bits. mul(a, b) = (a * b) >> 16 on the full product (arithmetic shift,
  rounds towards minus infinity). Distances are unsigned; additions of distances saturate at
  0xFFFFFFFF. Divisions are 32-bit unsigned, rounding towards zero (the RV32M DIVU).
* Angles: 0..65535 for a full turn; the table has 1024 entries, indexed by the top 10 bits:
  SIN[i] = round(65536 * sin(2 pi i / 1024)), sin(a) = SIN[a >> 6], cos(a) = SIN[((a >> 6) + 256) & 1023].
* Camera: dir = (cos a, sin a), plane = (-sin a, cos a) x PLANE (PLANE = round(65536 * tan 30 deg):
  a 60 degree field of view). Column c (0..159): camera x = CAMX[c] = round(65536 * (2c + 1 - 160) / 160),
  ray = dir + mul(plane, CAMX[c]).
* Detail mode (SW5 up at reset, maze mode): the same frame budget for 1 and 2 cores. 2 cores draw
  the 160 columns; 1 core draws W_LOW = 80 columns over the same 60 degrees (CAMX_LOW, each shown
  twice as wide): the same frame rate, half the detail. Otherwise 160 columns and 1 core is half as fast.
* DDA (grid stepping, no per-step Euclidean distance): delta = 0xFFFFFFFF // |ray| per axis
  (0xFFFFFFFF if the ray component is 0); the first side distance is mul(the fraction to the next
  grid line, delta); step the smaller side distance (X on a tie) until a wall cell. The
  perpendicular distance = that side distance - its delta: the camera-plane method gives the
  distance perpendicular to the view, which removes the fisheye (it equals the ray length x
  cos(ray angle - player angle)). height = min(255, (240 << 16) // max(perp, 1)): the full strip
  height on a 240-row screen. attr bit 0 = the side hit (0: a vertical grid line, E/W wall; 1: a
  horizontal one, N/S wall); bits 2:1 = the core that drew the column (filled by the firmware).
* The moving light (soft shadows): a light trails the player (its position 1 s earlier live,
  LIGHT_LAG_SCRIPT frames earlier on the scripted path), so it always lights the walls around the
  player and lags around corners, sweeping their shadows across the walls. For every column, SHADOW_N shadow rays go from the wall point the column sees (EPS off
  the wall, in the free cell in front) to points spread over the light's disc (LIGHT_DISC, radius
  LIGHT_R); each is a grid DDA in segment units (t = ONE at the target) that stops at a wall cell
  (shadowed) or at t >= ONE (lit). level = falloff x facing x lit share, 0..63:
  falloff = (63 << 16) // (ONE + d2 >> 3) with d2 the squared distance to the light's centre,
  facing = (component towards the light along the wall's normal << 8) // (|vx| + |vy|) (0 when the
  wall faces away). Two lights, SHADOW_N rays each: the lantern (above) and the beacon (the game, below);
  level = min(63, lantern + beacon). attr = side | core << 1 | level << 2. All rays are traced in every case, so a
  column costs about the same wherever the light is: this is what makes a frame heavy enough that
  1 and 2 cores show different frame rates on the screen.
* Movement per frame from the buttons (BTNL bit 0, BTNR bit 1, BTNU bit 2, BTND bit 3): turn by
  turn angle units; walk speed forward / back along dir; each axis moves only if the cell at the
  new position plus MARGIN in the direction of travel is free. Live: the step follows real time
  (with c the cycles since the last frame: (c >> SPEED_SHIFT) + (c >> SPEED_SHIFT + 1), the same with TURN_SHIFT for turns), so the walk and the
  light move at the same speed with 1 or 2 cores, and only the smoothness changes. SCRIPT: large
  fixed steps for the scripted test path.
* The map: a 24 x 24 grid, a perfect maze carved from a fixed seed on 11 x 11 rooms with a few
  extra openings (loops), surrounded by wall. 0 = free, 1 = wall.
* The game (Light Hunt): ORBS, five cells to visit in any order, then EXIT. An orb is picked up at
  the start of the first frame whose pose is in its cell. The beacon stands at the centre of the
  lowest orb not yet picked up (the exit once all are). The player wins at the start of a frame in
  the exit cell with every orb picked up. The MAZEMAP packet carries the state (map_packet).
* Race mode (SW14 + SW6 at reset): the autopilot plays the game (race_script): its targets are the
  orbs in order, its steps RACE_SPEED / RACE_TURN per frame, and it ends at the pickup of orb
  RACE_ORBS - 1. A step per frame, not per second: with fewer frames per second the race ends later.
* The scripted path: the autopilot (class Autopilot: seeded random target cells reached along
  BFS shortest paths, quarter turns, cell centre to cell centre) produces the button mask of
  every frame; the scripted path is its first frames from the start pose.
"""
import math
import random
import sys

W_COLS, SCREEN_H, MAP_N = 160, 240, 24
SCRIPT_N = 96                                            # frames of the scripted path (SW14 at reset)
ONE = 1 << 16
U32 = 0xFFFFFFFF
SIN = [int(round(65536 * math.sin(2 * math.pi * i / 1024))) for i in range(1024)]
PLANE = int(round(65536 * math.tan(math.radians(30))))
W_LOW = 80                                               # detail mode (SW5), 1 core: half the columns
CAMX = [int(round(65536 * (2 * c + 1 - W_COLS) / W_COLS)) for c in range(W_COLS)]
CAMX_LOW = [int(round(65536 * (2 * c + 1 - W_LOW) / W_LOW)) for c in range(W_LOW)]
MARGIN = int(round(0.25 * ONE))
SPEED_SCRIPT, TURN_SCRIPT = int(round(0.08 * ONE)), 1024  # the scripted test path: 16 frames a quarter turn
RACE_SPEED, RACE_TURN = int(round(0.2 * ONE)), 4096      # race mode (SW14 + SW6): 4 frames a quarter turn
RACE_ORBS = 2                                            # the race ends at the pickup of orb RACE_ORBS - 1
# the moving light (soft shadows): SHADOW_N shadow rays per column to points on the light's disc
SHADOW_N = 96                                            # per light: the lantern and the beacon
SHADOW_STEPS = 64                                        # cells a shadow ray may cross
EPS = 256                                                # 1/256 cell: the shadow ray starts off the wall
LIGHT_R = 0.3                                            # disc radius in cells (soft shadow edges)
LIGHT_LAG_SCRIPT = 12                                    # scripted path: the light = the position 12 frames earlier
LIGHT_LAG_TICKS = 50000000                               # live: the position 1 s earlier (50 MHz)
LIGHT_RING = 64                                          # live: past positions kept (one per frame)
SPEED_SHIFT, SPEED_CAP = 9, int(round(0.45 * ONE))       # live walk: (cycles >> 9) + (cycles >> 10) per frame (2.24 cells/s)
TURN_SHIFT, TURN_CAP = 11, 8192                          # live turn: (cycles >> 11) + (cycles >> 12) per frame (201 deg/s)
LIGHT_DISC = [(int(round(LIGHT_R * ONE * math.sqrt((k + 0.5) / SHADOW_N) * math.cos(2.399963 * k))),
               int(round(LIGHT_R * ONE * math.sqrt((k + 0.5) / SHADOW_N) * math.sin(2.399963 * k))))
              for k in range(SHADOW_N)]                  # Vogel spiral: even samples over the disc
# the game (Light Hunt): orbs to pick up in any order, then the exit; the beacon = a second light at
# the lowest orb not yet picked up (the exit once all are), so its glow shows the way
ORBS = [(3, 3), (17, 1), (11, 11), (1, 21), (21, 13)]
EXIT = (21, 18)                                          # the free cell farthest from the start
CELL_ORB, CELL_EXIT, CELL_OPEN = 0x10, 0x20, 0x21        # MAZEMAP cells: orb i = 0x10 + i, exit closed / open
BTN_L, BTN_R, BTN_U, BTN_D = 1, 2, 4, 8
START = (int(1.5 * ONE), int(1.5 * ONE), 0)              # x, y (cell units, Q16.16), angle


def mul(a, b):
    return (a * b) >> 16


def i32(v):
    v &= U32
    return v - (1 << 32) if v & 0x80000000 else v


def make_map(seed=2026):
    rng = random.Random(seed)
    g = [[1] * MAP_N for _ in range(MAP_N)]
    n = 11                                               # rooms at odd coordinates 1..21
    seen = {(0, 0)}
    stack = [(0, 0)]
    g[1][1] = 0
    while stack:
        cx, cy = stack[-1]
        nb = [(cx + dx, cy + dy, dx, dy) for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))
              if 0 <= cx + dx < n and 0 <= cy + dy < n and (cx + dx, cy + dy) not in seen]
        if not nb:
            stack.pop()
            continue
        nx, ny, dx, dy = rng.choice(nb)
        g[1 + 2 * cy + dy][1 + 2 * cx + dx] = 0
        g[1 + 2 * ny][1 + 2 * nx] = 0
        seen.add((nx, ny))
        stack.append((nx, ny))
    opened = 0                                           # a few loops: remove interior walls
    while opened < 14:
        x, y = rng.randrange(2, 21), rng.randrange(2, 21)
        if g[y][x] == 1 and ((g[y][x - 1] == 0 and g[y][x + 1] == 0) or (g[y - 1][x] == 0 and g[y + 1][x] == 0)):
            g[y][x] = 0
            opened += 1
    return g


MAP = make_map()


def got_after(ref, k, got=0):
    """The orbs picked up (bit i = orb i) once frame k's pose is reached: an orb is picked up at the
    start of the first frame whose pose is in its cell."""
    for j in range(k + 1):
        x, y, _ = ref[j][1]
        c = (x >> 16, y >> 16)
        for i, o in enumerate(ORBS):
            if o == c:
                got |= 1 << i
    return got


def beacon(got):
    """The beacon's centre (Q16.16) for the picked-up mask got."""
    for i, (ox, oy) in enumerate(ORBS):
        if not got >> i & 1:
            return (ox << 16) + ONE // 2, (oy << 16) + ONE // 2
    return (EXIT[0] << 16) + ONE // 2, (EXIT[1] << 16) + ONE // 2


def map_packet(got):
    """The MAZEMAP cells for the picked-up mask got: 1 wall, 0 free, 0x10 + i orb i still there,
    0x20 the exit (closed), 0x21 (open: every orb picked up)."""
    g = [row[:] for row in MAP]
    for i, (ox, oy) in enumerate(ORBS):
        if not got >> i & 1:
            g[oy][ox] = CELL_ORB + i
    g[EXIT[1]][EXIT[0]] = CELL_OPEN if got == (1 << len(ORBS)) - 1 else CELL_EXIT
    return bytes(v for row in g for v in row)


def light_script(ref, k):
    """The light of scripted frame k: the player's position LIGHT_LAG_SCRIPT frames earlier (the
    start position for the first frames). ref = script(n)."""
    x, y, _ = ref[max(0, k - LIGHT_LAG_SCRIPT)][1]
    return x, y


def shadow_visible(m, px, py, cx, cy, qx, qy):
    """1 if the segment from P (inside free cell cx, cy) to Q crosses no wall cell before Q.
    Grid DDA in segment units: t = ONE at Q; delta = 0xFFFFFFFF // |component| per axis."""
    dx, dy = i32(qx - px), i32(qy - py)
    ddx = U32 // abs(dx) if dx else U32
    ddy = U32 // abs(dy) if dy else U32
    if dx < 0:
        sx, sdx = -1, mul(px - (cx << 16), ddx)
    else:
        sx, sdx = 1, mul(((cx + 1) << 16) - px, ddx)
    if dy < 0:
        sy, sdy = -1, mul(py - (cy << 16), ddy)
    else:
        sy, sdy = 1, mul(((cy + 1) << 16) - py, ddy)
    for _ in range(SHADOW_STEPS):
        if sdx >= ONE and sdy >= ONE:
            return 1
        if sdx <= sdy:
            sdx, cx = min(sdx + ddx, U32), cx + sx
        else:
            sdy, cy = min(sdy + ddy, U32), cy + sy
        if m[cy][cx]:
            return 0
    return 0


def light_level(m, x, y, rx, ry, mx, my, side, sx, sy, perp, lx, ly):
    """Light level 0..63 of the wall point a column sees: SHADOW_N shadow rays from that point (moved
    EPS off the wall, into the free cell in front) to points spread over the light's disc; the share
    that reaches the light x distance falloff x the angle between the wall's normal and the light."""
    if side == 0:
        px = ((mx << 16) if sx > 0 else ((mx + 1) << 16)) - sx * EPS
        py = min(max(y + mul(ry, perp), (my << 16) + EPS), ((my + 1) << 16) - EPS)
        cx, cy = mx - sx, my
    else:
        py = ((my << 16) if sy > 0 else ((my + 1) << 16)) - sy * EPS
        px = min(max(x + mul(rx, perp), (mx << 16) + EPS), ((mx + 1) << 16) - EPS)
        cx, cy = mx, my - sy
    vx, vy = lx - px, ly - py
    dn = -sx * vx if side == 0 else -sy * vy             # towards the light along the wall's normal
    d2 = mul(vx, vx) + mul(vy, vy)
    fall = (63 << 16) // (ONE + (d2 >> 3))               # 63 at the light, 42 at 2 cells, 21 at 4
    lam = (dn << 8) // (abs(vx) + abs(vy)) if dn > 0 else 0   # 0..256: facing the light
    vis = 0
    for ox, oy in LIGHT_DISC:                            # every ray is traced: a steady cost per column
        vis += shadow_visible(m, px, py, cx, cy, lx + ox, ly + oy)
    return (fall * lam * vis) // (SHADOW_N << 8)


def cast(m, x, y, a, light=None, bea=None, ncols=W_COLS):
    """(height, attr) for the ncols (160, or 80 in detail mode with 1 core) columns of pose (x, y, a);
    attr = side | light level << 2, the level = min(63, lantern at light + beacon at bea) (None: no
    light, level 0)."""
    camx = CAMX if ncols == W_COLS else CAMX_LOW
    lx, ly = light if light is not None else (0, 0)
    dx, dy = SIN[((a >> 6) + 256) & 1023], SIN[a >> 6]
    px, py = mul(-dy, PLANE), mul(dx, PLANE)
    out = []
    for c in range(ncols):
        rx = i32(dx + mul(px, camx[c]))
        ry = i32(dy + mul(py, camx[c]))
        mx, my = x >> 16, y >> 16
        ddx = U32 // abs(rx) if rx else U32
        ddy = U32 // abs(ry) if ry else U32
        if rx < 0:
            sx, sdx = -1, mul(x - (mx << 16), ddx)
        else:
            sx, sdx = 1, mul(((mx + 1) << 16) - x, ddx)
        if ry < 0:
            sy, sdy = -1, mul(y - (my << 16), ddy)
        else:
            sy, sdy = 1, mul(((my + 1) << 16) - y, ddy)
        sdx, sdy = min(sdx, U32), min(sdy, U32)
        side, hit = 0, False
        for _ in range(64):
            if sdx <= sdy:
                sdx, mx, side = min(sdx + ddx, U32), mx + sx, 0
            else:
                sdy, my, side = min(sdy + ddy, U32), my + sy, 1
            if m[my][mx]:
                hit = True
                break
        if not hit:
            raise ValueError("ray of column %d from (%d, %d, %d) hit no wall in 64 steps" % (c, x, y, a))
        perp = (sdx - ddx) if side == 0 else (sdy - ddy)
        perp = max(perp & U32, 1)
        lvl = 0
        if light is not None:
            lvl = light_level(m, x, y, rx, ry, mx, my, side, sx, sy, perp, lx, ly) +                 light_level(m, x, y, rx, ry, mx, my, side, sx, sy, perp, bea[0], bea[1])
            lvl = min(lvl, 63)
        out.append((min(255, (SCREEN_H << 16) // perp), side | (lvl << 2)))
    return out


def move(m, pose, btn, speed=SPEED_SCRIPT, turn=TURN_SCRIPT):
    x, y, a = pose
    if btn & BTN_L:
        a = (a - turn) & 0xFFFF
    if btn & BTN_R:
        a = (a + turn) & 0xFFFF
    sgn = 1 if btn & BTN_U else -1 if btn & BTN_D else 0
    if sgn:
        vx, vy = sgn * mul(SIN[((a >> 6) + 256) & 1023], speed), sgn * mul(SIN[a >> 6], speed)
        tx = x + vx + (MARGIN if vx > 0 else -MARGIN if vx < 0 else 0)
        if vx and m[y >> 16][tx >> 16] == 0:
            x += vx
        ty = y + vy + (MARGIN if vy > 0 else -MARGIN if vy < 0 else 0)
        if vy and m[ty >> 16][x >> 16] == 0:
            y += vy
    return (x, y, a)


def bfs(m, a, b):
    """Shortest path of cells from a to b (both free), b included, a excluded; neighbours in the
    order E, S, W, N; ties broken by that order."""
    prev, todo, i = {a: None}, [a], 0
    while i < len(todo):
        c = todo[i]
        i += 1
        if c == b:
            break
        for dx, dy in ((1, 0), (0, 1), (-1, 0), (0, -1)):
            n = (c[0] + dx, c[1] + dy)
            if m[n[1]][n[0]] == 0 and n not in prev:
                prev[n] = c
                todo.append(n)
    path, c = [], b
    while c != a:
        path.append(c)
        c = prev[c]
    return path[::-1]


class Autopilot:
    """Walks the maze on its own (the scripted test path and race mode). Targets: free cells
    from a xorshift32 generator (seed 2026) - the firmware uses the same - reached along the BFS
    shortest path, cell centre to cell centre: turn in quarter turns (the turn step divides 16384),
    then walk until the cell centre is passed."""

    def __init__(self, m, target=None):
        self.m, self.rng, self.path, self.target = m, 2026, [], target
        self.free = [(x, y) for y in range(MAP_N) for x in range(MAP_N) if m[y][x] == 0]

    def rand(self):
        v = self.rng
        v ^= (v << 13) & U32
        v ^= v >> 17
        v ^= (v << 5) & U32
        self.rng = v
        return v

    def step(self, pose):
        x, y, a = pose
        cx, cy = x >> 16, y >> 16
        while not self.path:
            t = self.target() if self.target else self.free[self.rand() % len(self.free)]
            if t != (cx, cy):
                self.path = bfs(self.m, (cx, cy), t)
        nx, ny = self.path[0]
        want = {(1, 0): 0, (0, 1): 16384, (-1, 0): 32768, (0, -1): 49152}[(nx - cx, ny - cy)] if (nx, ny) != (cx, cy) else a
        if (nx, ny) == (cx, cy):                         # inside the next cell: walk to its centre
            ctr = ((nx << 16) + ONE // 2, (ny << 16) + ONE // 2)
            dx, dy = SIN[((a >> 6) + 256) & 1023], SIN[a >> 6]
            past = (x - ctr[0]) * dx + (y - ctr[1]) * dy >= 0
            if past:
                self.path.pop(0)
                return self.step(pose) if self.path else 0
            return BTN_U
        if a != want:
            return BTN_R if ((want - a) & 0xFFFF) < 32768 else BTN_L
        return BTN_U


def script(n):
    """The scripted path: (button mask, pose before the frame) for frames 0..n-1."""
    pose, ap, out = START, Autopilot(MAP), []
    for _ in range(n):
        b = ap.step(pose)
        out.append((b, pose))
        pose = move(MAP, pose, b)
    return out


def race_script():
    """Race mode (SW14 + SW6 at reset): the autopilot plays the game with RACE_SPEED / RACE_TURN steps;
    its next target is the lowest orb not yet picked up. Every frame moves the same step, so fewer
    frames per second means a later finish. Returns (button mask, pose) of every frame drawn; the
    race ends at the start of the frame whose pose picks up orb RACE_ORBS - 1 (not drawn)."""
    state = {"got": 0}

    def target():
        i = next(j for j in range(len(ORBS)) if not state["got"] >> j & 1)
        return ORBS[i]

    pose, ap, out = START, Autopilot(MAP, target), []
    done = (1 << RACE_ORBS) - 1
    while True:
        c = (pose[0] >> 16, pose[1] >> 16)
        for i, o in enumerate(ORBS):
            if o == c:
                state["got"] |= 1 << i
        if state["got"] & done == done:
            return out
        b = ap.step(pose)
        out.append((b, pose))
        pose = move(MAP, pose, b, RACE_SPEED, RACE_TURN)


def frame_hash(h, cols):
    """fnv1a over (height, side | light << 2) of every column: the scripted run's checksum (core ids
    excluded, so 1 and 2 cores give the same value)."""
    for hh, attr in cols:
        for byte in (hh, attr):
            h = ((h ^ byte) * 0x01000193) & U32
    return h


def frame(ref, k, ncols=W_COLS):
    """The reference columns of scripted frame k (ref = script(n), n > k)."""
    x, y, a = ref[k][1]
    return cast(MAP, x, y, a, light_script(ref, k), beacon(got_after(ref, k)), ncols)


def gold(n=SCRIPT_N, ncols=W_COLS, ref=None):
    h, ref = 0x811C9DC5, ref or script(n)
    for k in range(len(ref)):
        h = frame_hash(h, frame(ref, k, ncols))
    return h


def header(path):
    lines = ["/* maze_data.h - generated by tools/raycast.py: do not edit. The reference and the firmware",
             " * share these tables, so they agree bit for bit. */",
             "#ifndef MAZE_DATA_H", "#define MAZE_DATA_H", "#include <stdint.h>", "",
             "#define MAZE_N %d" % MAP_N, "#define MAZE_COLS %d" % W_COLS, "#define MAZE_SCREEN_H %d" % SCREEN_H,
             "#define MAZE_PLANE %d" % PLANE,
             "#define MAZE_SPEED_SHIFT %d" % SPEED_SHIFT, "#define MAZE_SPEED_CAP %d" % SPEED_CAP,
             "#define MAZE_TURN_SHIFT %d" % TURN_SHIFT, "#define MAZE_TURN_CAP %d" % TURN_CAP,
             "#define MAZE_SPEED_SCRIPT %d" % SPEED_SCRIPT, "#define MAZE_TURN_SCRIPT %d" % TURN_SCRIPT,
             "#define MAZE_MARGIN %d" % MARGIN,
             "#define MAZE_START_X %d" % START[0], "#define MAZE_START_Y %d" % START[1], "#define MAZE_START_A %d" % START[2],
             "#define MAZE_SHADOW_N %d" % SHADOW_N,
             "#define MAZE_SHADOW_STEPS %d" % SHADOW_STEPS, "#define MAZE_EPS %d" % EPS,
             "#define MAZE_LIGHT_LAG_SCRIPT %d" % LIGHT_LAG_SCRIPT, "#define MAZE_LIGHT_LAG_TICKS %du" % LIGHT_LAG_TICKS,
             "#define MAZE_LIGHT_RING %d" % LIGHT_RING,
             "#define MAZE_SCRIPT_N %d" % SCRIPT_N,
             "#define MAZE_N_ORBS %d" % len(ORBS), "#define MAZE_EXIT %d   /* cell y * 24 + x */" % (EXIT[1] * MAP_N + EXIT[0]),
             "#define MAZE_CELL_ORB 0x%02X" % CELL_ORB, "#define MAZE_CELL_EXIT 0x%02X" % CELL_EXIT,
             "#define MAZE_CELL_OPEN 0x%02X" % CELL_OPEN,
             "#define MAZE_GOLD 0x%08Xu   /* fnv1a of the scripted run's (height, side | light << 2) */" % gold(),
             "#define MAZE_RACE_SPEED %d" % RACE_SPEED, "#define MAZE_RACE_TURN %d" % RACE_TURN,
             "#define MAZE_RACE_ORBS %d" % RACE_ORBS,
             "#define MAZE_GOLD_RACE 0x%08Xu   /* the race (SW14 + SW6), 160 columns */" % gold(ref=race_script()),
             "#define MAZE_COLS_LOW %d   /* detail mode (SW5), 1 core */" % W_LOW,
             "#define MAZE_GOLD_LOW 0x%08Xu   /* the same with MAZE_COLS_LOW columns */" % gold(ncols=W_LOW), "",
             "static const uint8_t maze_map[MAZE_N * MAZE_N] = {"]
    for row in MAP:
        lines.append("    " + ", ".join(str(v) for v in row) + ",")
    lines += ["};", "", "/* the orbs' cells, y * 24 + x */",
              "static const uint16_t maze_orb[MAZE_N_ORBS] = {%s};" % ", ".join(str(oy * MAP_N + ox) for ox, oy in ORBS),
              "", "/* shadow-ray targets: offsets (Q16.16) over the light's disc */",
              "static const int32_t maze_light_disc[MAZE_SHADOW_N][2] = {"]
    for i in range(0, SHADOW_N, 4):
        lines.append("    " + ", ".join("{%d, %d}" % d for d in LIGHT_DISC[i:i + 4]) + ",")
    lines += ["};", "", "static const int32_t maze_sin[1024] = {"]
    for i in range(0, 1024, 8):
        lines.append("    " + ", ".join(str(v) for v in SIN[i:i + 8]) + ",")
    lines += ["};", "", "static const int32_t maze_camx[MAZE_COLS] = {"]
    for i in range(0, W_COLS, 8):
        lines.append("    " + ", ".join(str(v) for v in CAMX[i:i + 8]) + ",")
    lines += ["};", "", "static const int32_t maze_camx_low[MAZE_COLS_LOW] = {"]
    for i in range(0, W_LOW, 8):
        lines.append("    " + ", ".join(str(v) for v in CAMX_LOW[i:i + 8]) + ",")
    lines += ["};", "", "#endif", ""]
    open(path, "w", newline="\n").write("\n".join(lines))


def golden(path, n):
    with open(path, "w", newline="\n") as f:
        f.write("# frame btn x y a : 160 x (height attr: side | light << 2)\n")
        ref = script(n)
        for k, (b, (x, y, a)) in enumerate(ref):
            cols = frame(ref, k)
            f.write("%d %x %d %d %d : %s\n" % (k, b, x, y, a, " ".join("%d.%d" % hc for hc in cols)))


def self_test():
    m = MAP
    assert len(m) == MAP_N and all(len(r) == MAP_N for r in m)
    assert all(m[0][i] and m[MAP_N - 1][i] and m[i][0] and m[i][MAP_N - 1] for i in range(MAP_N))
    assert m[START[1] >> 16][START[0] >> 16] == 0
    # every free cell reachable from the start (a connected maze)
    free = {(x, y) for y in range(MAP_N) for x in range(MAP_N) if m[y][x] == 0}
    todo, seen = [(1, 1)], {(1, 1)}
    while todo:
        x, y = todo.pop()
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if (nx, ny) in free and (nx, ny) not in seen:
                seen.add((nx, ny))
                todo.append((nx, ny))
    assert seen == free, "maze not connected"
    # symmetry: facing a flat wall head-on, column c and 159 - c have the same height
    open_box = [[1] * MAP_N for _ in range(MAP_N)]
    for yy in range(1, 23):
        for xx in range(1, 23):
            open_box[yy][xx] = 0
    cols = cast(open_box, 12 * ONE + ONE // 2, 12 * ONE + ONE // 2, 0)
    assert all(abs(cols[c][0] - cols[159 - c][0]) <= 1 for c in range(80)), "not symmetric"
    # no fisheye: on a flat wall every column has the same perpendicular distance -> height
    assert max(h for h, _ in cols) - min(h for h, _ in cols) <= 1, "fisheye: %s" % [h for h, _ in cols[:5]]
    # nearer wall = taller: 10.5 cells -> 240 / 10.5 = 22.86
    assert cols[80][0] == 22, cols[80]
    # the scripted path stays in free cells, moves and turns
    path = script(600)
    assert all(m[y >> 16][x >> 16] == 0 for _, (x, y, _) in path)
    for _, (x, y, a) in path[::10]:                      # every ray of the path hits a wall
        cast(m, x, y, a)
    assert len({(x >> 16, y >> 16) for _, (x, y, _) in path}) > 8, "the autopilot does not explore"
    # a light 2 cells in front of a wall the player faces head-on: lit; the same light behind the player: dark wall
    box = [[1] * MAP_N for _ in range(MAP_N)]
    for yy in range(1, 23):
        for xx in range(1, 23):
            box[yy][xx] = 0
    cols = cast(box, 12 * ONE + ONE // 2, 12 * ONE + ONE // 2, 0, None)
    lit = light_level(box, 12 * ONE + ONE // 2, 12 * ONE + ONE // 2, ONE, 0, 23, 12, 0, 1, 1,
                      int(10.5 * ONE), 21 * ONE, 12 * ONE + ONE // 2)
    dark = light_level(box, 12 * ONE + ONE // 2, 12 * ONE + ONE // 2, ONE, 0, 23, 12, 0, 1, 1,
                       int(10.5 * ONE), 23 * ONE + ONE // 2, 12 * ONE + ONE // 2)
    assert 20 <= lit <= 63 and dark == 0, (lit, dark)
    lit_cols = 0
    for k in range(0, SCRIPT_N, 7):
        for h, attr in frame(path, k):
            assert 0 <= attr >> 2 <= 63
            lit_cols += (attr >> 2) > 0
    assert lit_cols > 200, "the trailing light lights too few columns: %d" % lit_cols
    # the game: orbs and the exit on free, distinct cells, all reachable; the scripted path picks up orb 0
    assert all(m[y][x] == 0 for x, y in ORBS + [EXIT]) and len(set(ORBS + [EXIT])) == len(ORBS) + 1
    assert all((x, y) in seen for x, y in ORBS + [EXIT])
    assert got_after(path, 0) == 0 and got_after(path, SCRIPT_N - 1) == 1, got_after(path, SCRIPT_N - 1)
    assert beacon(0) != beacon(1) and map_packet(0) != map_packet(1)
    assert map_packet((1 << len(ORBS)) - 1).count(CELL_OPEN) == 1
    race = race_script()
    assert 150 < len(race) < 400 and got_after(race, len(race) - 1) == 1, (len(race), got_after(race, len(race) - 1))
    x, y, _ = move(MAP, race[-1][1], race[-1][0], RACE_SPEED, RACE_TURN)
    assert (x >> 16, y >> 16) == ORBS[1]
    return True


def main():
    a = sys.argv[1:]
    if a == ["--check"]:
        print("raycast self-test:", "PASS" if self_test() else "FAIL")
    elif len(a) == 2 and a[0] == "--header":
        header(a[1])
        print("wrote", a[1])
    elif len(a) in (2, 3) and a[0] == "--golden":
        golden(a[1], int(a[2]) if len(a) == 3 else 240)
        print("wrote", a[1])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
