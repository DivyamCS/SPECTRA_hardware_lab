`timescale 1ns / 1ps
`default_nettype none
// tb_lock_barrier - rr_arbiter + lock_barrier with two TB cores and a downstream
// port stub (ready in cycle 2).
//  LOCK (lock_barrier alone): back-to-back reads from core 0 and core 1: exactly one gets 0;
//    release by a write of 0, re-acquire; a write of another value does not release.
//  BARRIER through the arbiter (spec 1.0.1), 1,000 rounds with ncores = 2, either core first,
//    random arrival gaps, plus ordinary port traffic from the core that is not waiting:
//    no core is released before both arrived, both in the same cycle, rdata 0; the other
//    core's accesses proceed while one waits; ev_barwait counts exactly the waiting cycles.
//    With ncores = 1: core 0's BARRIER read answers in cycle 2.
// Prints one PASS/FAIL line.

module tb_lock_barrier;

    reg         clk = 1'b0, rst = 1'b1;
    always #10 clk = ~clk;
    reg  [1:0]  ncores = 2'd2;

    // ---- LOCK on lock_barrier directly
    reg  lock_rd = 0, lock_wr0 = 0, l_owner = 0;
    wire lock_rdata, bw0, bw1;
    wire [1:0] bar_req, bar_release;
    lock_barrier dut (.clk(clk), .rst(rst), .ncores(ncores), .lock_rd(lock_rd), .lock_wr0(lock_wr0),
                      .owner(l_owner), .lock_rdata(lock_rdata), .bar_req(bar_req), .bar_release(bar_release),
                      .ev_barwait0(bw0), .ev_barwait1(bw1));

    // ---- arbiter with two TB cores
    reg         req0 = 0, req1 = 0, we0 = 0, we1 = 0;
    reg  [31:0] addr0 = 0, addr1 = 0;
    wire [31:0] rdata0, rdata1, m_addr, m_wdata;
    wire        ready0, ready1, m_req, m_we, m_owner, aw0, aw1;
    wire [3:0]  m_be;
    reg         m_ready = 0;
    rr_arbiter arb (.clk(clk), .rst(rst),
        .req0(req0), .we0(we0), .addr0(addr0), .wdata0(32'd0), .be0(4'hF), .rdata0(rdata0), .ready0(ready0),
        .req1(req1), .we1(we1), .addr1(addr1), .wdata1(32'd0), .be1(4'hF), .rdata1(rdata1), .ready1(ready1),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata), .m_be(m_be), .m_owner(m_owner),
        .m_rdata(32'hDEADBEEF), .m_ready(m_ready), .bar_req(bar_req), .bar_release(bar_release),
        .ev_arbwait0(aw0), .ev_arbwait1(aw1));
    // downstream stub: ready in the cycle after a request first appears
    always @(posedge clk) m_ready <= m_req && !m_ready && !rst;

    integer errors = 0, checks = 0, seed = 85;
    task fail(input [8*48-1:0] what, input integer got, input integer want);
        begin
            errors = errors + 1;
            if (errors <= 12) $display("%0s: got %0d want %0d (t=%0t)", what, got, want, $time);
        end
    endtask

    // barrier bookkeeping, sampled every cycle
    reg  at0 = 0, at1 = 0;                 // the TB core is inside a BARRIER read
    integer wait0 = 0, wait1 = 0, ev0 = 0, ev1 = 0, rel_both = 0, other_done = 0;
    always @(negedge clk) if (!rst) begin
        if (bw0) ev0 = ev0 + 1;
        if (bw1) ev1 = ev1 + 1;
        if (at0 && bar_req[0] && !ready0) wait0 = wait0 + 1;
        if (at1 && bar_req[1] && !ready1) wait1 = wait1 + 1;
    end

    integer r, k, g0, g1, first, c, z;
    initial begin
        repeat (2) @(negedge clk); rst = 1'b0;
        // ---------------------------------------------------------- LOCK
        lock_rd = 1; l_owner = 0; #1;
        checks = checks + 1; if (lock_rdata !== 1'b0) fail("first LOCK read", lock_rdata, 0);
        @(negedge clk); l_owner = 1; #1;                  // back to back from core 1
        checks = checks + 1; if (lock_rdata !== 1'b1) fail("second LOCK read", lock_rdata, 1);
        @(negedge clk); lock_rd = 0; lock_wr0 = 1;          // release
        @(negedge clk); lock_wr0 = 0; lock_rd = 1; l_owner = 1; #1;
        checks = checks + 1; if (lock_rdata !== 1'b0) fail("re-acquire after release", lock_rdata, 0);
        @(negedge clk); lock_rd = 0;
        for (k = 0; k < 200; k = k + 1) begin               // random back-to-back pairs
            lock_wr0 = 1; @(negedge clk); lock_wr0 = 0;
            lock_rd = 1; l_owner = $random(seed); #1; g0 = lock_rdata;
            @(negedge clk); l_owner = !l_owner; #1; g1 = lock_rdata;
            @(negedge clk); lock_rd = 0;
            checks = checks + 1;
            if (g0 + g1 != 1) fail("one of two LOCK reads gets 0", g0 + g1, 1);
        end
        // ---------------------------------------------------------- BARRIER, two cores
        for (r = 0; r < 1000; r = r + 1) begin
            first = $random(seed) & 1;
            g0 = 1 + $unsigned($random(seed)) % 20;          // gap before the second arrives
            if (first == 0) begin we0 = 0; addr0 = 32'h2000000C; req0 = 1; at0 = 1; end
            else            begin we1 = 0; addr1 = 32'h2000000C; req1 = 1; at1 = 1; end
            // meanwhile the other core makes ordinary accesses, which must complete
            for (c = 0; c < g0; c = c + 1) begin
                if (first == 0) begin req1 = 1; we1 = 1; addr1 = 32'h10000000 + 4 * c; end
                else            begin req0 = 1; we0 = 1; addr0 = 32'h10000000 + 4 * c; end
                @(negedge clk);
                z = 0;
                while (!(first == 0 ? ready1 : ready0) && z < 200) begin
                    z = z + 1;
                    checks = checks + 1;
                    if (first == 0 ? ready0 : ready1) fail("released before the other core arrived", 1, 0);
                    @(negedge clk);
                end
                if (z >= 200) begin fail("the other core's access never completed (port held?)", 0, 1); $finish; end
                other_done = other_done + 1;
                if (first == 0) req1 = 0; else req0 = 0;
                checks = checks + 1;
                if (first == 0 ? ready0 : ready1) fail("released before the other core arrived", 1, 0);
            end
            // the second core arrives
            @(negedge clk);
            if (first == 0) begin we1 = 0; addr1 = 32'h2000000C; req1 = 1; at1 = 1; end
            else            begin we0 = 0; addr0 = 32'h2000000C; req0 = 1; at0 = 1; end
            z = 0;
            while (!(ready0 || ready1) && z < 10) begin @(negedge clk); z = z + 1; end
            checks = checks + 3;
            if (!(ready0 && ready1)) fail("both released in the same cycle", {ready0, ready1}, 3);
            if (rdata0 !== 32'd0 || rdata1 !== 32'd0) fail("BARRIER reads 0", rdata0 | rdata1, 0);
            if (z != 1) fail("release cycle after the second arrival", z + 1, 2);
            rel_both = rel_both + 1;
            @(negedge clk); req0 = 0; req1 = 0; at0 = 0; at1 = 0;
            repeat ($unsigned($random(seed)) % 3) @(negedge clk);
        end
        checks = checks + 2;
        if (ev0 != wait0) fail("core 0 BAR_WAIT cycles", ev0, wait0);
        if (ev1 != wait1) fail("core 1 BAR_WAIT cycles", ev1, wait1);
        // ---------------------------------------------------------- BARRIER, one core
        ncores = 2'd1;
        for (r = 0; r < 20; r = r + 1) begin
            @(negedge clk); we0 = 0; addr0 = 32'h2000000C; req0 = 1;
            #1; checks = checks + 1; if (ready0) fail("one-core BARRIER in cycle 1", 1, 0);
            @(negedge clk); #1;
            checks = checks + 1; if (!ready0) fail("one-core BARRIER in cycle 2", 0, 1);
            @(negedge clk); req0 = 0;
        end
        if (errors == 0 && rel_both == 1000)
            $display("PASS lock_barrier (%0d checks: LOCK pairs, 1000 two-core barrier rounds with %0d other accesses during waits, BAR_WAIT %0d / %0d, one-core barrier)",
                     checks, other_done, ev0, ev1);
        else
            $display("FAIL lock_barrier: %0d errors in %0d checks", errors, checks);
        $finish;
    end

endmodule

`default_nettype wire
