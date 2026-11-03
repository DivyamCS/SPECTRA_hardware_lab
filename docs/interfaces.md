# SPECTRA module interfaces v1.0

Modules connect only through these four interfaces. No module reads another module's internal
signals. All signals are synchronous to the 50 MHz core clock `clk`, active high, and sampled on
the rising edge; `rst` is the synchronised reset from `clk_rst` (active high). Numbers come from
`docs/PROTOCOL.md`, which wins if the two ever differ.

| Interface | Connects | Section |
| --- | --- | --- |
| IF-A data port | core -> rr_arbiter -> addr_decode -> D-cache or mmio_bus | 1 |
| IF-B memory burst | D-cache, I-cache -> mem_delay -> BRAM | 2 |
| IF-C MMIO bus | addr_decode -> mmio_bus -> register blocks | 3 |
| IF-D config word | switch_cfg -> every block | 4 |

## 1. IF-A data port

One request at a time per master. The core is the master; the arbiter is a slave to each core
and a master downstream.

| Signal | Width | Direction | Meaning |
| --- | --- | --- | --- |
| `req` | 1 | master -> slave | a request is presented |
| `we` | 1 | master -> slave | 1 = store, 0 = load |
| `addr` | 32 | master -> slave | byte address; aligned to the access size |
| `wdata` | 32 | master -> slave | store data already placed in its byte lanes |
| `be` | 4 | master -> slave | byte enables: lanes written by a store, lanes wanted by a load |
| `rdata` | 32 | slave -> master | the whole aligned word; valid only in the `ready` cycle of a load |
| `ready` | 1 | slave -> master | 1-cycle pulse: the request is complete |
| `owner` | 1 | arbiter -> downstream | core that owns the request (0 or 1); added by rr_arbiter |

Rules:
1. A master raises `req` with all fields valid and holds every field stable until the cycle in
   which `ready` = 1. It may present the next request in the cycle after `ready`.
2. `ready` is a 1-cycle pulse, never asserted without `req`. Loads take `rdata` in that cycle;
   sign or zero extension is done in the core (MEM/WB), not by the slave.
3. Timing seen by the core, counting the cycle `req` rises as cycle 1: D-cache hit or MMIO
   access -> `ready` in cycle 2 (2 cycles in MEM/WB, 1 stall); D-cache miss, clean victim ->
   cycle 2 + (L + 4); dirty victim -> 2 + 2(L + 4); uncached (DC = 0) ->
   2 + (L + 1). Waiting for the arbiter adds cycles before these (counted as ARB_WAIT).
4. Loads to x0 still issue a request (a BARRIER read into x0 must still wait; PROTOCOL.md v1.1).
5. Address map (addr_decode): 0x1000_0000-0x1001_FFFF -> D-cache; 0x2000_0000-0x2000_00FF ->
   MMIO (32-bit accesses only); anything else -> `ready` after 2 cycles, `rdata` = 0, store
   dropped, decode-error flag (LED2) set.
6. Out of reset: `req` = 0.

## 2. IF-B memory burst

Between a cache (master) and its `mem_delay` (slave), which fronts the BRAM.

| Signal | Width | Direction | Meaning |
| --- | --- | --- | --- |
| `start` | 1 | master -> slave | 1-cycle pulse: begin a burst |
| `we` | 1 | master -> slave | 1 = write burst, 0 = read burst |
| `addr` | 30 | master -> slave | word address `[31:2]` of the first word |
| `nwords` | 1 | master -> slave | 0 = 1 word, 1 = 4 words (a 16-byte line) |
| `wdata` | 32 | master -> slave | write word, advanced by the master on each `wready` |
| `be` | 4 | master -> slave | byte enables of a 1-word write (sub-word store with DC = 0); 1111 for line writes; ignored on reads |
| `rvalid` | 1 | slave -> master | `rdata` holds the next read word |
| `rdata` | 32 | slave -> master | read word |
| `wready` | 1 | slave -> master | the slave took `wdata` this cycle |
| `done` | 1 | slave -> master | 1-cycle pulse with the last word |

Rules:
1. `start` only when no burst is open (between `start` and `done`). `we`, `addr` and `nwords`
   are held from `start` until `done`.
2. With `start` in cycle 0, words move in cycles L, L+1, ..., L + n - 1 (n = 1 or 4), one per
   cycle, in increasing address order (a line burst starts at word 0 of the line). `done` comes
   with the last word. A burst occupies L + n cycles: a single word costs L + 1, a line L + 4.
3. L is 5, 6, 8 or 10 from IF-D `LAT` (cfg[4:3]) and is fixed for the run.
4. Out of reset: `start` = 0; the slave drives `rvalid`, `wready`, `done` = 0.
5. **Addition to the IF-B list:** `be`. A byte or half-word store that bypasses the
   D-cache (DC = 0) or writes through must reach memory in one L + 1 burst (PROTOCOL.md
   section 7), which needs byte enables; a read-modify-write would cost a second burst.

## 3. IF-C MMIO bus

From addr_decode (master) to mmio_bus (slave), which holds the registers of PROTOCOL.md
section 3 and talks to lock_barrier, perf_counters, the 7-segment and the streamer.

| Signal | Width | Direction | Meaning |
| --- | --- | --- | --- |
| `sel` | 1 | master -> slave | an MMIO access is presented |
| `we` | 1 | master -> slave | 1 = write |
| `off` | 8 | master -> slave | register offset (addr[7:0]), a multiple of 4 |
| `wdata` | 32 | master -> slave | write data |
| `owner` | 1 | master -> slave | requesting core (from IF-A `owner`) |
| `rdata` | 32 | slave -> master | read data, valid with `ready` |
| `ready` | 1 | slave -> master | the access is complete |

Rules:
1. `sel` and the fields are held until `ready`; addr_decode raises `sel` one cycle after the
   IF-A request reaches it, so the core sees `ready` in cycle 2 (IF-A rule 3).
2. `ready` = 1 in the same cycle as `sel` for every register. (1.0.2: a BARRIER read never
   reaches IF-C: rr_arbiter parks it and answers it when lock_barrier releases every running
   core. Held on the shared port, it would keep the other core from reaching the barrier.)
3. `owner` selects the core for CORE_ID, BARRIER, LOCK and the per-core counters.
4. Writes to read-only offsets and reads of write-only offsets are ignored and read 0.
5. **Addition to the IF-C list:** `owner`. CORE_ID returns the requesting core's
   number, so the MMIO bus must know which core is asking.

## 4. IF-D config word

| Signal | Width | Direction | Meaning |
| --- | --- | --- | --- |
| `cfg` | 16 | switch_cfg -> every block | SW[15:0] sampled once when reset releases |

Rules:
1. `cfg` changes only in the cycle reset releases and is constant for the whole run.
2. Field map (PROTOCOL.md section 4): [0] FWD, [1] DC, [2] DUAL, [4:3] LAT, [6:5] PROGRAM,
   [7] IC, [13:8] reserved, [15:14] DISPLAY.
3. The live switch value for the SWITCHES register is a separate signal (synchronised, not
   sampled), so DISPLAY can be changed after a run.

## 5. Change log

| Version | Date | Change |
| --- | --- | --- |
| 1.0.1 | 16 Oct 2026 | Rule IF-A 4 wording only (PROTOCOL.md v1.1); no signal or timing change |
| 1.0 | 16 Oct 2026 | First version, from the interface table and PROTOCOL.md v1.0; adds `owner` to IF-C and `be` to IF-B |
