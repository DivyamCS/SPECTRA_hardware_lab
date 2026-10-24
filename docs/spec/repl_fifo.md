# repl_fifo (spec v1.1)

| Item | Value |
| --- | --- |
| File | rtl/mem/repl_fifo.v |
| Testbench | tb/tb_repl_fifo.v |
| Vectors | tb/vectors/fifo_*.mem from `tools/cache_model.py` |
| Interfaces | none (inside dcache) |
| Removal parameter | none |

## Purpose
FIFO (round-robin) replacement for the 2-way I-cache (way mask 0011): a 2-bit pointer per set.
The module handles up to 4 ways; its testbench covers every mask.

## Ports
Same as repl_plru, with `upd` meaning "a fill happened" (`upd_hit` is not needed: hits do not
move the pointer):
| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 each | |
| `set`, `way_mask` | in | 6, 4 | as repl_plru |
| `victim` | out | 2 | the pointer of `set`, moved to an enabled way if it points at a disabled one |
| `fill` | in | 1 | a line was filled this cycle |
| `fill_set` | in | 6 | its set |
| `fill_way` | in | 2 | the way filled (spec 1.0.1): the cache may fill an invalid way, not the victim |

## Behaviour
PROTOCOL.md section 6: the pointer names the next victim and moves to the next enabled way
(wrapping) after each fill; hits do not move it. "Next" counts from the way actually filled
(`fill_way`), as tools/cache_model.py does, also when the cache filled the lowest invalid way.

## Reset values
All pointers 0.

## Tests
Every vector sequence for way masks 0000, 0001, 0011, 0111 and random masks. PASS = every
victim equals the Python model.

## Change log
| Version | Date | Change |
| --- | --- | --- |
| 1.0 | 16 Oct 2026 | First version, approved by Divyam |
| 1.0.1 | 16 Oct 2026 | input `fill_way`; the pointer moves past the way filled (cache_model rule). Pending Divyam's review |
| 1.1 | 24 Oct 2026 | now the I-cache's replacement (way mask 0011); the D-cache no longer uses it (SW8 retired) |
