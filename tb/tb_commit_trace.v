`timescale 1ns / 1ps
`default_nettype none
// tb_commit_trace - driven by tb/commit_trace/run.py. Replays retire events made
// from rv32sim reference traces (vector files in the run directory) into commit_trace, with 0-2
// idle cycles between events (retire = 0, every other input random) and a reset phase with
// retire = 1 (must print nothing). Store data carries random bits above the access size.
// run.py then compares trace_rtl0.txt with the reference, byte for byte and with tracecmp.py.
// Prints "PASS commit_trace_drive" when every event has been driven.

module tb_commit_trace;

    localparam MAXN = 65536;
    reg [31:0] v_pc [0:MAXN-1], v_ins [0:MAXN-1], v_val [0:MAXN-1], v_addr [0:MAXN-1],
               v_sd [0:MAXN-1], v_flags [0:MAXN-1];
    reg [31:0] v_n [0:0];

    reg         clk = 1'b0, rst = 1'b1, retire = 1'b0, wb_we = 1'b0, is_load = 1'b0, is_store = 1'b0;
    reg  [31:0] pc = 0, instr = 0, wb_data = 0, addr = 0, store_data = 0;
    reg  [4:0]  wb_rd = 0;
    reg  [1:0]  mem_size = 0;
    always #10 clk = ~clk;

    commit_trace #(.HART_ID(0)) dut (
        .clk(clk), .rst(rst), .retire(retire), .pc(pc), .instr(instr), .wb_we(wb_we),
        .wb_rd(wb_rd), .wb_data(wb_data), .is_load(is_load), .is_store(is_store),
        .mem_size(mem_size), .addr(addr), .store_data(store_data));

    integer k, g, seed = 47;

    task garbage;
        begin
            pc = $random(seed); instr = $random(seed); wb_data = $random(seed); addr = $random(seed);
            store_data = $random(seed); wb_rd = $random(seed); mem_size = $random(seed);
            wb_we = $random(seed); is_load = $random(seed); is_store = $random(seed);
        end
    endtask

    initial begin
        $readmemh("n.mem", v_n);
        $readmemh("pc.mem", v_pc);   $readmemh("ins.mem", v_ins);  $readmemh("val.mem", v_val);
        $readmemh("addr.mem", v_addr); $readmemh("sd.mem", v_sd); $readmemh("flags.mem", v_flags);
        // reset phase: retire high with garbage, nothing may be written
        for (g = 0; g < 3; g = g + 1) begin @(negedge clk); garbage; retire = 1'b1; end
        @(negedge clk); rst = 1'b0; retire = 1'b0;
        for (k = 0; k < v_n[0]; k = k + 1) begin
            for (g = $unsigned($random(seed)) % 3; g > 0; g = g - 1) begin
                @(negedge clk); garbage; retire = 1'b0;
            end
            @(negedge clk);
            retire = 1'b1; pc = v_pc[k]; instr = v_ins[k]; wb_data = v_val[k]; addr = v_addr[k];
            store_data = v_sd[k];
            wb_we = v_flags[k][0]; wb_rd = v_flags[k][5:1]; is_load = v_flags[k][6];
            is_store = v_flags[k][7]; mem_size = v_flags[k][9:8];
        end
        @(negedge clk); retire = 1'b0; garbage;
        @(negedge clk); @(negedge clk);
        $display("PASS commit_trace_drive (%0d events)", v_n[0]);
        $finish;
    end

endmodule

`default_nettype wire
