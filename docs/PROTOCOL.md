# SPECTRA hardware/software contract (v1.1)

Everything the RTL must do so that the firmware, the simulator (`sim/rv32sim.c`) and the
dashboard (`host/`) work unchanged. `fw/spectra.h` holds the same numbers for the firmware;
`python tools/check_maps.py` fails if this file and `spectra.h` ever disagree.

**Status.** Frozen 16 Oct 2026 (I-cache 2 KB 2-way per core; switch map with SW7 = IC and
SW15:14 = DISPLAY, as written below). Any change bumps the version and re-runs
`scripts/check_all.py`. The module
interfaces built on this contract are in `docs/interfaces.md`.

**Change log.** v1.1 (16 Oct 2026): section 8, trace comparison also stops at the
first CYCLES read; found when FWD = 1 and FWD = 0 traces of t_hazard differed only after it. Section 1,
loads to x0: the firmware loads BARRIER into a normal register, not x0 (found); the
hardware rule is unchanged. No number, register or timing changed.

## 1. System

| Item | Value |
| --- | --- |
| Clock | 50 MHz from the MMCM (board clock 100 MHz on pin E3) |
| Reset | BTNC, active high; releases core 0, and core 1 when DUAL = 1 |
| Cores | 2 x 3-stage RV32IM (IF/ID, EX, MEM/WB), both start at PC 0 |
| ISA used by the firmware | RV32I + M only: no FENCE, ECALL, EBREAK, CSR or compressed instructions |
| Loads to x0 | Must still access memory (a BARRIER read written as `lw zero, 0xC(base)` must still wait); the kit firmware loads BARRIER into a normal register (boot.S: `t3`) |
| Register file | Write-through: a value written in MEM/WB is read in the same cycle |
| Branches | Resolved in EX; the 2 instructions behind a taken branch, JAL or JALR are squashed |

## 2. Memory map

| Range | Size | Contents |
| --- | --- | --- |
| 0x0000_0000-0x0000_3FFF | 16 KB | IMEM, `imem.hex`, true dual-port BRAM (port A core 0, port B core 1) |
| 0x1000_0000-0x1000_7FFF | 32 KB | .rodata and .bss, `dmem.hex` (.data is always empty) |
| 0x1000_8000-0x1000_8FFF | 4 KB | GRID0, Game of Life 64x64 bytes, snooped |
| 0x1000_9000-0x1000_9FFF | 4 KB | GRID1, snooped |
| 0x1001_0000-0x1001_6BFF | 27 KB | IMAGE, Mandelbrot 192x144 bytes, snooped |
| 0x1001_0000 / 0x1001_4000 / 0x1001_8000 | 4 KB each | MatMul A / B / C (32x32 int32); C is snooped |
| 0x1001_E000-0x1001_EFFF | 4 KB | core 1 stack |
| 0x1001_F000-0x1001_FFFF | 4 KB | core 0 stack |
| 0x2000_0000-0x2000_00FF | - | MMIO, through the arbiter, never cached |

DMEM is 128 KB (0x1000_0000-0x1001_FFFF). Any other data address sets the decode-error flag
(LED2) and reads 0. A soft reset does not reload BRAM; the firmware never relies on it.

## 3. MMIO registers (base 0x2000_0000, 32-bit accesses only)

| Offset | Name | R/W | Behaviour |
| --- | --- | --- | --- |
| 0x00 | CORE_ID | R | 0 or 1 |
| 0x04 | NCORES | R | 1 or 2 (DUAL) |
| 0x08 | CONFIG | R | SW[15:0] sampled when reset releases |
| 0x0C | BARRIER | R | The load completes when every running core has issued it; returns 0 |
| 0x10 | LOCK | R/W | Read: test-and-set, returns 0 (acquired) or 1 (busy). Write 0: release |
| 0x14 | RUN_START | W | Clear and start all counters; streamer sends BEGIN |
| 0x18 | RUN_STOP | W | Freeze all counters |
| 0x1C | GEN_DONE | W | {buffer << 16 or generation}: streamer sends a FRAME of that grid, or skips it if busy |
| 0x20 | CHECKSUM | W | Latch the value; streamer sends STATS |
| 0x24 | LEDS | W | LED[15:0], except LED2 (hardware decode-error flag) |
| 0x28 | SEG7 | W | 0 to 99,999,999 shown in decimal |
| 0x2C | ROW_DONE | W | Mandelbrot row finished: queue a ROW packet |
| 0x30 | MROW_DONE | W | MatMul row of C finished: queue an MROW packet |
| 0x34 | CYCLES | R | Cycles since RUN_START (frozen by RUN_STOP) |
| 0x38 | SWITCHES | R | Live SW[15:0] (synchronised) |
| 0x3C | BUTTONS | R | Bit 0 BTNL, 1 BTNR, 2 BTNU, 3 BTND (debounced, level) |
| 0x40 | SEG7_DP | W | Decimal points, bit n = digit n (digit 0 = rightmost) |
| 0x44 | TIMER | R | Clock cycles since reset, free-running: never frozen, wraps at 2^32 (the time base after the run) |
| 0x48 | SEG7_TXT | W | Letters on the 7-segment display: nibble n = digit n; 0 = the SEG7 digit, 1-15 = a letter instead (table below) |
| 0x50 + 0x20*k | counters, core k | R | +0x00 INSTRET, +0x04 D_HIT, +0x08 D_MISS, +0x0C I_HIT, +0x10 I_MISS, +0x14 ARB_WAIT, +0x18 BAR_WAIT |

Counters count only between RUN_START and RUN_STOP. D_HIT/D_MISS count cacheable data
accesses of that core when DC = 1. I_HIT/I_MISS count fetches when IC = 1. ARB_WAIT counts cycles
a data request waited for the arbiter; BAR_WAIT counts cycles spent blocked in BARRIER.

7-segment blanking: leading zeros are blank, except digit 0 and every digit at or right of
the highest decimal point that is on (so 73 with SEG7_DP = 0x04 shows "0.73"). A digit whose
SEG7_TXT code is not 0 shows that letter instead, always lit; its decimal point is shown but does
not change the blanking (so "dn0." followed by 368 shows "dn0.  368"):

| Code | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Shows | C | y | I | H | d | n | P | A | r | - | 0 | 1 | t | E | blank |

## 4. Switches, buttons, LEDs

| Switch | Field | Meaning |
| --- | --- | --- |
| SW0 | FWD | 1 = forwarding on; 0 = 1-cycle interlock on every distance-1 dependence |
| SW1 | DC | 1 = D-cache on; 0 = every data access is a one-word memory burst |
| SW2 | DUAL | 1 = core 1 runs |
| SW4:3 | LAT | memory latency L: 00 = 5, 01 = 6, 10 = 8, 11 = 10 cycles |
| SW6:5 | PROGRAM | 00 Game of Life, 01 Mandelbrot halves, 10 Mandelbrot interleaved, 11 MatMul |
| SW7 | IC | 1 = I-caches on; 0 = every fetch is a one-word memory burst |
| SW8 | - | reserved (ignored); the D-cache is PLRU, the I-cache FIFO |
| SW9 | WPOL | 0 = write-back/write-allocate, 1 = write-through/no-allocate |
| SW13:10 | WAYS | D-cache way enable mask; 0000 = all four |
| SW15:14 | DISPLAY | 7-segment counter after the run (read live) |

Buttons: BTNC = reset. After a run (the program runs once; the display only shows the counters
it left):

* **Tour** (on after every run; BTNU starts it again): one item every 3 s (TIMER), in a loop:
  cycles in thousands; then for each running core its I-cache hit % (IC = 1), D-cache hit %
  (DC = 1) and CPI; then, with two cores, each core's arbiter wait %.
* **Browser**: moving SW15:14 or pressing BTNL / BTNR leaves the tour. BTNR toggles core 0/1,
  BTNL toggles count/rate mode:

| SW15:14 | Count mode | Label | Rate mode (2 decimals) | Label |
| --- | --- | --- | --- | --- |
| 00 | Cycles, in thousands | Cy | CPI of the selected core | CPI |
| 01 | D-cache hits | dH | D-cache hit rate % | dH |
| 10 | D-cache misses | dn | I-cache hit rate % | IH |
| 11 | Arbiter wait cycles | Ar | Arbiter wait as % of cycles | Ar |

Every value has its label on the left (SEG7_TXT letters) and the number right-aligned after it:
"Cy 70337", "IH  99.98", "CPI  2.20". With two cores the core number and a dot follow the label
(not after "Cy"): "dH0.49300", "IH1. 99.99". A count longer than its digits is shown in
thousands; a rate is capped at the largest number that fits.

LEDs after a run: LED0 done, LED1 checksum = golden, LED2 decode error (hardware), LED10 tour on,
LED11 rate mode, LED12 value shown in thousands, LED13 core 1, LED15:14 = the selector of the
value shown (SW15:14 in the browser; in the tour the browser setting that shows the same value).

## 5. UART packets (1,000,000 baud, 8N1, board to laptop)

`0xA5 | type | length (u16 LE) | payload | crc8` - crc8 = polynomial 0x07, initial 0, over type,
both length bytes and the payload. All fields little-endian. Cycle stamps count from RUN_START.

| Type | Name | Length | Payload |
| --- | --- | --- | --- |
| 1 | BEGIN | 4 | config u16, ncores u8, program u8 |
| 2 | FRAME | 518 | generation u16, cycle u32, 512 bytes: 4096 cells, bit i = cell i (row-major, LSB first) |
| 3 | ROW | 199 | core u8, row u16, cycle u32, 192 iteration counts |
| 4 | MROW | 38 | core u8, row u8, cycle u32, 32 bytes min(255, C >> 5) |
| 5 | STATS | 68 | config u16, ncores u8, program u8, cycles u32, checksum u32, then for core 0 and core 1: INSTRET, D_HIT, D_MISS, I_HIT, I_MISS, ARB_WAIT, BAR_WAIT (u32 each) |

The streamer never makes a core wait:
* it snoops every store leaving the arbiter into shadow buffers: GRID0/GRID1 as one bit per cell
  (2 x 4096 bits), IMAGE as bytes (27,648 B), MatMul C as min(255, value >> 5) (1,024 B);
* ROW_DONE and MROW_DONE push {core, row, cycle} into a 256-entry FIFO (a run never has more
  than 144 rows), and the row data is read from the shadow when the packet is sent;
* GEN_DONE copies the selected grid's 4096 shadow bits into a frame buffer only if the previous
  FRAME has finished sending; otherwise that frame is skipped. A FRAME is 523 bytes, about
  0.26 M cycles (5.2 ms) of UART time, so with two cores roughly two generations in three are
  skipped; the cycle counts are unaffected.

## 6. Cache rules (tools/cache_model.py implements exactly this)

| Item | D-cache (shared) | I-cache (per core) |
| --- | --- | --- |
| Size, ways, line | 4 KB, 4-way, 16 B | 2 KB, 2-way, 16 B |
| Sets, index, tag | 64, addr[9:4], addr[31:10] | 64, addr[9:4], addr[31:10] |
| Replacement | PLRU (3-bit tree) | FIFO (pointer per set) |
| Writes | WB-WA or WT-NA, SW9 | read-only |
| Way mask | SW13:10, only enabled ways are ever filled | - |

* Miss: the lowest-numbered invalid enabled way is filled; otherwise the policy picks.
* PLRU (D-cache): b0 = 0 victim in ways 0-1, 1 victim in ways 2-3; b1 picks within 0-1, b2 within 2-3. Every
  hit or fill of way w sets the bits to point away from w. A subtree with no enabled way is never
  chosen; a disabled leaf gives its sibling.
* FIFO (I-cache): the pointer names the next victim and moves to the other way after each fill;
  hits do not move it.
* Write-through/no-allocate: a store hit updates the line and memory, never dirty; a store miss
  writes memory only. Loads allocate in both policies.

## 7. Timing (RTL targets; rv32sim approximates them)

| Event | Cycles |
| --- | --- |
| Data access, D-cache hit or MMIO | 2 in MEM/WB (1 stall) |
| D-cache miss, clean victim | 2 + (L + 4) |
| D-cache miss, dirty victim | 2 + (L + 4) + (L + 4) |
| Uncached data access (DC = 0), write-through store | 2 + (L + 1) |
| I-cache hit | no stall |
| I-cache miss | L + 4 extra |
| Fetch with IC = 0 | L + 1 extra per instruction |
| MUL / DIV | 3 / up to 34 cycles in EX |
| Taken branch, JAL, JALR | 2 extra (2 squashed) |
| FWD = 0, dependence at distance 1 | 1 extra |
| Data port busy (other core) | wait until free; counted in ARB_WAIT |

rv32sim charges these as fixed costs per instruction and does not model overlaps (for example a
MUL that starts while a load stalls). Its cycle counts are estimates; the RTL defines the real
numbers. Its results (memory, checksums, packets, counter events) are exact.

## 8. Commit trace format (RTL testbench and rv32sim -t)

One line per retired instruction, per hart, in hex:

    PC INSTR [xN=VALUE] [ld ADDR | st ADDR DATA]

`xN=VALUE` only when rd != 0. Stores give the address and the data as stored (masked to the
access size). `tools/tracecmp.py` ignores the loaded value for LOCK, CYCLES, SWITCHES, BUTTONS
and the counters, and stops at the first CYCLES or SWITCHES read (v1.1: the firmware reads
CYCLES only after RUN_STOP and CHECKSUM, then computes with it, so what follows depends on timing).

## 9. Firmware rules

* boot.S: both cores read CORE_ID, set sp (core 0: 0x1002_0000, core 1: 0x1001_F000); core 0
  clears .bss; both meet at BARRIER; then spectra_main(id) (not main, so no compiler applies its rules for main).
* Each program: core 0 prepares data, writes RUN_START, everyone meets at BARRIER, the work runs,
  everyone meets at BARRIER, core 0 writes RUN_STOP, computes the checksum (FNV-1a) and calls
  finish(): CHECKSUM, LED0/LED1, SEG7 = cycles / 1000, then the display browser.
* Golden checksums come from `tools/golden.py` (written to `fw/golden.h` by `fw/build.py`).

## 10. Automation hooks (JTAG, used only by scripts)

So that board regressions run without anyone touching the board, the top level contains one
Vivado VIO core (Virtual Input/Output, driven over the same USB cable through the hardware
manager). With `ovr_en` = 0 (the reset value) the board behaves exactly as described above.

| VIO probe | Dir | Width | Meaning |
| --- | --- | --- | --- |
| ovr_en | out | 1 | 1 = switches and buttons come from VIO instead of the board |
| ovr_sw | out | 16 | replaces SW[15:0] (also what CONFIG samples at reset) |
| ovr_btn | out | 5 | replaces BTNC, BTNL, BTNR, BTNU, BTND (bit 0 = BTNC = reset) |
| leds | in | 16 | LED[15:0] as driven |
| seg7_val | in | 32 | value last written to SEG7 |
| seg7_dp | in | 8 | value last written to SEG7_DP |
| uart_busy | in | 1 | streamer still sending |

`scripts/board.tcl` (written) offers: set switches, pulse reset, press a button,
read LEDs and SEG7. `scripts/board_regress.py` uses it with the UART capture to run any list of
configurations unattended. The VIO costs a few hundred LUTs and no BRAM; the final demo build may
keep it (ovr_en = 0) or drop it by parameter.
