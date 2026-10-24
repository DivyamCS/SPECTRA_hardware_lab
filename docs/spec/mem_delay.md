# mem_delay (spec v1.0)

| Item | Value |
| --- | --- |
| File | rtl/mem/mem_delay.v |
| Testbench | tb/tb_mem_delay.v |
| Vectors | directed: every L, reads, writes, 1- and 4-word bursts, back-to-back |
| Interfaces | IF-B slave, IF-D (`cfg[4:3]` LAT) |
| Removal parameter | none |

## Purpose
The memory latency model: makes a BRAM look like a slower main memory with latency L = 5, 6, 8
or 10 cycles, so cache effects are measurable. One instance in front of DMEM (D-cache side) and
one per core in front of IMEM (I-cache side).

## Ports
| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 each | |
| `lat` | in | 2 | `cfg[4:3]`: 00 = 5, 01 = 6, 10 = 8, 11 = 10 |
| IF-B slave | in/out | - | `start`, `we`, `addr`, `nwords`, `wdata`, `be`, `rvalid`, `rdata`, `wready`, `done` |
| `m_addr`, `m_we`, `m_be`, `m_wdata`, `m_rdata` | out/in | 30,1,4,32,32 | BRAM port (1-cycle synchronous read) |

## Behaviour
1. `start` in cycle 0 -> words in cycles L .. L + n - 1, `done` with the last (interfaces.md
   section 2). Single word L + 1 cycles, line L + 4.
2. Reads: the BRAM is addressed one cycle before each `rvalid` so `rdata` lines up.
3. Writes: `wready` in cycles L .. L + n - 1; each `wready` writes `wdata` with `be` (1111 for
   lines) to address `addr + k`.
4. A new `start` is accepted in the cycle after `done`.

## Reset values
Idle, `rvalid` = `wready` = `done` = 0.

## Tests
For L = 5, 6, 8, 10: 1-word read, 1-word write with each byte-enable pattern, 4-word read and
write, back-to-back bursts. PASS = exact cycle of every `rvalid`/`wready`/`done` and the right data.

## Change log
| Version | Date | Change |
| --- | --- | --- |
| 1.0 | 16 Oct 2026 | First version, approved by Divyam |
