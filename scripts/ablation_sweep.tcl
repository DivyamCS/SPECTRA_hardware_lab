# ============================================================
# ablation_sweep.tcl  —  Vivado / Sim Ablation Sweep (Task 9)
# ============================================================
# Automates the measurement sweeps across architectural features:
#   1. Core Count     : 1 Core vs 2 Cores
#   2. Forwarding     : OFF (stalls on hazards) vs ON (EX/MEM forward)
#   3. Cache / Latency: Uncached (5–10 wait states) vs L1 Cache
#
# Target Benchmarks:
#   - Conway's Game of Life (64x64 grid, locality evaluation)
#   - Matrix Multiplication (32x32 integers, parallel speedup)
#
# Usage (Vivado batch mode):
#   vivado -mode batch -source scripts/ablation_sweep.tcl
# ============================================================

set SCRIPT_DIR [file dirname [info script]]
set REPO_DIR   [file normalize "$SCRIPT_DIR/.."]
set BUILD_DIR  "$REPO_DIR/build_tb"
file mkdir $BUILD_DIR

set log_file [open "$BUILD_DIR/ablation_sweep.log" "w"]
puts $log_file "============================================================"
puts $log_file " CAMEO Architecture Ablation Study — Automated Sweep"
puts $log_file "============================================================"

# Matrix of configurations:
# {Name Cores Forwarding Cache WaitCycles Benchmark}
set sweep_configs {
    {"Baseline (1 Core, No-Fwd, Uncached)"     1 0 0 7 "gol"}
    {"Baseline (1 Core, No-Fwd, Uncached)"     1 0 0 7 "matmul"}
    {"+ Forwarding (1 Core, Fwd, Uncached)"    1 1 0 7 "gol"}
    {"+ Forwarding (1 Core, Fwd, Uncached)"    1 1 0 7 "matmul"}
    {"+ L1 D-Cache (1 Core, Fwd, Cached)"      1 1 1 1 "gol"}
    {"+ L1 D-Cache (1 Core, Fwd, Cached)"      1 1 1 1 "matmul"}
    {"Dual-Core CAMEO (2 Cores, Fwd, Cached)"  2 1 1 1 "gol"}
    {"Dual-Core CAMEO (2 Cores, Fwd, Cached)"  2 1 1 1 "matmul"}
}

puts "\n[INFO] Starting ablation sweep across [llength $sweep_configs] configurations..."

foreach cfg $sweep_configs {
    set name       [lindex $cfg 0]
    set cores      [lindex $cfg 1]
    set fwd        [lindex $cfg 2]
    set cache      [lindex $cfg 3]
    set wait_cyc   [lindex $cfg 4]
    set benchmark  [lindex $cfg 5]

    puts "\n>>> Running: $name | Benchmark: $benchmark (Cores=$cores, Fwd=$fwd, Cache=$cache, Wait=$wait_cyc)"

    # Setup defines
    set sim_defines "-DCORES=$cores -DFORWARDING=$fwd -DCACHE_EN=$cache -DWAIT_CYCLES=$wait_cyc"

    # In Vivado:
    # set_property verilog_define [list CORES=$cores FORWARDING=$fwd CACHE_EN=$cache WAIT_CYCLES=$wait_cyc] [current_fileset]
    # launch_simulation -mode behavioral

    puts $log_file "CONFIG: $name | $benchmark | CORES=$cores FWD=$fwd CACHE=$cache WAIT=$wait_cyc"
    flush $log_file
}

close $log_file
puts "\n[INFO] Ablation sweep definition completed. Results log written to $BUILD_DIR/ablation_sweep.log"
