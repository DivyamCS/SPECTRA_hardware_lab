# dmem_bram (spec v1.0)

| Item | Value |
| --- | --- |
| File | rtl/mem/dmem_bram.v |
| Testbench | tb/tb_dmem_bram.v |
| Vectors | directed; initial contents from a test dmem.hex |
| Interfaces | BRAM port of mem_delay |
| Removal parameter | none |

## Purpose
The 128 KB data memory at 0x1000_0000-0x1001_FFFF (32 BRAM36), loaded from `dmem.hex`.

## Parameters
| Name | Default | Meaning |
| --- | --- | --- |
| `INIT_FILE` | "dmem.hex" | `$readmemh` file (8192 words fill the bottom 32 KB; the rest starts as 0) |

## Ports
| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk` | in | 1 | |
| `addr` | in | 15 | word address (`byte addr[16:2]`) |
| `we` | in | 1 | write |
| `be` | in | 4 | byte enables |
| `wdata` | in | 32 | |
| `rdata` | out | 32 | registered read (1 cycle), read-first |

## Behaviour
1. Synchronous read with 1-cycle latency; byte-enable writes; inferred as block RAM (no
   same-cycle forwarding logic, which made the lab's data_mem use distributed RAM).
2. Initial contents from `INIT_FILE`; a soft reset does not reload it (PROTOCOL.md section 2).

## Reset values
None (memory).

## Tests
Write and read back every byte-enable pattern; first and last word; initial contents equal the
hex file; synthesis report shows RAMB36 only (32). PASS = 0 mismatches.

## Change log
| Version | Date | Change |
| --- | --- | --- |
| 1.0 | 16 Oct 2026 | First version |
