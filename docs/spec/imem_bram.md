# imem_bram (spec v1.0)

| Item | Value |
| --- | --- |
| File | rtl/mem/imem_bram.v |
| Testbench | tb/tb_imem_bram.v |
| Vectors | directed; contents from a test imem.hex |
| Interfaces | BRAM ports of the two cores' I-side mem_delay |
| Removal parameter | none |

## Purpose
The 16 KB instruction memory at 0x0000_0000-0x0000_3FFF as a true dual-port BRAM: port A for
core 0, port B for core 1, so the cores never wait for each other on fetches.

## Parameters
| Name | Default | Meaning |
| --- | --- | --- |
| `INIT_FILE` | "imem.hex" | `$readmemh` file, 4096 words |

## Ports
| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk` | in | 1 | |
| `addr_a`, `addr_b` | in | 12 each | word addresses |
| `rdata_a`, `rdata_b` | out | 32 each | registered reads (1 cycle) |

## Behaviour
1. Read-only during a run; both ports read in the same cycle independently.
2. Must infer as block RAM so `scripts/updatemem.py` can swap programs into a built
   bitstream.

## Reset values
None.

## Tests
Both ports reading different and identical addresses in the same cycle; contents equal the hex
file. PASS = 0 mismatches.

## Change log
| Version | Date | Change |
| --- | --- | --- |
| 1.0 | 16 Oct 2026 | First version |
