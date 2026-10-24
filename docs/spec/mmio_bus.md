# mmio_bus (spec v1.1)

| Item | Value |
| --- | --- |
| File | rtl/soc/mmio_bus.v |
| Testbench | tb/tb_mmio_bus.v (generated from the PROTOCOL.md register table) |
| Vectors | register table parsed by a script (same parser as `tools/check_maps.py`) |
| Interfaces | IF-C slave; IF-D (`cfg` for CONFIG) |
| Removal parameter | none |

## Purpose
Holds every MMIO register of PROTOCOL.md section 3 and connects them to lock_barrier,
perf_counters, the 7-segment, the LEDs, the streamer and the switches and buttons.

## Ports
| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 each | |
| IF-C slave | in/out | - | `sel`, `we`, `off`, `wdata`, `owner` -> `rdata`, `ready` |
| `cfg`, `ncores`, `sw_live` | in | 16,2,16 | CONFIG, NCORES, SWITCHES |
| `btn` | in | 4 | BTNL, BTNR, BTNU, BTND after the VIO mux (raw) |
| to/from lock_barrier | - | - | `lock_rd`, `lock_wr0`, `bar_req`, `bar_release`, `lock_rdata` |
| to/from perf_counters | - | - | `run_start`, `run_stop`, `rd_sel`, `rd_data` |
| `leds` | out | 16 | LEDS register (LED2 is replaced by `decode_err` in the top) |
| `seg7_val`, `seg7_dp` | out | 27, 8 | SEG7, SEG7_DP |
| `st_gen_done`, `st_checksum`, `st_row_done`, `st_mrow_done` | out | pulses + 32-bit data | streamer events, with `owner` for ROW/MROW |

## Behaviour
1. Every register and offset exactly as PROTOCOL.md section 3 (32-bit accesses only).
2. `ready` in the same cycle as `sel` for every register (1.0.1: a BARRIER read is parked in
   rr_arbiter and does not reach this bus; one that did would read 0 at once).
3. CORE_ID returns `owner`. BUTTONS: 2-flop synchronised and debounced (as switch_cfg), level.
4. Writes to read-only offsets and reads of write-only offsets are ignored and read 0.

## Reset values
LEDS = 0, SEG7 = 0, SEG7_DP = 0; no streamer event pending.

## Tests
For every register in the table: a write (if W) and a read (if R) with the expected effect;
CORE_ID for both owners; BARRIER waits for `bar_release`. PASS = every register correct.

## Change log
| Version | Date | Change |
| --- | --- | --- |
| 1.0 | 16 Oct 2026 | First version, approved by Divyam |
| 1.0.1 | 16 Oct 2026 | BARRIER reads are parked in rr_arbiter (they never hold the shared data port, which would keep the other core from reaching the barrier: a deadlock in the 1.0 design); lock_barrier's bar_req / bar_release are not on this bus. Pending Divyam's review |
| 1.1 | 17 Oct 2026 | TIMER (0x44, R: clock cycles since reset, never frozen: the time base of the 7-segment tour after the run) and SEG7_TXT (0x48, W: letters per digit, output `seg7_txt`). Divyam's request (17 Oct, demo): labelled 7-segment tour. Approved by Divyam (his request) |
