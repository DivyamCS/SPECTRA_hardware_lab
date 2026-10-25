`timescale 1ns / 1ps
`default_nettype none
// tb_regfile - directed checks (reset to 0, x0 stays 0 when written, same-cycle write and read
// returns the new value on both ports) and 10,000 random cycles against a behavioural model
// (a third of the reads aimed at the register being written). Prints one PASS/FAIL line.

module tb_regfile;

    reg         clk = 1'b0, rst = 1'b1, we = 1'b0;
    reg  [4:0]  raddr1 = 5'd0, raddr2 = 5'd0, waddr = 5'd0;
    reg  [31:0] wdata = 32'd0;
    wire [31:0] rdata1, rdata2;

    regfile dut (.clk(clk), .rst(rst), .raddr1(raddr1), .raddr2(raddr2), .rdata1(rdata1),
                 .rdata2(rdata2), .we(we), .waddr(waddr), .wdata(wdata));

    always #10 clk = ~clk;

    reg  [31:0] model [0:31];
    integer i, k, errors = 0, checks = 0, seed = 41;

    function [31:0] expect_rd(input [4:0] ra);
        expect_rd = (ra == 5'd0) ? 32'd0 : (we && waddr == ra) ? wdata : model[ra];
    endfunction

    task check_ports;
        begin
            #1;                                          // combinational outputs settle
            checks = checks + 2;
            if (rdata1 !== expect_rd(raddr1)) begin
                errors = errors + 1;
                if (errors <= 5) $display("port1: x%0d got %08h want %08h", raddr1, rdata1, expect_rd(raddr1));
            end
            if (rdata2 !== expect_rd(raddr2)) begin
                errors = errors + 1;
                if (errors <= 5) $display("port2: x%0d got %08h want %08h", raddr2, rdata2, expect_rd(raddr2));
            end
        end
    endtask

    task tick;                                           // clock edge, then update the model
        begin
            @(posedge clk);
            if (we && waddr != 5'd0) model[waddr] = wdata;
            #1;
        end
    endtask

    initial begin
        for (i = 0; i < 32; i = i + 1) model[i] = 32'd0;
        @(posedge clk); @(posedge clk); #1; rst = 1'b0;
        // 1. after reset every register reads 0
        for (i = 0; i < 32; i = i + 1) begin raddr1 = i; raddr2 = 31 - i; check_ports; end
        // 2. writing x0 has no effect, also not through write-through
        we = 1'b1; waddr = 5'd0; wdata = 32'hFFFFFFFF; raddr1 = 5'd0; raddr2 = 5'd0; check_ports; tick;
        we = 1'b0; check_ports;
        // 3. same-cycle write and read: new value on both ports, before and after the edge
        we = 1'b1; waddr = 5'd7; wdata = 32'h12345678; raddr1 = 5'd7; raddr2 = 5'd7; check_ports;
        if (rdata1 !== 32'h12345678 || rdata2 !== 32'h12345678) errors = errors + 1;
        tick; we = 1'b0; check_ports;
        if (rdata1 !== 32'h12345678) errors = errors + 1;
        // 4. random cycles
        for (k = 0; k < 10000; k = k + 1) begin
            we     = $random(seed);
            waddr  = $random(seed);
            wdata  = $random(seed);
            raddr1 = ($random(seed) % 3 == 0) ? waddr : $random(seed);
            raddr2 = ($random(seed) % 3 == 0) ? waddr : $random(seed);
            check_ports;
            tick;
        end
        if (errors == 0 && checks > 20000)
            $display("PASS regfile (%0d port checks: reset, x0, write-through, 10000 random cycles)", checks);
        else
            $display("FAIL regfile: %0d errors in %0d checks", errors, checks);
        $finish;
    end

endmodule

`default_nettype wire
