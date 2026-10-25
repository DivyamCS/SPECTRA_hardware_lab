`timescale 1ns / 1ps
`default_nettype none
// tb_switch_cfg - Two instances: the real one (debounce 2^16 cycles) and one with
// DEB_BITS = 4 for long random runs. Checks:
//  * a clean change reaches sw_live exactly 2 + 2^N cycles later (2 synchroniser flops);
//  * a bounce shorter than 2^N cycles never reaches sw_live (2^16 - 2 cycles on the real one);
//  * random bouncing (DEB 4, 20,000 cycles): sw_live equals a model of the rule;
//  * cfg is 0 during reset, equals the debounced switches of the cycle reset releases from the
//    first cycle after, and ignores later switch changes until the next reset.
// Prints one PASS/FAIL line.

module tb_switch_cfg;

    reg         clk = 1'b0, rst = 1'b1;
    reg  [15:0] sw = 16'd0;
    always #10 clk = ~clk;
    wire [15:0] cfg, live, cfg4, live4;

    switch_cfg #(.DEB_BITS(16)) dut  (.clk(clk), .rst(rst), .sw(sw), .cfg(cfg),  .sw_live(live));
    switch_cfg #(.DEB_BITS(4))  dut4 (.clk(clk), .rst(rst), .sw(sw), .cfg(cfg4), .sw_live(live4));

    integer errors = 0, checks = 0, k, n, seed = 81;
    task fail(input [8*48-1:0] what, input [31:0] got, input [31:0] want);
        begin
            errors = errors + 1;
            if (errors <= 12) $display("%0s: got %04h want %04h (t=%0t)", what, got, want, $time);
        end
    endtask

    // model of one instance's sw_live (synchroniser + per-bit counters), stepped every edge
    reg [15:0] m_s1 = 0, m_s2 = 0, m_live = 0;
    integer    m_cnt [0:15];
    initial for (k = 0; k < 16; k = k + 1) m_cnt[k] = 0;
    always @(posedge clk) begin
        for (n = 0; n < 16; n = n + 1) begin
            if (m_s2[n] == m_live[n]) m_cnt[n] = 0;
            else if (m_cnt[n] == 15) begin m_live[n] = m_s2[n]; m_cnt[n] = 0; end
            else m_cnt[n] = m_cnt[n] + 1;
        end
        m_s2 = m_s1; m_s1 = sw;
    end
    always @(negedge clk) begin
        checks = checks + 1;
        if (live4 !== m_live) fail("DEB 4 sw_live vs model", live4, m_live);
    end

    integer c;
    initial begin
        repeat (3) @(negedge clk);
        // clean change of SW0 and SW15: exactly 2 + 65536 cycles on the real instance
        sw = 16'h8001;
        c = 0;
        while (live !== 16'h8001 && c < 70000) begin @(posedge clk); #1; c = c + 1; end
        checks = checks + 1;
        if (c != 2 + 65536) fail("clean change latency", c, 2 + 65536);
        // a bounce of 65534 cycles never gets through
        @(negedge clk); sw = 16'h8003;
        repeat (65534) @(negedge clk);
        sw = 16'h8001;
        repeat (100) begin
            @(negedge clk); checks = checks + 1;
            if (live !== 16'h8001) fail("short bounce reached sw_live", live, 16'h8001);
        end
        // random bouncing on the DEB 4 instance (checked every cycle against the model)
        for (k = 0; k < 20000; k = k + 1) begin
            @(negedge clk);
            if ($unsigned($random(seed)) % 8 == 0) sw = sw ^ (16'd1 << ($unsigned($random(seed)) % 16));
        end
        // cfg: set a value, let it settle, reset, release
        @(negedge clk); sw = 16'hA5C3;
        repeat (2 + 65536 + 5) @(negedge clk);
        rst = 1'b1;
        repeat (5) begin @(negedge clk); checks = checks + 1; if (cfg !== 16'd0) fail("cfg during reset", cfg, 0); end
        @(negedge clk); rst = 1'b0;
        #1; checks = checks + 1;
        if (cfg !== 16'hA5C3) fail("cfg in the first cycle after reset", cfg, 16'hA5C3);
        sw = 16'h1234;                                   // changes after reset are ignored
        repeat (2 + 65536 + 10) @(negedge clk);
        checks = checks + 2;
        if (cfg !== 16'hA5C3) fail("cfg changed after reset", cfg, 16'hA5C3);
        if (live !== 16'h1234) fail("sw_live follows the switches", live, 16'h1234);
        // next reset samples the new value
        rst = 1'b1; repeat (3) @(negedge clk); rst = 1'b0; #1;
        checks = checks + 1;
        if (cfg !== 16'h1234) fail("cfg after the second reset", cfg, 16'h1234);
        if (errors == 0 && checks > 20000)
            $display("PASS switch_cfg (%0d checks: 2 + 2^16 cycle latency, short bounce blocked, 20000 random cycles = model, cfg sampled at reset)", checks);
        else
            $display("FAIL switch_cfg: %0d errors in %0d checks", errors, checks);
        $finish;
    end

endmodule

`default_nettype wire
