`timescale 1ns / 1ps
`default_nettype none
// tb_mem_delay - mem_delay in front of a 1,024-word BRAM model (1-cycle
// synchronous read, byte enables). For L = 5, 6, 8 and 10:
//  * 1-word read and 4-word read: rvalid exactly in cycles L .. L+n-1 (start = cycle 0) with
//    the right words, done with the last, nothing outside;
//  * 1-word write with each of the 16 byte-enable patterns, 4-word write: wready exactly in
//    cycles L .. L+n-1, memory written as the model says;
//  * back to back: the next start in the cycle after done is accepted; a start while a burst
//    is open (and in the done cycle) is ignored;
//  * 2,000 random bursts (read/write, 1/4 words, random gaps 0-3) against the model.
// Prints one PASS/FAIL line.

module tb_mem_delay;

    reg         clk = 1'b0, rst = 1'b1;
    always #10 clk = ~clk;

    reg  [1:0]  lat = 2'd0;
    reg         start = 1'b0, we = 1'b0, nwords = 1'b0;
    reg  [29:0] addr = 30'd0;
    reg  [31:0] wdata = 32'd0;
    reg  [3:0]  be = 4'hF;
    wire        rvalid, wready, done, m_we;
    wire [31:0] rdata, m_wdata;
    wire [29:0] m_addr;
    wire [3:0]  m_be;
    reg  [31:0] m_rdata = 32'd0;

    mem_delay dut (.clk(clk), .rst(rst), .lat(lat), .start(start), .we(we), .addr(addr),
                   .nwords(nwords), .wdata(wdata), .be(be), .rvalid(rvalid), .rdata(rdata),
                   .wready(wready), .done(done), .m_addr(m_addr), .m_we(m_we), .m_be(m_be),
                   .m_wdata(m_wdata), .m_rdata(m_rdata));

    // BRAM model and reference model
    reg [31:0] bram [0:1023];
    reg [31:0] model [0:1023];
    integer n, nb;
    always @(posedge clk) begin
        m_rdata <= bram[m_addr[9:0]];
        if (m_we) for (nb = 0; nb < 4; nb = nb + 1) if (m_be[nb]) bram[m_addr[9:0]][8*nb +: 8] <= m_wdata[8*nb +: 8];
    end

    integer errors = 0, checks = 0, seed = 55;
    task fail(input [8*48-1:0] what, input [31:0] got, input [31:0] want);
        begin
            errors = errors + 1;
            if (errors <= 12) $display("%0s: got %08h want %08h (L code %0d, t=%0t)", what, got, want, lat, $time);
        end
    endtask

    function integer lval(input [1:0] c);
        lval = (c == 0) ? 5 : (c == 1) ? 6 : (c == 2) ? 8 : 10;
    endfunction

    // one burst, called at a negedge: start in cycle 0 (sampled at the next posedge),
    // then check every cycle up to and including done; `extra_start` pulses start again while
    // the burst is open (it must be ignored)
    integer c, L, nw, k, wcount;
    reg [31:0] wd [0:3];
    task burst(input w, input four, input [29:0] a, input [3:0] bmask, input extra_start);
        begin
            L = lval(lat); nw = four ? 4 : 1;
            for (k = 0; k < 4; k = k + 1) wd[k] = $random(seed);
            // called at a negedge: this is cycle 0
            start = 1'b1; we = w; nwords = four; addr = a; be = bmask; wdata = wd[0];
            wcount = 0;
            for (c = 0; c <= L + nw - 1; c = c + 1) begin
                if (c == 1) start = extra_start;               // ignored while busy
                if (c == 2) start = 1'b0;
                if (c == L + nw - 1 && extra_start) start = 1'b1; // in the done cycle: ignored
                if (w && c >= L) wdata = wd[(c - L) & 3];       // the master advances on wready
                #1; checks = checks + 3;
                // expected pulses in cycle c
                if (rvalid !== (!w && c >= L && c < L + nw)) fail("rvalid timing", rvalid, c);
                if (wready !== (w && c >= L && c < L + nw)) fail("wready timing", wready, c);
                if (done !== (c == L + nw - 1)) fail("done timing", done, c);
                if (rvalid) begin
                    checks = checks + 1;
                    if (rdata !== model[(a + c - L) & 1023]) fail("rdata", rdata, model[(a + c - L) & 1023]);
                end
                if (wready) begin
                    for (n = 0; n < 4; n = n + 1)
                        if (four || bmask[n]) model[(a + c - L) & 1023][8*n +: 8] = wd[c - L][8*n +: 8];
                    wcount = wcount + 1;
                end
                @(negedge clk);
            end
            start = 1'b0;                  // the next burst may start right now: the cycle after done
        end
    endtask

    // idle for g cycles, checking that nothing happens
    task idle(input integer g);
        integer j;
        begin
            for (j = 0; j < g; j = j + 1) begin
                #1; checks = checks + 1;
                if (rvalid || wready || done) fail("pulse while idle", {rvalid, wready, done}, 0);
                @(negedge clk);
            end
        end
    endtask

    task check_mem;
        integer j;
        begin
            for (j = 0; j < 1024; j = j + 1) begin
                checks = checks + 1;
                if (bram[j] !== model[j]) fail("memory word", bram[j], model[j]);
            end
        end
    endtask

    integer i, lc, bp, r;
    initial begin
        for (i = 0; i < 1024; i = i + 1) begin bram[i] = i * 32'h01000193 ^ 32'hA5A5A5A5; model[i] = bram[i]; end
        repeat (2) @(posedge clk); #1 rst = 1'b0;
        @(negedge clk);
        for (lc = 0; lc < 4; lc = lc + 1) begin
            lat = lc;
            burst(0, 0, 30'd17, 4'hF, 0);                  // 1-word read
            burst(0, 1, 30'd40, 4'hF, 0);                  // line read
            for (bp = 0; bp < 16; bp = bp + 1)             // 1-word write, every byte-enable pattern
                burst(1, 0, 30'd100 + bp, bp, 0);
            burst(1, 1, 30'd200, 4'h0, 0);                 // line write (be ignored: 1111)
            burst(0, 1, 30'd200, 4'hF, 0);                 // read it back
            // back to back: next start right in the cycle after done; starts while busy ignored
            burst(0, 0, 30'd300, 4'hF, 1);
            burst(1, 0, 30'd301, 4'h5, 1);
            burst(0, 1, 30'd300, 4'hF, 1);
            idle(3);
            check_mem;
        end
        // random bursts, every L
        for (r = 0; r < 2000; r = r + 1) begin
            lat = $random(seed);
            burst($random(seed), $random(seed), $random(seed) & 30'h3FF, $random(seed), $random(seed));
            idle($unsigned($random(seed)) % 4);
        end
        check_mem;
        if (errors == 0 && checks > 50000)
            $display("PASS mem_delay (%0d checks: L = 5, 6, 8, 10, 1/4-word reads and writes, 16 byte-enable patterns, back-to-back, 2000 random bursts)", checks);
        else
            $display("FAIL mem_delay: %0d errors in %0d checks", errors, checks);
        $finish;
    end

endmodule

`default_nettype wire
