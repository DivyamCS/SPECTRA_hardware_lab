# core (wrapper and every submodule) with tb_core_dc (D-cache, mem_delay, dmem_bram)
-d SIM
-d TIMING_DUMP
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
rtl/mem/mem_delay.v
rtl/core/core.v
rtl/mem/plru.v
rtl/mem/dcache.v
rtl/mem/dmem_bram.v
tb/tb_core_dc.v
