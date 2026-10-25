`timescale 1ns / 1ps
`default_nettype none
// tb_clk_rst - clk_rst with Xilinx's MMCME2_BASE simulation model.
//  * rst stays high until the MMCM locks, then falls on a clk rising edge after at least 18
//    clk cycles of lock (2 synchroniser flops + 16), and never before lock;
//  * clk is 50 MHz once locked (20.000 ns between rising edges);
//  * a one-cycle pulse on btn_rst during a run (as from vio_hook's synchroniser flop) gives a
//    full reset: rst rises on a clk edge within 3 edges (never between edges), then >= 18
//    cycles counted from the pulse;
//  * a long button press holds rst; release is synchronous to clk.
// Prints one PASS/FAIL line.

module tb_clk_rst;

    reg  clk100 = 1'b0, btn = 1'b0;
    always #5 clk100 = ~clk100;
    wire clk, rst, locked;

    clk_rst dut (.clk100(clk100), .btn_rst(btn), .clk(clk), .rst(rst), .locked(locked));

    integer errors = 0, checks = 0, n;
    realtime t_lock, t_prev, t_rel;
    task fail(input [8*48-1:0] what, input integer got, input integer want);
        begin
            errors = errors + 1;
            $display("%0s: got %0d want %0d (t=%0t)", what, got, want, $time);
        end
    endtask

    // count clk rising edges until rst falls, starting from `start` (edges already elapsed since
    // the event); check it falls on a clk edge
    integer edges;
    task wait_release(input [8*32-1:0] what, input integer start);
        begin
            edges = start;
            while (rst) begin
                @(posedge clk or negedge rst);
                if (rst) edges = edges + 1;
                else begin
                    checks = checks + 1;
                    if (clk !== 1'b1) fail("release not on a clk rising edge", 0, 1);
                end
                t_prev = $realtime;
            end
            checks = checks + 1;
            if (edges < 18) fail(what, edges, 18);
        end
    endtask

    // rst must never be low while the MMCM is unlocked
    always @(negedge rst) if (!locked) fail("rst released before lock", 0, 1);

    initial begin
        // power-up: rst high until lock
        #1; checks = checks + 1;
        if (rst !== 1'b1) fail("rst at power-up", rst, 1);
        @(posedge locked); t_lock = $realtime;
        wait_release("cycles from lock to release", 0);
        // clk period once locked
        @(posedge clk); t_prev = $realtime;
        for (n = 0; n < 50; n = n + 1) begin
            @(posedge clk); checks = checks + 1;
            if ($realtime - t_prev < 19.999 || $realtime - t_prev > 20.001) fail("clk period (ps)", ($realtime - t_prev) * 1000, 20000);
            t_prev = $realtime;
        end
        // a one-cycle pulse on btn_rst during a run (driven just after a clk edge, like a flop)
        repeat (10) @(posedge clk);
        #0.5 btn = 1'b1;
        @(posedge clk); #0.5 btn = 1'b0;
        #0.1; checks = checks + 1;
        if (rst !== 1'b0) fail("rst changed between clk edges after a pulse", rst, 0);
        n = 0;
        while (rst !== 1'b1 && n < 4) begin
            @(posedge clk); n = n + 1;
            if (rst === 1'b1) begin checks = checks + 1; fail("rst rose before the clk edge's update", 1, 0); end
            #0.1;
        end
        checks = checks + 1;
        if (rst !== 1'b1 || n > 3) fail("clk edges from pulse to rst (max 3)", n, 3);
        wait_release("cycles after a pulse", n + 1);
        // a long press: rst held, then released synchronously after the button
        repeat (5) @(posedge clk);
        #7; btn = 1'b1;
        repeat (3) @(posedge clk);                              // synchroniser: rst within 3 edges
        repeat (37) begin @(posedge clk); checks = checks + 1; if (!rst) fail("rst low while pressed", 0, 1); end
        #3; btn = 1'b0;
        wait_release("cycles after a press", 0);
        repeat (5) @(posedge clk);
        if (errors == 0 && checks > 50)
            $display("PASS clk_rst (%0d checks: held until lock (%0.0f ns), 50 MHz, a 1-cycle pulse and a press give full resets, rst changes only on clk edges)", checks, t_lock);
        else
            $display("FAIL clk_rst: %0d errors", errors);
        $finish;
    end

endmodule

`default_nettype wire
