# SPECTRA module table

One spec page per module. 28 modules. Each page follows `docs/spec/TEMPLATE.md`. Stretch modules
(victim cache, coherent D-cache) get their pages.

Status of every page: **v1.0**, approved by Divyam on 16 Oct 2026 and frozen with spec v1.0. Ports may still be
refined by the step that builds a module; such a change is recorded in the page's change log
and, if it touches an interface, in `docs/interfaces.md`.

| # | Module | File | Built / tested at | Interfaces | Removal parameter |
| --- | --- | --- | --- | --- | --- |
| 1 | [decoder](decoder.md) | rtl/core/decoder.v | 39, 40 | - | - |
| 2 | [regfile](regfile.md) | rtl/core/regfile.v | 41 | - | - |
| 3 | [hazard_unit](hazard_unit.md) | rtl/core/hazard_unit.v | 42-44 | IF-D | `HAS_FWD` |
| 4 | [mul_unit](mul_unit.md) | rtl/core/mul_unit.v | 33-35 | - | `HAS_MD` |
| 5 | [div_unit](div_unit.md) | rtl/core/div_unit.v | 36-38 | - | `HAS_MD` |
| 6 | [execute](execute.md) | rtl/core/execute.v | 45 | - | - |
| 7 | [mem_stage](mem_stage.md) | rtl/core/mem_stage.v | 46 | IF-A master | - |
| 8 | [icache](icache.md) | rtl/core/icache.v | 71-73 | IF-B master, IF-D | `HAS_ICACHE` |
| 9 | [core](core.md) (wrapper) | rtl/core/core.v | 47-53, 73-74 | IF-A, IF-B, IF-D | - |
| 10 | [mem_delay](mem_delay.md) | rtl/mem/mem_delay.v | 54-55 | IF-B slave, IF-D | - |
| 11 | [dmem_bram](dmem_bram.md) | rtl/mem/dmem_bram.v | 56 | - | - |
| 12 | [imem_bram](imem_bram.md) | rtl/mem/imem_bram.v | 57 | - | - |
| 13 | [repl_plru](repl_plru.md) | rtl/mem/repl_plru.v | 58 | - | - |
| 14 | [repl_fifo](repl_fifo.md) | rtl/mem/repl_fifo.v | 59 | - | - |
| 15 | [dcache](dcache.md) | rtl/mem/dcache.v | 60-70 | IF-A slave, IF-B master, IF-D | `HAS_DCACHE` |
| 16 | [clk_rst](clk_rst.md) | rtl/soc/clk_rst.v | 80 | - | - |
| 17 | [switch_cfg](switch_cfg.md) | rtl/soc/switch_cfg.v | 81 | IF-D source | - |
| 18 | [core_ctrl](core_ctrl.md) | rtl/soc/core_ctrl.v | 82 | IF-D | `HAS_CORE1` |
| 19 | [rr_arbiter](rr_arbiter.md) | rtl/soc/rr_arbiter.v | 83 | IF-A (2 slaves, 1 master) | - |
| 20 | [addr_decode](addr_decode.md) | rtl/soc/addr_decode.v | 84 | IF-A slave, IF-A master, IF-C master | - |
| 21 | [lock_barrier](lock_barrier.md) | rtl/soc/lock_barrier.v | 85 | IF-D | - |
| 22 | [perf_counters](perf_counters.md) | rtl/soc/perf_counters.v | 86 | - | - |
| 23 | [mmio_bus](mmio_bus.md) | rtl/soc/mmio_bus.v | 87 | IF-C slave, IF-D | - |
| 24 | [seg7_bcd](seg7_bcd.md) | rtl/io/seg7_bcd.v | 88-89 | - | - |
| 25 | [uart_top](uart_top.md) | rtl/io/uart_top.v | 90-91 | - | - |
| 26 | [result_streamer](result_streamer.md) | rtl/io/result_streamer.v | 92-94 | IF-D | - |
| 27 | [vio_hook](vio_hook.md) | rtl/io/vio_hook.v | 95 | - | `HAS_VIO` |
| 28 | [top_fpga](top_fpga.md) (wrapper) | rtl/top_fpga.v | 95-97, 101 | all | - |

Wrappers (9, 28) only instantiate and connect modules (modular rule: merges happen only in
wrappers). `soc_top` for simulation is the board top without pins and VIO; it is described on
the top_fpga page.

Global conventions for every page: clock `clk` (50 MHz), reset `rst` (synchronous to `clk`,
active high, from clk_rst); all outputs registered unless the page says otherwise; one
testbench `tb/tb_<module>.v` printing exactly one `PASS <module>` or `FAIL <module>` line;
an entry in `sim/tests.txt`.
