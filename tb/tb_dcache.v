`timescale 1ns / 1ps
`default_nettype none
// tb_dcache - one section per step, on dcache + mem_delay + dmem_bram (empty).
// Every access is checked for: the cycle of `ready` (cycle 1 = the cycle `req` rises), the load
// data, and the hit/miss pulse with its owner; memory is checked through the BRAM directly.
//  60 bypass (DC = 0): every access a 1-word burst, ready in 2 + (L + 1), no pulses
//  61 read hit in 2 cycles            62 read miss, clean victim: 2 + (L + 4), lowest invalid way
//  63 write-back, write-allocate      64 dirty victim written back first: 2 + 2(L + 4)
//  66 PLRU replacement
//  67 hit and miss pulses tagged with the owner core
// Each section runs for L = 5, 6, 8 and 10. Prints one PASS/FAIL line.

module tb_dcache;

    reg         clk = 1'b0, rst = 1'b1;
    always #10 clk = ~clk;

    reg         cfg_dc = 1'b1;
    reg  [1:0]  lat = 2'd0;
    reg         req = 1'b0, we = 1'b0, owner = 1'b0;
    reg  [31:0] addr = 32'd0, wdata = 32'd0;
    reg  [3:0]  be = 4'hF;
    wire [31:0] rdata;
    wire        ready, ev_hit, ev_miss, ev_owner;
    wire        m_start, m_we, m_nwords, m_rvalid, m_wready, m_done, b_we;
    wire [29:0] m_addr, b_addr;
    wire [31:0] m_wdata, m_rdata, b_wdata, b_rdata;
    wire [3:0]  m_be, b_be;

    dcache dut (.clk(clk), .rst(rst), .cfg_dc(cfg_dc), .req(req), .we(we), .addr(addr), .wdata(wdata), .be(be),
                .owner(owner), .rdata(rdata), .ready(ready),
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

    integer errors = 0, checks = 0, accesses = 0, seed = 60;
    task fail(input [8*56-1:0] what, input [31:0] got, input [31:0] want);
        begin
            errors = errors + 1;
            if (errors <= 15) $display("%0s: got %08h want %08h (L code %0d, addr %08h, t=%0t)",
                                       what, got, want, lat, addr, $time);
        end
    endtask

    function integer Lv(input [1:0] c); Lv = (c == 0) ? 5 : (c == 1) ? 6 : (c == 2) ? 8 : 10; endfunction

    // kind of access expected: 0 hit, 1 clean miss, 2 dirty miss, 3 single-word burst
    function integer cyc_of(input integer kind);
        cyc_of = (kind == 0) ? 2 : (kind == 1) ? 2 + Lv(lat) + 4 : (kind == 2) ? 2 + 2 * (Lv(lat) + 4)
                                                                  : 2 + Lv(lat) + 1;
    endfunction

    // one access; ev: 0 = expect ev_hit, 1 = ev_miss, 2 = no pulse (DC = 0)
    integer c, nh, nm;
    reg [31:0] got_rdata;
    task acc(input w, input [31:0] a, input [31:0] d, input [3:0] b, input o,
             input integer kind, input integer ev, input [31:0] want);
        begin
            @(negedge clk);
            req = 1'b1; we = w; addr = a; wdata = d; be = b; owner = o;
            c = 1; nh = 0; nm = 0;
            #1;
            while (!ready && c < 200) begin
                if (ev_hit)  begin nh = nh + 1; if (ev_owner !== o) fail("ev_owner", ev_owner, o); end
                if (ev_miss) begin nm = nm + 1; if (ev_owner !== o) fail("ev_owner", ev_owner, o); end
                @(negedge clk); #1; c = c + 1;
            end
            if (ev_hit)  begin nh = nh + 1; if (ev_owner !== o) fail("ev_owner", ev_owner, o); end
            if (ev_miss) begin nm = nm + 1; if (ev_owner !== o) fail("ev_owner", ev_owner, o); end
            got_rdata = rdata;
            accesses = accesses + 1; checks = checks + 3;
            if (c != cyc_of(kind)) fail("ready cycle", c, cyc_of(kind));
            if (!w && got_rdata !== want) fail("load data", got_rdata, want);
            if (ev == 0 && (nh != 1 || nm != 0)) fail("expected one hit pulse", {nh[15:0], nm[15:0]}, 32'h00010000);
            if (ev == 1 && (nh != 0 || nm != 1)) fail("expected one miss pulse", {nh[15:0], nm[15:0]}, 32'h00000001);
            if (ev == 2 && (nh != 0 || nm != 0)) fail("expected no pulse", {nh[15:0], nm[15:0]}, 0);
            @(negedge clk); req = 1'b0;            // the master drops req after ready
            #1; checks = checks + 1;
            if (ready) fail("ready held a second cycle", 1, 0);
        end
    endtask

    function [31:0] memw(input [31:0] a); memw = u_mem.mem[a[16:2]]; endfunction
    task memcheck(input [8*40-1:0] what, input [31:0] a, input [31:0] want);
        begin
            checks = checks + 1;
            if (memw(a) !== want) fail(what, memw(a), want);
        end
    endtask

    task restart(input dc, input [1:0] l);
        integer k;
        begin
            @(negedge clk);
            rst = 1'b1; cfg_dc = dc; lat = l;
            for (k = 0; k < 32768; k = k + 1) u_mem.mem[k] = 32'd0;
            @(negedge clk); @(negedge clk); rst = 1'b0;
        end
    endtask

    // addresses: set s, tag t, word k  (D range 0x1000_0000-0x1001_FFFF)
    function [31:0] A(input integer t, input integer s, input integer k);
        A = 32'h10000000 + t * 32'h400 + s * 16 + k * 4;
    endfunction

    integer lc, t, k, way;
    reg [31:0] v;
    initial begin
        for (lc = 0; lc < 4; lc = lc + 1) begin
            // ---------------------------------------------------------- 60: bypass
            restart(0, lc);
            acc(1, A(0, 3, 1), 32'hCAFEF00D, 4'hF, 0, 3, 2, 0);
            memcheck("60 SW reaches memory", A(0, 3, 1), 32'hCAFEF00D);
            acc(1, A(0, 3, 1), 32'h00AB0000, 4'b0100, 1, 3, 2, 0);       // SB, lane 2
            memcheck("60 SB lane 2", A(0, 3, 1), 32'hCAABF00D);
            acc(1, A(0, 3, 1), 32'h00001234, 4'b0011, 0, 3, 2, 0);       // SH, low half
            memcheck("60 SH low", A(0, 3, 1), 32'hCAAB1234);
            acc(0, A(0, 3, 1), 0, 4'hF, 0, 3, 2, 32'hCAAB1234);
            acc(0, A(0, 3, 1), 0, 4'hF, 1, 3, 2, 32'hCAAB1234);          // again: still a burst
            checks = checks + 1;
            if (dut.valid[3] !== 4'd0) fail("60 arrays touched with DC = 0", dut.valid[3], 0);
            // ---------------------------------------------------------- 61-62: read hit, clean miss
            restart(1, lc);
            for (k = 0; k < 4; k = k + 1) u_mem.mem[A(1, 5, k) >> 2 & 32'h7FFF] = 32'h11110000 + k;
            acc(0, A(1, 5, 2), 0, 4'hF, 0, 1, 1, 32'h11110002);          // clean miss -> way 0
            checks = checks + 1; if (dut.valid[5] !== 4'b0001) fail("62 first fill in way 0", dut.valid[5], 1);
            for (k = 0; k < 4; k = k + 1) acc(0, A(1, 5, k), 0, 4'hF, 0, 0, 0, 32'h11110000 + k);  // hits
            acc(0, A(2, 5, 0), 0, 4'hF, 0, 1, 1, 32'h0);                 // another tag -> way 1
            checks = checks + 1; if (dut.valid[5] !== 4'b0011) fail("62 lowest invalid way next", dut.valid[5], 3);
            acc(0, A(1, 5, 3), 0, 4'hF, 0, 0, 0, 32'h11110003);          // first line still hits
            // ---------------------------------------------------------- 63: write-back, write-allocate
            acc(1, A(1, 5, 1), 32'hAAAA5555, 4'hF, 0, 0, 0, 0);          // store hit: 2 cycles
            checks = checks + 1; if (dut.dirty[5][0] !== 1'b1) fail("63 store hit sets dirty", dut.dirty[5][0], 1);
            memcheck("63 store hit not yet in memory", A(1, 5, 1), 32'h11110001);
            acc(0, A(1, 5, 1), 0, 4'hF, 0, 0, 0, 32'hAAAA5555);
            acc(1, A(3, 5, 2), 32'h0000BB00, 4'b0010, 0, 1, 1, 0);       // store miss: allocate -> way 2
            checks = checks + 1; if (dut.valid[5] !== 4'b0111 || dut.dirty[5][2] !== 1'b1)
                fail("63 store miss allocates, dirty", {dut.valid[5], dut.dirty[5]}, 8'h74);
            acc(0, A(3, 5, 2), 0, 4'hF, 0, 0, 0, 32'h0000BB00);
            memcheck("63 allocated store not in memory", A(3, 5, 2), 32'h0);
            // ---------------------------------------------------------- 64: dirty victim
            acc(1, A(4, 5, 0), 32'h44440000, 4'hF, 0, 1, 1, 0);          // way 3, dirty; set full
            // PLRU now points away from way 3 (last touched): victim is the PLRU's choice; make
            // every way dirty so whichever is chosen is written back first
            acc(1, A(2, 5, 3), 32'h22220003, 4'hF, 0, 0, 0, 0);          // way 1 dirty (hit)
            way = dut.u_plru.victim;
            acc(0, A(5, 5, 0), 0, 4'hF, 0, 2, 1, 32'h0);                 // 5th line: dirty miss
            case (way)
                0: memcheck("64 way 0 written back", A(1, 5, 1), 32'hAAAA5555);
                1: memcheck("64 way 1 written back", A(2, 5, 3), 32'h22220003);
                2: memcheck("64 way 2 written back", A(3, 5, 2), 32'h0000BB00);
                default: memcheck("64 way 3 written back", A(4, 5, 0), 32'h44440000);
            endcase
            // ---------------------------------------------------------- 66: PLRU replacement
            restart(1, lc);
            for (t = 0; t < 4; t = t + 1) acc(0, A(8 + t, 12, 0), 0, 4'hF, 0, 1, 1, 0); // ways 0-3
            acc(0, A(8, 12, 0), 0, 4'hF, 0, 0, 0, 0);                    // touch way 0
            acc(0, A(10, 12, 0), 0, 4'hF, 0, 0, 0, 0);                   // touch way 2
            // bits: way 2 last -> b0 = 0 (left), b1 points away from 0 -> way 1
            acc(0, A(20, 12, 0), 0, 4'hF, 0, 1, 1, 0);
            checks = checks + 1; if (dut.victim_way_reg !== 2'd1) fail("66 PLRU victim", dut.victim_way_reg, 1);
            // ---------------------------------------------------------- 67: owner-tagged pulses
            restart(1, lc);
            acc(0, A(30, 20, 0), 0, 4'hF, 1, 1, 1, 0);                   // core 1 miss
            acc(0, A(30, 20, 1), 0, 4'hF, 0, 0, 0, 0);                   // core 0 hit
            acc(1, A(30, 20, 2), 32'h1, 4'hF, 1, 0, 0, 0);               // core 1 store hit
            acc(1, A(31, 21, 0), 32'h2, 4'hF, 0, 1, 1, 0);               // core 0 store miss
        end
        if (errors == 0 && accesses > 100)
            $display("PASS dcache (%0d checks, %0d accesses: 7 feature sections x L = 5, 6, 8, 10)", checks, accesses);
        else
            $display("FAIL dcache: %0d errors in %0d checks", errors, checks);
        $finish;
    end

endmodule

`default_nettype wire
