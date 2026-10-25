`timescale 1ns / 1ps
`default_nettype none
// tb_uart_top - A line monitor measures every level change of tx:
//  * every bit lasts exactly 50 cycles (a run of equal bits lasts a multiple of 50), each frame
//    is start 0, 8 data bits LSB first, stop 1, and frames sent back to back have no idle gap;
//  * 256 bytes pushed in a row arrive in order and intact;
//  * pushing one byte per cycle while !full: full rises exactly when 512 bytes sit in the FIFO,
//    and every accepted byte (1,500 in all) arrives, none lost or repeated;
//  * tx idles high after reset and after the last byte; busy falls only after the last stop bit.
// Prints one PASS/FAIL line.

module tb_uart_top;

    reg        clk = 1'b0, rst = 1'b1, wr = 1'b0;
    reg  [7:0] wr_data = 8'd0;
    wire       full, busy, tx;
    always #10 clk = ~clk;

    uart_top dut (.clk(clk), .rst(rst), .wr(wr), .wr_data(wr_data), .full(full), .busy(busy), .tx(tx));

    integer errors = 0, checks = 0;
    task fail(input [8*48-1:0] what, input [31:0] got, input [31:0] want);
        begin
            errors = errors + 1;
            if (errors <= 12) $display("%0s: got %0d want %0d (t=%0t)", what, got, want, $time);
        end
    endtask

    // ---- line monitor: sample tx every cycle, decode frames at the bit centres
    reg  [7:0] sent [0:4095];          // bytes accepted by the FIFO, in order
    integer    n_sent = 0, n_got = 0, cyc = 0, last_edge = 0, gaps = 0;
    reg        prev_tx = 1'b1, in_frame = 1'b0;
    integer    fstart = -1000, b, b2b = 0;
    reg  [7:0] byte_r;
    always @(posedge clk) begin
        cyc = cyc + 1;
        if (!rst && wr && !full) begin sent[n_sent] = wr_data; n_sent = n_sent + 1; end
        // every level change happens a multiple of 50 cycles after the previous one while busy
        if (tx !== prev_tx) begin
            checks = checks + 1;
            if (in_frame && ((cyc - last_edge) % 50) != 0) fail("level held a non-multiple of 50 cycles", cyc - last_edge, 50);
            last_edge = cyc;
        end
        // a frame begins with a falling edge outside a frame
        if (!in_frame && prev_tx === 1'b1 && tx === 1'b0) begin
            if (cyc == fstart + 500) b2b = b2b + 1;           // starts right after the last frame
            in_frame = 1'b1; fstart = cyc;
        end
        if (in_frame) begin
            b = (cyc - fstart) / 50;                       // bit number, sampled at its centre
            if ((cyc - fstart) % 50 == 25) begin
                checks = checks + 1;
                if (b == 0 && tx !== 1'b0) fail("start bit", tx, 0);
                if (b >= 1 && b <= 8) byte_r[b - 1] = tx;
                if (b == 9) begin
                    if (tx !== 1'b1) fail("stop bit", tx, 1);
                    checks = checks + 1;
                    if (byte_r !== sent[n_got]) fail("byte", byte_r, sent[n_got]);
                    n_got = n_got + 1;
                end
            end
            if (cyc - fstart == 499) begin
                in_frame = 1'b0;                            // frame over after 500 cycles
            end
        end
        prev_tx = tx;
    end

    integer k, t0;
    initial begin
        repeat (3) @(negedge clk);
        checks = checks + 1; if (tx !== 1'b1) fail("tx idle in reset", tx, 1);
        rst = 1'b0;
        // 256 bytes in a row, one per cycle
        for (k = 0; k < 256; k = k + 1) begin
            @(negedge clk); wr = 1'b1; wr_data = k ^ 8'h5A;
        end
        @(negedge clk); wr = 1'b0;
        wait (!busy);
        repeat (10) @(negedge clk);
        checks = checks + 3;
        if (n_got != 256) fail("bytes received after 256", n_got, 256);
        if (b2b != 255) fail("frames sent back to back", b2b, 255);   // no idle gap
        if (tx !== 1'b1) fail("tx idle after the last byte", tx, 1);
        // fill: push one byte per cycle while !full until 1,500 more are accepted
        k = 0;
        while (n_sent < 256 + 1500) begin
            @(negedge clk);
            if (full) begin
                // full exactly when 512 bytes sit in the RAM
                checks = checks + 1;
                if (dut.count !== 10'd512) fail("full without 512 bytes", dut.count, 512);
                wr = 1'b0;
            end else begin
                wr = 1'b1; wr_data = $random;
                if (dut.count == 10'd512) fail("not full with 512 bytes", 0, 1);
            end
        end
        @(negedge clk); wr = 1'b0;
        wait (!busy);
        repeat (10) @(negedge clk);
        checks = checks + 1;
        if (n_got != n_sent) fail("bytes received vs accepted", n_got, n_sent);
        if (errors == 0 && checks > 10000)
            $display("PASS uart_top (%0d checks: %0d bytes, every bit 50 cycles, back to back, full at 512, none lost)", checks, n_got);
        else
            $display("FAIL uart_top: %0d errors in %0d checks", errors, checks);
        $finish;
    end

endmodule

`default_nettype wire
