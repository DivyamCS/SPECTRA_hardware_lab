# soc_top (the whole SoC, no pins) with tb_top
-d SIM
-i rtl/core
rtl/core/decoder.v
rtl/core/regfile.v
rtl/core/hazard_unit.v
rtl/core/mul.v
rtl/core/mul_unit.v
rtl/core/div.v
rtl/core/div_unit.v
rtl/core/execute.v
rtl/core/mem_stage.v
rtl/core/commit_trace.v
rtl/mem/fifo.v
rtl/core/icache.v
rtl/core/core.v
rtl/mem/mem_delay.v
rtl/mem/dmem_bram.v
rtl/mem/imem_bram.v
rtl/mem/plru.v
rtl/mem/dcache.v
rtl/soc/switch_cfg.v
rtl/soc/core_ctrl.v
rtl/soc/rr_arbiter.v
rtl/soc/addr_decode.v
rtl/soc/lock_barrier.v
rtl/soc/perf_counters.v
rtl/soc/mmio_bus.v
rtl/io/seg7_bcd.v
rtl/io/uart_top.v
rtl/io/result_streamer.v
rtl/soc_top.v
tb/tb_top.v