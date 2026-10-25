# ============================================================
# build_bitstream.tcl  —  Vivado Batch Bitstream Flow (Task 10)
# ============================================================
# Automates non-project synthesis, implementation, timing closure,
# and bitstream generation for the CAMEO architecture on Nexys A7.
#
# Target Part: xc7a100tcsg324-1 (Artix-7 100T)
#
# Usage:
#   vivado -mode batch -source scripts/build_bitstream.tcl
# ============================================================

set SCRIPT_DIR [file dirname [info script]]
set REPO_DIR   [file normalize "$SCRIPT_DIR/.."]
set OUTPUT_DIR "$REPO_DIR/build_fpga"
file mkdir $OUTPUT_DIR

puts "============================================================"
puts "  CAMEO Dual-Core FPGA Bitstream Build"
puts "  Target: Digilent Nexys A7-100T (xc7a100tcsg324-1)"
puts "============================================================"

# 1. Read Verilog Sources
puts "\n[STEP 1/6] Reading RTL source files..."
set_param general.maxThreads 4

read_verilog -sv "$REPO_DIR/modules/opcode.vh"
read_verilog -sv "$REPO_DIR/modules/IF_ID.v"
read_verilog -sv "$REPO_DIR/modules/execute.v"
read_verilog -sv "$REPO_DIR/modules/wb.v"
read_verilog -sv "$REPO_DIR/modules/pipe.v"
read_verilog -sv "$REPO_DIR/modules/memory.v"
read_verilog -sv "$REPO_DIR/modules/mem_delay.v"
read_verilog -sv "$REPO_DIR/modules/perf_counters.v"
read_verilog -sv "$REPO_DIR/modules/mmio_decoder.v"
read_verilog -sv "$REPO_DIR/modules/result_streamer.v"
read_verilog -sv "$REPO_DIR/modules/uart_tx.v"
read_verilog -sv "$REPO_DIR/modules/sw_counter_display.v"
read_verilog -sv "$REPO_DIR/modules/seg7.v"
read_verilog -sv "$REPO_DIR/modules/top_fpga_dual.v"

# 2. Read Constraints
puts "\n[STEP 2/6] Reading XDC constraints..."
read_xdc "$REPO_DIR/constraints/constraint.xdc"

# 3. Synthesis
puts "\n[STEP 3/6] Running Synthesis (top_fpga_dual)..."
synth_design -top top_fpga_dual -part xc7a100tcsg324-1 -include_dirs "$REPO_DIR/modules"
write_checkpoint -force "$OUTPUT_DIR/post_synth.dcp"
report_utilization -file "$OUTPUT_DIR/synth_utilization.rpt"

# 4. Logic Optimization & Placement
puts "\n[STEP 4/6] Running Optimization & Placement..."
opt_design
place_design
phys_opt_design
write_checkpoint -force "$OUTPUT_DIR/post_place.dcp"

# 5. Routing & Timing Closure
puts "\n[STEP 5/6] Running Route & Timing Check..."
route_design
write_checkpoint -force "$OUTPUT_DIR/post_route.dcp"
report_timing_summary -file "$OUTPUT_DIR/timing_summary.rpt"
report_utilization    -file "$OUTPUT_DIR/route_utilization.rpt" -hierarchical
report_power          -file "$OUTPUT_DIR/power_report.rpt"

# 6. Generate Bitstream
puts "\n[STEP 6/6] Writing Bitstream..."
write_bitstream -force "$OUTPUT_DIR/cameo_dual_core.bit"

puts "\n============================================================"
puts "  BUILD COMPLETE: $OUTPUT_DIR/cameo_dual_core.bit"
puts "============================================================"
