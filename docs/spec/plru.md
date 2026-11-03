# plru (spec v1.1)

| Item | Value |
| --- | --- |
| File | rtl/mem/plru.v |
| Testbench | tb/tb_plru.v (directed and exhaustive checks) |
| Interfaces | none (inside dcache) |
| Removal parameter | none |

## Purpose
Tree pseudo-LRU replacement state for the 4-way D-cache: 3 bits per set, 64 sets.

## Parameters
| Name | Default | Meaning |
| --- | --- | --- |
| `NUM_SETS` | 64 | sets |
| `INDEX_BITS` | 6 | set index width |

## Ports
| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 each | |
| `set` | in | 6 | set being looked up |
| `way_mask` | in | 4 | enabled ways, 0000 treated as 1111 (dcache ties it to 1111: all four ways) |
| `victim` | out | 2 | way to fill on a miss when every way is valid (combinational) |
| `upd` | in | 1 | a hit or fill happened this cycle |
| `upd_set` | in | 6 | its set |
| `upd_way` | in | 2 | its way |

## Behaviour
PROTOCOL.md section 6: b0 = 0 -> victim in ways 0-1, 1 -> ways 2-3; b1 chooses within 0-1, b2
within 2-3. A hit or fill of way w sets the bits to point away from w. With a mask, a subtree with
no enabled way is never chosen and a disabled leaf gives its sibling. (The "lowest invalid way
first" rule is applied by dcache, not here.)

## Reset values
All bits 0.

## Tests
tb_plru: reset, directed walks, exhaustive state x access x mask transitions, set isolation;
106,184 checks.

## Change log
| Version | Date | Change |
| --- | --- | --- |
| 1.0 | 16 Oct 2026 | First version (repl_plru) |
| 1.1 | 25 Oct 2026 | plru.v replaces repl_plru.v; same ports, parameterised; tb_plru replaces tb_repl_plru |
