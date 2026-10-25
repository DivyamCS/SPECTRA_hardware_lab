`timescale 1ns / 1ps
`default_nettype none
// tb_seg7_bcd - driven by tb/seg7/run.py (seg7.mem in the run directory).
//  * fast instance (SCAN_BITS = 4: 2 cycles per digit): for every test, set value and dp, let
//    the conversion run, then read one whole scan: each digit's segments and decimal point
//    (active low on the pins) must equal tools/seg7_model.py, exactly one anode low at a time;
//  * the display keeps the old digits while a new conversion runs;
//  * real instance (SCAN_BITS = 16): digits scanned 0, 1, .., 7, each lit 8,192 cycles;
//  * blank after reset until the first conversion.
// Prints one PASS/FAIL line.

module tb_seg7_bcd;

    reg         clk = 1'b0, rst = 1'b1;
    always #10 clk = ~clk;
    reg  [26:0] value = 27'd0;
    reg  [7:0]  dp = 8'd0;
    reg  [31:0] txt = 32'd0;
    wire [7:0]  an, an16;
    wire [6:0]  seg, seg16;
    wire        dp_n, dp_n16;

    seg7_bcd #(.SCAN_BITS(4))  dut   (.clk(clk), .rst(rst), .value(value), .dp(dp), .txt(txt), .an(an), .seg(seg), .dp_n(dp_n));
    seg7_bcd #(.SCAN_BITS(16)) dut16 (.clk(clk), .rst(rst), .value(value), .dp(dp), .txt(txt), .an(an16), .seg(seg16), .dp_n(dp_n16));

    integer errors = 0, checks = 0, tests = 0, fd, r, i, k, c, d;
    reg [26:0] v; reg [7:0] p; reg [31:0] tx;
    reg [6:0] es [0:7]; reg ed [0:7];
    integer s0,s1,s2,s3,s4,s5,s6,s7, d0,d1,d2,d3,d4,d5,d6,d7;
    reg [7:0] seen;

    task fail(input [8*40-1:0] what, input [31:0] got, input [31:0] want);
        begin
            errors = errors + 1;
            if (errors <= 12) $display("%0s: got %0h want %0h (value %0d dp %02h)", what, got, want, value, dp);
        end
    endtask

    function integer onehot_idx(input [7:0] a);      // a is active low
        integer j;
        begin
            onehot_idx = -1;
            for (j = 0; j < 8; j = j + 1) if (a == ~(8'd1 << j)) onehot_idx = j;
        end
    endfunction

    // read one full scan of the fast instance and compare every digit
    task check_scan;
        begin
            seen = 8'd0;
            for (c = 0; c < 20; c = c + 1) begin
                @(negedge clk);
                d = onehot_idx(an);
                checks = checks + 1;
                if (d < 0) fail("anodes not one-hot", an, 0);
                else begin
                    seen[d] = 1'b1;
                    checks = checks + 2;
                    if (~seg !== es[d]) fail("segments", ~seg, es[d]);
                    if (~dp_n !== ed[d]) fail("decimal point", ~dp_n, ed[d]);
                end
            end
            checks = checks + 1;
            if (seen !== 8'hFF) fail("digits seen in a scan", seen, 8'hFF);
        end
    endtask

    initial begin
        // blank after reset
        repeat (3) @(negedge clk); rst = 1'b0;
        checks = checks + 1;
        if (seg !== 7'h7F || dp_n !== 1'b1) fail("not blank after reset", seg, 7'h7F);
        fd = $fopen("seg7.mem", "r");
        while (!$feof(fd)) begin
            r = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
                        v, p, tx, s0, d0, s1, d1, s2, d2, s3, d3, s4, d4, s5, d5, s6, d6, s7, d7);
            if (r == 19) begin
                es[0]=s0; es[1]=s1; es[2]=s2; es[3]=s3; es[4]=s4; es[5]=s5; es[6]=s6; es[7]=s7;
                ed[0]=d0; ed[1]=d1; ed[2]=d2; ed[3]=d3; ed[4]=d4; ed[5]=d5; ed[6]=d6; ed[7]=d7;
                @(negedge clk);
                value = v; dp = p; txt = tx;
                repeat (35) @(negedge clk);                 // conversion: 1 + 27 cycles
                check_scan;
                tests = tests + 1;
            end
        end
        $fclose(fd);
        // old digits stay while a conversion runs: 1234 shown, then change to 5678
        @(negedge clk); value = 27'd1234; dp = 8'd0;
        repeat (40) @(negedge clk);
        value = 27'd5678;
        for (k = 0; k < 20; k = k + 1) begin
            @(negedge clk);
            if (onehot_idx(an) == 0) begin
                checks = checks + 1;
                if (~seg !== 7'h66) fail("old digit 0 (4) kept during conversion", ~seg, 7'h66);
            end
        end
        // real scan: order 0..7, each digit 8,192 cycles
        @(negedge clk);
        while (an16 !== 8'hFE) @(negedge clk);              // wait for digit 0 to begin
        for (k = 0; k < 8; k = k + 1) begin
            c = 0;
            while (an16 === ~(8'd1 << k)) begin @(negedge clk); c = c + 1; end
            checks = checks + 2;
            if (c != 8192) fail("digit period (cycles)", c, 8192);
            if (k < 7 && an16 !== ~(8'd1 << (k + 1))) fail("scan order", an16, ~(8'd1 << (k + 1)));
        end
        if (errors == 0 && tests > 1000)
            $display("PASS seg7_bcd (%0d checks: %0d values = seg7_model.py, old digits kept, scan 0..7 at 8192 cycles each)", checks, tests);
        else
            $display("FAIL seg7_bcd: %0d errors in %0d checks", errors, checks);
        $finish;
    end

endmodule

`default_nettype wire
