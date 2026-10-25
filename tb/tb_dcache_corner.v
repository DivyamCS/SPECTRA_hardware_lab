`timescale 1ns / 1ps
`default_nettype none
// tb_dcache_corner - dcache + mem_delay + dmem_bram (empty), write-back / write-allocate,
// PLRU replacement, L = 5 and 10. The master presents each request in the cycle right after the
// previous ready (no idle cycle), as mem_stage may. Every load is checked against a byte-level
// model of program order; every ready cycle against the expected kind of access.
//  a. five lines into one set: four fills, then evictions, then the evicted line again
//  b. dirty evictions: five stored lines into one set, each later load correct
//  c. a hit right after a miss: load miss then load hit, miss then store hit, dirty miss then hit
//  d. byte and half-word stores on every lane, as hits and as misses (allocate-merge)
// Prints one PASS/FAIL line.

module tb_dcache_corner;

    reg         clk = 1'b0, rst = 1'b1;
    always #10 clk = ~clk;

    reg  [1:0]  lat = 2'd0;
    reg         req = 1'b0, we = 1'b0;
    reg  [31:0] addr = 32'd0, wdata = 32'd0;
    reg  [3:0]  be = 4'hF;
    wire [31:0] rdata;
    wire        ready, ev_hit, ev_miss, ev_owner;
    wire        m_start, m_we, m_nwords, m_rvalid, m_wready, m_done, b_we;
    wire [29:0] m_addr, b_addr;
    wire [31:0] m_wdata, m_rdata, b_wdata, b_rdata;
    wire [3:0]  m_be, b_be;

    dcache dut (.clk(clk), .rst(rst), .cfg_dc(1'b1), .req(req), .we(we), .addr(addr), .wdata(wdata), .be(be),
                .owner(1'b0), .rdata(rdata), .ready(ready),
                .m_start(m_start), .m_we(m_we), .m_addr(m_addr), .m_nwords(m_nwords),
                .m_wdata(m_wdata), .m_be(m_be), .m_rvalid(m_rvalid), .m_rdata(m_rdata),
                .m_wready(m_wready), .m_done(m_done),
                .ev_hit(ev_hit), .ev_miss(ev_miss), .ev_owner(ev_owner));
    mem_delay u_md (.clk(clk), .rst(rst), .lat(lat), .start(m_start), .we(m_we), .addr(m_addr),
                    .nwords(m_nwords), .wdata(m_wdata), .be(m_be), .rvalid(m_rvalid), .rdata(m_rdata),
                    .wready(m_wready), .done(m_done), .m_addr(b_addr), .m_we(b_we), .m_be(b_be),
                    .m_wdata(b_wdata), .m_rdata(b_rdata));
    dmem_bram #(.INIT_FILE("")) u_mem (.clk(clk), .addr(b_addr[14:0]), .we(b_we), .be(b_be),
                                       .wdata(b_wdata), .rdata(b_rdata));

    // program-order byte model of the 128 KB data range
    reg [7:0] model [0:131071];

    integer errors = 0, checks = 0, accesses = 0, i, n;
    integer Lv;
    task fail(input [8*48-1:0] what, input [31:0] got, input [31:0] want);
        begin
            errors = errors + 1;
            if (errors <= 15) $display("%0s: got %08h want %08h (L %0d addr %08h)",
                                       what, got, want, Lv, addr);
        end
    endtask

    // kind: 0 hit, 1 clean miss, 2 dirty miss, 3 single burst, -1 = do not check the cycles
    // (called at a negedge; returns at the negedge after ready, request still up: the next call
    // replaces it in that same cycle)
    integer c, want_c;
    reg [31:0] w;
    task acc(input wr, input [31:0] a, input [31:0] d, input [3:0] b, input integer kind);
        begin
            req = 1'b1; we = wr; addr = a; wdata = d; be = b;
            c = 1; #1;
            while (!ready && c < 300) begin @(negedge clk); #1; c = c + 1; end
            accesses = accesses + 1;
            want_c = (kind == 0) ? 2 : (kind == 1) ? Lv + 6 : (kind == 2) ? 2 * Lv + 10 : Lv + 3;
            if (kind >= 0) begin
                checks = checks + 1;
                if (c != want_c) fail("ready cycle", c, want_c);
            end
            w = {model[{a[16:2], 2'd3}], model[{a[16:2], 2'd2}], model[{a[16:2], 2'd1}], model[{a[16:2], 2'd0}]};
            if (!wr) begin
                checks = checks + 1;
                if (rdata !== w) fail("load data", rdata, w);
            end else begin
                for (n = 0; n < 4; n = n + 1) if (b[n]) model[{a[16:2], n[1:0]}] = d[8*n +: 8];
            end
            @(negedge clk);
        end
    endtask

    task idle;
        begin req = 1'b0; @(negedge clk); end
    endtask

    task restart(input integer lcode);
        integer k;
        begin
            req = 1'b0;
            @(negedge clk);
            rst = 1'b1; lat = lcode;
            Lv = (lcode == 0) ? 5 : (lcode == 1) ? 6 : (lcode == 2) ? 8 : 10;
            for (k = 0; k < 32768; k = k + 1) u_mem.mem[k] = 32'd0;
            for (k = 0; k < 131072; k = k + 1) model[k] = 8'd0;
            @(negedge clk); @(negedge clk); rst = 1'b0;
        end
    endtask

    function [31:0] A(input integer t, input integer s, input integer k);
        A = 32'h10000000 + t * 32'h400 + s * 16 + k * 4;
    endfunction

    integer li, t, lane, st, kind_st;
    initial begin
            for (li = 0; li < 4; li = li + 3) begin            // L code 0 (5) and 3 (10)
                restart(li);
                kind_st = 0;                                    // a store hit: 2 cycles
                // a. five lines into one set (loads; the memory holds known words first)
                for (t = 0; t < 5; t = t + 1) begin
                    u_mem.mem[A(t, 7, 1) >> 2 & 32'h7FFF] = 32'h70000000 + t;
                    for (n = 0; n < 4; n = n + 1) model[(A(t, 7, 1) & 32'h1FFFF) + n] = (32'h70000000 + t) >> (8 * n);
                end
                for (t = 0; t < 4; t = t + 1) acc(0, A(t, 7, 1), 0, 4'hF, 1);    // fills ways 0-3
                for (t = 0; t < 4; t = t + 1) acc(0, A(t, 7, 1), 0, 4'hF, 0);    // all hit
                acc(0, A(4, 7, 1), 0, 4'hF, 1);                                  // 5th: clean eviction
                for (t = 0; t < 5; t = t + 1) acc(0, A(t, 7, 1), 0, 4'hF, -1);   // one of them misses
                // b. dirty evictions (stores into five lines of set 9)
                for (t = 0; t < 5; t = t + 1)
                    acc(1, A(t + 8, 9, 2), 32'h90000000 + t, 4'hF, t < 4 ? 1 : 2);
                for (t = 0; t < 5; t = t + 1) acc(0, A(t + 8, 9, 2), 0, 4'hF, -1);
                // c. a hit right after a miss, in the very next cycle
                acc(0, A(20, 11, 0), 0, 4'hF, 1);
                acc(0, A(20, 11, 3), 0, 4'hF, 0);                                // hit
                acc(0, A(21, 12, 0), 0, 4'hF, 1);
                acc(1, A(21, 12, 1), 32'h12121212, 4'hF, kind_st);               // store hit
                acc(0, A(21, 12, 1), 0, 4'hF, 0);
                // dirty miss, then hit
                for (t = 0; t < 4; t = t + 1) acc(1, A(30 + t, 13, 0), 32'hD0000000 + t, 4'hF, 1);
                acc(0, A(40, 13, 0), 0, 4'hF, 2);
                acc(0, A(40, 13, 2), 0, 4'hF, 0);
                // d. byte and half-word stores on every lane, as hits and as misses
                acc(0, A(50, 20, 0), 0, 4'hF, 1);                                // line present
                for (lane = 0; lane < 4; lane = lane + 1) begin
                    acc(1, A(50, 20, 0) + lane, 32'hA1 << (8 * lane), 4'b0001 << lane, kind_st);
                    acc(0, A(50, 20, 0), 0, 4'hF, 0);
                end
                for (st = 0; st < 2; st = st + 1) begin
                    acc(1, A(50, 20, 1) + 2 * st, 32'hBEEF << (16 * st), st ? 4'b1100 : 4'b0011, kind_st);
                    acc(0, A(50, 20, 1), 0, 4'hF, 0);
                end
                for (lane = 0; lane < 4; lane = lane + 1) begin                  // byte store misses
                    acc(1, A(60 + lane, 21, lane) + lane, 32'h5C << (8 * lane), 4'b0001 << lane, 1);
                    acc(0, A(60 + lane, 21, lane), 0, 4'hF, 0);                  // allocated: a hit
                end
                acc(1, A(70, 22, 3) + 2, 32'h77660000, 4'b1100, 1);               // half store miss
                acc(0, A(70, 22, 3), 0, 4'hF, 0);
                idle;
                // everything once more, after all the evictions above
                for (t = 0; t < 5; t = t + 1) acc(0, A(t, 7, 1), 0, 4'hF, -1);
                for (t = 0; t < 5; t = t + 1) acc(0, A(t + 8, 9, 2), 0, 4'hF, -1);
                for (lane = 0; lane < 4; lane = lane + 1) acc(0, A(60 + lane, 21, lane), 0, 4'hF, -1);
                idle;
            end
        if (errors == 0 && accesses > 100)
            $display("PASS dcache_corner (%0d checks, %0d back-to-back accesses: L 5/10, write-back, PLRU)", checks, accesses);
        else
            $display("FAIL dcache_corner: %0d errors in %0d checks", errors, checks);
        $finish;
    end

endmodule

`default_nettype wire
