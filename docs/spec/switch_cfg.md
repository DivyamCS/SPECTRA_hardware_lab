# switch_cfg (spec v1.0)

| Item | Value |
| --- | --- |
| File | rtl/soc/switch_cfg.v |
| Testbench | tb/tb_switch_cfg.v |
| Vectors | directed |
| Interfaces | IF-D source |
| Removal parameter | none |

## Purpose
Turns the 16 slide switches into the IF-D config word, sampled once when reset releases, plus a
synchronised live copy for the SWITCHES register.

## Ports
| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 each | |
| `sw` | in | 16 | switches after the VIO override mux (asynchronous) |
| `cfg` | out | 16 | IF-D config word |
| `sw_live` | out | 16 | synchronised, debounced switches |

## Behaviour
1. 2-flop synchroniser on every bit, then a debounce (a bit changes only after it is stable for
   2^16 cycles, about 1.3 ms).
2. `cfg` <= `sw_live` in the cycle `rst` falls; constant until the next reset (interfaces.md
   section 4).
   Implementation (1.0.1): a register follows `sw_live` in every reset cycle, so it holds the
   value of the cycle reset releases, and `cfg` = `rst` ? 0 : that register - valid from the first
   cycle after reset (the module only sees `rst` fall one cycle late).
3. Because switches are debounced continuously, the value sampled at reset is the value set
   before BTNC was pressed.

## Reset values
`cfg` = 0 during reset; synchronisers keep running.

## Tests
`cfg` equals the switches present before reset and ignores changes after it; a bounce shorter
than the debounce time never reaches `sw_live`. PASS = all checks.

## Change log
| Version | Date | Change |
| --- | --- | --- |
| 1.0 | 16 Oct 2026 | First version |
| 1.0.1 | 16 Oct 2026 | how behaviour 2 is met (wording) |
