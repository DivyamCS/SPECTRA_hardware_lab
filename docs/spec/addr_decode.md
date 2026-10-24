# addr_decode (spec v1.0)

| Item | Value |
| --- | --- |
| File | rtl/soc/addr_decode.v |
| Testbench | tb/tb_addr_decode.v |
| Vectors | directed: boundary addresses of every range |
| Interfaces | IF-A slave (from rr_arbiter), IF-A master (to dcache), IF-C master (to mmio_bus) |
| Removal parameter | none |

## Purpose
Sends each data access to the D-cache or the MMIO block by address, and flags any other address
(decode error, LED2).

## Ports
| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 each | |
| IF-A slave | in/out | - | from rr_arbiter, with `owner` |
| IF-A master | out/in | - | to dcache, with `owner` |
| IF-C master | out/in | - | to mmio_bus: `sel`, `we`, `off`, `wdata`, `owner` -> `rdata`, `ready` |
| `decode_err` | out | 1 | sticky until reset (drives LED2) |

## Behaviour
1. 0x1000_0000-0x1001_FFFF -> dcache (passed through in the same cycle).
2. 0x2000_0000-0x2000_00FF -> mmio_bus; `sel` is raised one cycle after the request arrives
   (registered), so the core sees `ready` in cycle 2 (interfaces.md, IF-C rule 1).
3. Any other address -> `ready` in cycle 2, `rdata` = 0, store dropped, `decode_err` set.

## Reset values
`decode_err` = 0; no access open.

## Tests
First and last address of each range and one past each end; loads and stores; MMIO and error
timing (ready in cycle 2). PASS = all routed correctly with the right timing.

## Change log
| Version | Date | Change |
| --- | --- | --- |
| 1.0 | 16 Oct 2026 | First version, approved by Divyam |
