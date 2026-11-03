# SPECTRA module table

One spec page per module. 28 modules. Each page follows `docs/spec/TEMPLATE.md`.

| # | Module | File | Testbench | Interfaces | Removal parameter |
| --- | --- | --- | --- | --- | --- |
| 1 | [decoder](decoder.md) | rtl/core/decoder.v | `tb_decoder` | - | - |
| 2 | [regfile](regfile.md) | rtl/core/regfile.v | `tb_regfile` | - | - |
| 3 | [hazard_unit](hazard_unit.md) | rtl/core/hazard_unit.v | `tb_hazard_unit` | IF-D | `HAS_FWD` |
| 4 | [mul_unit](mul_unit.md) | rtl/core/mul_unit.v | `tb_mul_unit` | - | `HAS_MD` |
| 5 | [div_unit](div_unit.md) | rtl/core/div_unit.v | `tb_div_unit` | - | `HAS_MD` |
| 6 | [execute](execute.md) | rtl/core/execute.v | `tb_execute` | - | - |
| 7 | [mem_stage](mem_stage.md) | rtl/core/mem_stage.v | `tb_mem_stage` | IF-A master | - |
| 8 | [icache](icache.md) | rtl/core/icache.v | `tb_icache` | IF-B master, IF-D | `HAS_ICACHE` |
| 9 | [core](core.md) (wrapper) | rtl/core/core.v | `tb_core` | IF-A, IF-B, IF-D | - |
| 10 | [mem_delay](mem_delay.md) | rtl/mem/mem_delay.v | `tb_mem_delay` | IF-B slave, IF-D | - |
| 11 | [dmem_bram](dmem_bram.md) | rtl/mem/dmem_bram.v | `tb_dmem_bram` | - | - |
| 12 | [imem_bram](imem_bram.md) | rtl/mem/imem_bram.v | `tb_imem_bram` | - | - |
| 13 | [plru](plru.md) | rtl/mem/plru.v | `tb_plru` | - | - |
| 14 | [fifo](fifo.md) | rtl/mem/fifo.v | `tb_fifo` | - | - |
| 15 | [dcache](dcache.md) | rtl/mem/dcache.v | `tb_dcache` | IF-A slave, IF-B master, IF-D | `HAS_DCACHE` |
| 16 | [clk_rst](clk_rst.md) | rtl/soc/clk_rst.v | `tb_clk_rst` | - | - |
| 17 | [switch_cfg](switch_cfg.md) | rtl/soc/switch_cfg.v | `tb_switch_cfg` | IF-D source | - |
| 18 | [core_ctrl](core_ctrl.md) | rtl/soc/core_ctrl.v | `tb_core_ctrl` | IF-D | `HAS_CORE1` |
| 19 | [rr_arbiter](rr_arbiter.md) | rtl/soc/rr_arbiter.v | `tb_rr_arbiter` | IF-A (2 slaves, 1 master) | - |
| 20 | [addr_decode](addr_decode.md) | rtl/soc/addr_decode.v | `tb_addr_decode` | IF-A slave, IF-A master, IF-C master | - |
| 21 | [lock_barrier](lock_barrier.md) | rtl/soc/lock_barrier.v | `tb_lock_barrier` | IF-D | - |
| 22 | [perf_counters](perf_counters.md) | rtl/soc/perf_counters.v | `tb_perf_counters` | - | - |
| 23 | [mmio_bus](mmio_bus.md) | rtl/soc/mmio_bus.v | `tb_mmio_bus` | IF-C slave, IF-D | - |
| 24 | [seg7_bcd](seg7_bcd.md) | rtl/io/seg7_bcd.v | `tb_seg7_bcd` | - | - |
| 25 | [uart_top](uart_top.md) | rtl/io/uart_top.v | `tb_uart_top` | - | - |
| 26 | [result_streamer](result_streamer.md) | rtl/io/result_streamer.v | `tb_result_streamer` | IF-D | - |
| 27 | [vio_hook](vio_hook.md) | rtl/io/vio_hook.v | `tb_vio_hook` | - | `HAS_VIO` |
| 28 | [top_fpga](top_fpga.md) (wrapper) | rtl/top_fpga.v | `tb_top` | all | - |

Wrappers (9, 28) only instantiate and connect modules. `soc_top` for simulation is the board top without pins and VIO; it is described on
the top_fpga page.

Global conventions for every page: clock `clk` (50 MHz), reset `rst` (synchronous to `clk`,
active high, from clk_rst); all outputs registered unless the page says otherwise; one
testbench `tb/tb_<module>.v` printing exactly one `PASS <module>` or `FAIL <module>` line;
an entry in `sim/tests.txt`.
