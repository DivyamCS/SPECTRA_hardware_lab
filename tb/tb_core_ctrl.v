`timescale 1ns / 1ps
`default_nettype none
// tb_core_ctrl - DUAL = 0: core 1 stays in reset, ncores = 1; DUAL = 1: both cores
// leave reset in the same cycle, ncores = 2; HAS_CORE1 = 0 keeps core 1 in reset even with
// DUAL = 1. Prints one PASS/FAIL line.

module tb_core_ctrl;

    reg  clk = 1'b0, rst = 1'b1, dual = 1'b0;
    always #10 clk = ~clk;
    wire r0, r1, r1n;
    wire [1:0] nc, ncn;

    core_ctrl #(.HAS_CORE1(1)) dut  (.clk(clk), .rst(rst), .cfg_dual(dual), .rst_core0(r0), .rst_core1(r1), .ncores(nc));
    core_ctrl #(.HAS_CORE1(0)) dutn (.clk(clk), .rst(rst), .cfg_dual(dual), .rst_core0(), .rst_core1(r1n), .ncores(ncn));

    integer errors = 0, checks = 0, k;
    task chk(input [8*40-1:0] what, input [7:0] got, input [7:0] want);
        begin
            checks = checks + 1;
            if (got !== want) begin errors = errors + 1; $display("%0s: got %0d want %0d", what, got, want); end
        end
    endtask

    initial begin
        // in reset: both held
        repeat (2) @(negedge clk);
        chk("rst_core0 in reset", r0, 1); chk("rst_core1 in reset", r1, 1);
        // DUAL = 0
        rst = 1'b0;
        for (k = 0; k < 20; k = k + 1) begin
            @(negedge clk);
            chk("DUAL=0 core 0 runs", r0, 0); chk("DUAL=0 core 1 held", r1, 1); chk("DUAL=0 ncores", nc, 1);
        end
        // DUAL = 1 (cfg changes only at a reset release): both leave reset in the same cycle
        rst = 1'b1; dual = 1'b1;
        repeat (2) @(negedge clk);
        chk("DUAL=1 core 0 in reset", r0, 1); chk("DUAL=1 core 1 in reset", r1, 1);
        rst = 1'b0; #1;
        chk("same release cycle", {r0, r1}, 0);
        for (k = 0; k < 20; k = k + 1) begin
            @(negedge clk);
            chk("DUAL=1 both run", {r0, r1}, 0); chk("DUAL=1 ncores", nc, 2);
            chk("HAS_CORE1=0 core 1 held", r1n, 1); chk("HAS_CORE1=0 ncores", ncn, 1);
        end
        if (errors == 0) $display("PASS core_ctrl (%0d checks: DUAL 0/1, same-cycle release, HAS_CORE1 = 0)", checks);
        else             $display("FAIL core_ctrl: %0d errors", errors);
        $finish;
    end

endmodule

`default_nettype wire
