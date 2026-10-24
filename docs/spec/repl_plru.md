# repl_plru (spec v1.0)

| Item | Value |
| --- | --- |
| File | rtl/mem/repl_plru.v |
| Testbench | tb/tb_repl_plru.v |
| Vectors | tb/vectors/plru_*.mem: 10,000 random hit/fill sequences from `tools/cache_model.py` |
| Interfaces | none (inside dcache) |
| Removal parameter | none |

## Purpose
Tree pseudo-LRU replacement state for the 4-way D-cache: 3 bits per set, 64 sets.

## Ports
| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 each | |
| `set` | in | 6 | set being looked up |
| `way_mask` | in | 4 | enabled ways (`cfg[13:10]`, 0000 treated as 1111) |
| `victim` | out | 2 | way to fill on a miss when every enabled way is valid (combinational) |
| `upd` | in | 1 | a hit or fill happened this cycle |
| `upd_set` | in | 6 | its set |
| `upd_way` | in | 2 | its way |

## Behaviour
PROTOCOL.md section 6: b0 = 0 -> victim in ways 0-1, 1 -> ways 2-3; b1 chooses within 0-1, b2
within 2-3. A hit or fill of way w sets the bits to point away from w. A subtree with no enabled
way is never chosen; a disabled leaf gives its sibling. (The "lowest invalid enabled way first"
rule is applied by dcache, not here.)

## Reset values
All bits 0.

## Tests
Every vector sequence for way masks 0000, 0001, 0011, 0111 and random masks. PASS = every
victim equals the Python model.

## Change log
| Version | Date | Change |
| --- | --- | --- |
| 1.0 | 16 Oct 2026 | First version, approved by Divyam |
