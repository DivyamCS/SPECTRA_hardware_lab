# vio_ip.tcl - create the VIO core vio_0 for vio_hook.v (PROTOCOL.md section 10). Sourced by
# scripts/build.tcl through a "-t scripts/vio_ip.tcl" line in the file list, in the output
# directory, before the RTL is read. Probes: out0 ovr_en (1), out1 ovr_sw (16), out2 ovr_btn (5);
# in0 leds (16), in1 seg7_val (32), in2 seg7_dp (8), in3 uart_busy (1), in4 seg7_txt (32).
# ovr_en starts at 0.

set_part $opt(-part)
file mkdir ip
create_ip -name vio -vendor xilinx.com -library ip -module_name vio_0 -dir [file normalize ip]
set_property -dict [list \
    CONFIG.C_NUM_PROBE_OUT {3} CONFIG.C_PROBE_OUT0_WIDTH {1} CONFIG.C_PROBE_OUT1_WIDTH {16} \
    CONFIG.C_PROBE_OUT2_WIDTH {5} CONFIG.C_PROBE_OUT0_INIT_VAL {0x0} \
    CONFIG.C_NUM_PROBE_IN {5} CONFIG.C_PROBE_IN0_WIDTH {16} CONFIG.C_PROBE_IN1_WIDTH {32} \
    CONFIG.C_PROBE_IN2_WIDTH {8} CONFIG.C_PROBE_IN3_WIDTH {1} CONFIG.C_PROBE_IN4_WIDTH {32}] [get_ips vio_0]
generate_target all [get_ips vio_0]
synth_ip [get_ips vio_0]
