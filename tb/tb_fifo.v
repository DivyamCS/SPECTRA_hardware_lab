`timescale 1ns / 1ps

// =============================================================================
// Self-checking testbench for fifo.v  (2-way FIFO replacement policy)
//
// Three DUT instances run in lock-step on the same stimulus:
//   dut64 : NUM_SETS = 64, INDEX_BITS = 6   (main instance, literal checks)
//   dut4  : NUM_SETS = 4,  INDEX_BITS = 2   (parameterisation / aliasing)
//   dut2  : NUM_SETS = 2,  INDEX_BITS = 1   (smallest legal instance)
//
// The reference model is a truth table written from the spec (not a copy of
// the RTL expressions):
//     en = (way_mask == 00) ? 11 : way_mask
//     victim : en==11 -> ptr    en==01 -> 0    en==10 -> 1
//     fill   : en==11 -> ptr <= ~fill_way
//              en==01 -> ptr <= 0           en==10 -> ptr <= 1
//
// Tests
//   T1  reset: power-up, priority over fill, independent of mask, multi-cycle
//   T2  directed walk on one set with literal expected values
//   T3  cold-fill order on every set (strict 0,1,0,1,... alternation)
//   T4  exhaustive transition table: ptr(2) x fill_way(2) x fill-mask(4)
//       x read-mask(4)
//   T5  way_mask invariants (00 == 11, 01 -> way0, 10 -> way1, X-free)
//   T6  set isolation (every index bit, boundary sets, aliasing)
//   T7  idle invariance (fill = 0 never changes state)
//   T8  back-to-back / same-cycle read+fill (no bypass), held fill, etc.
//   T9  combinational response of victim to way_mask / set (no clock)
//   T10 constrained-random regression with random resets and hot sets
//   T11 functional coverage
//
// Run (Vivado xsim):   xvlog fifo.v tb_fifo.v ; xelab tb_fifo -s t ; xsim t -R
// =============================================================================
module tb_fifo;

    localparam CLK_PERIOD = 10;

    // -------------------------------------------------------------------------
    // Stimulus / DUT hook-up
    // -------------------------------------------------------------------------
    reg        clk;
    reg        rst;
    reg  [5:0] set_idx;
    reg  [1:0] way_mask;
    reg        fill;
    reg  [5:0] fill_set;
    reg        fill_way;

    wire       v64, v4, v2;

    fifo #(.NUM_SETS(64), .INDEX_BITS(6)) dut64 (
        .clk(clk), .rst(rst),
        .set(set_idx), .way_mask(way_mask), .victim(v64),
        .fill(fill), .fill_set(fill_set), .fill_way(fill_way)
    );

    fifo #(.NUM_SETS(4), .INDEX_BITS(2)) dut4 (
        .clk(clk), .rst(rst),
        .set(set_idx[1:0]), .way_mask(way_mask), .victim(v4),
        .fill(fill), .fill_set(fill_set[1:0]), .fill_way(fill_way)
    );

    fifo #(.NUM_SETS(2), .INDEX_BITS(1)) dut2 (
        .clk(clk), .rst(rst),
        .set(set_idx[0]), .way_mask(way_mask), .victim(v2),
        .fill(fill), .fill_set(fill_set[0]), .fill_way(fill_way)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // -------------------------------------------------------------------------
    // Reference model (truth-table based)
    // -------------------------------------------------------------------------
    reg mp64 [0:63];
    reg mp4  [0:3];
    reg mp2  [0:1];

    function exp_vic;
        input p;
        input [1:0] m;
        begin
            case (m)
                2'b01:   exp_vic = 1'b0;   // only way 0 enabled
                2'b10:   exp_vic = 1'b1;   // only way 1 enabled
                default: exp_vic = p;      // 11, and 00 (falls back to 11)
            endcase
        end
    endfunction

    function exp_nxt;
        input fw;
        input [1:0] m;
        begin
            case (m)
                2'b01:   exp_nxt = 1'b0;
                2'b10:   exp_nxt = 1'b1;
                default: exp_nxt = ~fw;    // 11 and 00
            endcase
        end
    endfunction

    // coverage
    reg [15:0] cov_fill;   // {mask, fill_way, ptr_before}
    reg [7:0]  cov_vic;    // {mask, victim}

    integer mi;
    initial begin
        for (mi = 0; mi < 64; mi = mi + 1) mp64[mi] = 1'b0;
        for (mi = 0; mi < 4;  mi = mi + 1) mp4[mi]  = 1'b0;
        for (mi = 0; mi < 2;  mi = mi + 1) mp2[mi]  = 1'b0;
        cov_fill = 16'd0;
        cov_vic  = 8'd0;
    end

    // Model update: inputs only change at negedge, so no race with the DUT.
    always @(posedge clk) begin
        if (rst) begin
            for (mi = 0; mi < 64; mi = mi + 1) mp64[mi] = 1'b0;
            for (mi = 0; mi < 4;  mi = mi + 1) mp4[mi]  = 1'b0;
            for (mi = 0; mi < 2;  mi = mi + 1) mp2[mi]  = 1'b0;
        end else if (fill) begin
            cov_fill[{way_mask, fill_way, mp64[fill_set]}] = 1'b1;
            mp64[fill_set]     = exp_nxt(fill_way, way_mask);
            mp4[fill_set[1:0]] = exp_nxt(fill_way, way_mask);
            mp2[fill_set[0]]   = exp_nxt(fill_way, way_mask);
        end
    end

    // -------------------------------------------------------------------------
    // Checking helpers
    // -------------------------------------------------------------------------
    integer test_errors;
    integer checks;
    reg     chk_en;
    integer seed;

    task bad;
        input [8*32:1] tag;
        input [8*24:1] what;
        input [31:0]   a;
        begin
            test_errors = test_errors + 1;
            if (test_errors <= 25)
                $display("[ERROR] %0s | %0s | %0d | set %0d mask %b | t=%0t",
                         tag, what, a, set_idx, way_mask, $time);
        end
    endtask

    // Compare all three DUTs against the model for the currently driven
    // set_idx / way_mask.
    task chk;
        input [8*32:1] tag;
        reg e64, e4, e2;
        begin
            if (chk_en) begin
                e64 = exp_vic(mp64[set_idx],       way_mask);
                e4  = exp_vic(mp4[set_idx[1:0]],   way_mask);
                e2  = exp_vic(mp2[set_idx[0]],     way_mask);
                checks = checks + 1;
                if ((v64 !== 1'b0 && v64 !== 1'b1) ||
                    (v4  !== 1'b0 && v4  !== 1'b1) ||
                    (v2  !== 1'b0 && v2  !== 1'b1))
                    bad(tag, "X/Z on victim", 0);
                else if (v64 !== e64) bad(tag, "dut64 mismatch (exp)", e64);
                else if (v4  !== e4)  bad(tag, "dut4 mismatch (exp)",  e4);
                else if (v2  !== e2)  bad(tag, "dut2 mismatch (exp)",  e2);
                if (v64 === 1'b0 || v64 === 1'b1)
                    cov_vic[{way_mask, v64}] = 1'b1;
            end
        end
    endtask

    // One clock cycle: drive at negedge, check combinational read before the
    // edge (old state) and again after the edge (updated state).
    task cycle;
        input        r;
        input        f;
        input [5:0]  fs;
        input        fw;
        input [5:0]  rs;
        input [1:0]  m;
        begin
            @(negedge clk);
            rst = r; fill = f; fill_set = fs; fill_way = fw;
            set_idx = rs; way_mask = m;
            #1 chk("pre-edge (comb read)");
            @(posedge clk);
            #1 chk("post-edge (update)");
        end
    endtask

    // Normal fill with full mask, reading the same set
    task fillc;
        input [5:0] s;
        input       w;
        begin
            cycle(1'b0, 1'b1, s, w, s, 2'b11);
        end
    endtask

    task do_reset;
        input integer len;
        integer rr;
        begin
            for (rr = 0; rr < len; rr = rr + 1)
                cycle(1'b1, 1'b0, 6'd0, 1'b0, 6'd0, 2'b11);
        end
    endtask

    // Read only (no fill) and compare with model
    task rd;
        input [5:0]    s;
        input [1:0]    m;
        input [8*32:1] tag;
        begin
            @(negedge clk);
            rst = 1'b0; fill = 1'b0; set_idx = s; way_mask = m;
            #1 chk(tag);
        end
    endtask

    // Read only, also compare dut64 with a literal expected value
    task expect_v;
        input [5:0]    s;
        input [1:0]    m;
        input          e;
        input [8*32:1] tag;
        begin
            @(negedge clk);
            rst = 1'b0; fill = 1'b0; set_idx = s; way_mask = m;
            #1 chk(tag);
            checks = checks + 1;
            if (v64 !== e) bad(tag, "literal mismatch (exp)", e);
        end
    endtask

    // Literal check without waiting for a clock edge (inputs already driven)
    task lit;
        input          e;
        input [8*32:1] tag;
        begin
            #1 chk(tag);
            checks = checks + 1;
            if (v64 !== e) bad(tag, "literal mismatch (exp)", e);
        end
    endtask

    // Scan every set for one mask value
    task scan_sets;
        input [1:0]    m;
        input [8*32:1] tag;
        integer ss;
        begin
            @(negedge clk);
            rst = 1'b0; fill = 1'b0; way_mask = m;
            for (ss = 0; ss < 64; ss = ss + 1) begin
                set_idx = ss;
                #1 chk(tag);
            end
        end
    endtask

    // Scan every set for every mask value
    task scan_all;
        input [8*32:1] tag;
        integer mm;
        begin
            for (mm = 0; mm < 4; mm = mm + 1) scan_sets(mm[1:0], tag);
        end
    endtask

    // Model-independent mask invariants on every set (uses DUT outputs only)
    task inv_scan;
        input [8*32:1] tag;
        integer ss;
        reg a00, a11, a01, a10;
        begin
            @(negedge clk);
            rst = 1'b0; fill = 1'b0;
            for (ss = 0; ss < 64; ss = ss + 1) begin
                set_idx = ss;
                way_mask = 2'b00; #1 chk(tag); a00 = v64;
                way_mask = 2'b11; #1 chk(tag); a11 = v64;
                way_mask = 2'b01; #1 chk(tag); a01 = v64;
                way_mask = 2'b10; #1 chk(tag); a10 = v64;
                checks = checks + 4;
                if (a00 !== a11)  bad(tag, "mask 00 != mask 11", ss);
                if (a01 !== 1'b0) bad(tag, "mask 01 must pick way0", ss);
                if (a10 !== 1'b1) bad(tag, "mask 10 must pick way1", ss);
            end
        end
    endtask

    // Only set `s` may have changed after one fill of way `w` from reset:
    // with full mask, ptr <= ~w, so only (w == 0) makes victim 1 on that set.
    task iso_check;
        input [5:0]    s;
        input          w;
        input [8*32:1] tag;
        integer ss;
        reg e;
        begin
            @(negedge clk);
            rst = 1'b0; fill = 1'b0; way_mask = 2'b11;
            for (ss = 0; ss < 64; ss = ss + 1) begin
                set_idx = ss;
                #1 chk(tag);
                e = (ss == s) && (w == 1'b0);
                checks = checks + 1;
                if (v64 !== e) bad(tag, "isolation violated (exp)", e);
            end
        end
    endtask

    // Snapshot / compare of all victims (mask 11)
    reg snap [0:63];
    task take_snap;
        integer ss;
        begin
            @(negedge clk);
            rst = 1'b0; fill = 1'b0; way_mask = 2'b11;
            for (ss = 0; ss < 64; ss = ss + 1) begin
                set_idx = ss; #1 snap[ss] = v64;
            end
        end
    endtask

    task cmp_snap;
        input [8*32:1] tag;
        integer ss;
        begin
            @(negedge clk);
            rst = 1'b0; fill = 1'b0; way_mask = 2'b11;
            for (ss = 0; ss < 64; ss = ss + 1) begin
                set_idx = ss; #1 chk(tag);
                checks = checks + 1;
                if (v64 !== snap[ss]) bad(tag, "state changed while idle", ss);
            end
        end
    endtask

    function [31:0] rnd;
        input integer dummy;
        begin
            rnd = $random(seed);
        end
    endfunction

    function integer count_ones;
        input [31:0] v;
        integer c, k;
        begin
            c = 0;
            for (k = 0; k < 32; k = k + 1) c = c + v[k];
            count_ones = c;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Main sequence
    // -------------------------------------------------------------------------
    integer i, j, n, bb, rounds;
    integer tp, tfw, tmf, tmr;
    reg [5:0]  sa, rs, fs;
    reg [1:0]  mk;
    reg [31:0] r32, r2;

    initial begin
        rst = 1'b1; fill = 1'b0; fill_set = 6'd0; fill_way = 1'b0;
        set_idx = 6'd0; way_mask = 2'b11;
        test_errors = 0; checks = 0; chk_en = 1'b0; seed = 32'h0f1f0abc;

        repeat (2) @(posedge clk);
        #1 chk_en = 1'b1;

        // ---------------------------------------------------------------- T1
        $display("\nT1: reset behaviour");
        scan_all("T1 after power-up reset");
        for (i = 0; i < 64; i = i + 1) expect_v(i, 2'b11, 1'b0, "T1 victim 0 after reset");
        for (i = 0; i < 64; i = i + 1) expect_v(i, 2'b10, 1'b1, "T1 mask10 -> way1 after reset");

        for (i = 0; i < 64; i = i + 1) fillc(i, 1'b0);            // ptr -> 1 everywhere
        scan_all("T1 after dirtying all sets");
        expect_v(6'd20, 2'b11, 1'b1, "T1 dirty literal");

        cycle(1'b1, 1'b1, 6'd17, 1'b0, 6'd17, 2'b11);            // reset + fill together
        scan_all("T1 reset priority over fill");
        expect_v(6'd17, 2'b11, 1'b0, "T1 reset wins over fill");

        for (j = 0; j < 4; j = j + 1) begin                       // reset ignores mask
            for (i = 0; i < 64; i = i + 1) fillc(i, 1'b0);
            cycle(1'b1, 1'b0, 6'd0, 1'b0, 6'd0, j[1:0]);
            scan_all("T1 reset with mask");
        end

        for (i = 0; i < 100; i = i + 1) begin
            r32 = rnd(0);
            cycle(1'b0, 1'b1, r32[5:0], r32[6], r32[13:8], 2'b11);
        end
        for (i = 0; i < 6; i = i + 1) begin                       // multi-cycle reset + noise
            r32 = rnd(0);
            cycle(1'b1, r32[8], r32[5:0], r32[6], r32[14:9], r32[17:16]);
        end
        scan_all("T1 after multi-cycle reset");

        // ---------------------------------------------------------------- T2
        $display("T2: directed walk on set 5 (literals)");
        do_reset(1);
        expect_v(6'd5, 2'b11, 1'b0, "T2 initial");
        fillc(6'd5, 1'b0);  expect_v(6'd5, 2'b11, 1'b1, "T2 after fill w0");
        fillc(6'd5, 1'b1);  expect_v(6'd5, 2'b11, 1'b0, "T2 after fill w1");
        fillc(6'd5, 1'b1);  expect_v(6'd5, 2'b11, 1'b0, "T2 fill w1 again");
        fillc(6'd5, 1'b0);  expect_v(6'd5, 2'b11, 1'b1, "T2 fill w0");
        fillc(6'd5, 1'b0);  expect_v(6'd5, 2'b11, 1'b1, "T2 fill w0 again");
        fillc(6'd5, 1'b1);  expect_v(6'd5, 2'b11, 1'b0, "T2 fill w1");
        expect_v(6'd4,  2'b11, 1'b0, "T2 neighbour set 4 untouched");
        expect_v(6'd6,  2'b11, 1'b0, "T2 neighbour set 6 untouched");
        expect_v(6'd37, 2'b11, 1'b0, "T2 set 37 untouched");

        // ---------------------------------------------------------------- T3
        $display("T3: cold-fill order on every set");
        do_reset(1);
        for (i = 0; i < 64; i = i + 1)
            for (j = 0; j < 8; j = j + 1) begin
                expect_v(i, 2'b11, j % 2, "T3 strict alternation");
                fillc(i, j % 2);                                  // fill the victim
            end
        scan_all("T3 end");

        // ---------------------------------------------------------------- T4
        $display("T4: exhaustive transitions (ptr x fill_way x fill_mask x read_mask)");
        for (tp = 0; tp < 2; tp = tp + 1)
            for (tfw = 0; tfw < 2; tfw = tfw + 1)
                for (tmf = 0; tmf < 4; tmf = tmf + 1) begin
                    do_reset(1);
                    if (tp == 1) cycle(1'b0, 1'b1, 6'd7, 1'b0, 6'd7, 2'b11);   // ptr = 1
                    cycle(1'b0, 1'b1, 6'd7, tfw[0], 6'd7, tmf[1:0]);
                    for (tmr = 0; tmr < 4; tmr = tmr + 1)
                        rd(6'd7, tmr[1:0], "T4 transition table");
                    scan_all("T4 other sets unaffected");
                end

        // ---------------------------------------------------------------- T5
        $display("T5: way_mask invariants");
        do_reset(1);
        inv_scan("T5 after reset");
        for (rounds = 0; rounds < 4; rounds = rounds + 1) begin
            for (i = 0; i < 2000; i = i + 1) begin
                r32 = rnd(0);
                cycle(1'b0, 1'b1, r32[5:0], r32[6], r32[13:8], r32[17:16]);
            end
            inv_scan("T5 after random fills");
        end

        // ---------------------------------------------------------------- T6
        $display("T6: set isolation (index bits, boundaries)");
        for (bb = 0; bb < 8; bb = bb + 1) begin
            case (bb)
                6:       sa = 6'd0;
                7:       sa = 6'd63;
                default: sa = 6'd1 << bb;
            endcase
            for (j = 0; j < 2; j = j + 1) begin
                do_reset(1);
                fillc(sa, j[0]);
                iso_check(sa, j[0], "T6 only one set may change");
            end
        end

        // ---------------------------------------------------------------- T7
        $display("T7: idle invariance (fill = 0)");
        do_reset(1);
        for (i = 0; i < 100; i = i + 1) begin
            r32 = rnd(0);
            cycle(1'b0, 1'b1, r32[5:0], r32[6], r32[13:8], 2'b11);
        end
        take_snap;
        for (i = 0; i < 300; i = i + 1) begin
            r32 = rnd(0);
            cycle(1'b0, 1'b0, r32[5:0], r32[6], r32[13:8], r32[17:16]);
        end
        cmp_snap("T7 after idle wiggle");

        // ---------------------------------------------------------------- T8
        $display("T8: back-to-back / same-cycle read+fill");
        do_reset(1);
        // fill and read the same set in the same cycle: read must see OLD state
        @(negedge clk);
        rst = 1'b0; fill = 1'b1; fill_set = 6'd9; fill_way = 1'b0;
        set_idx = 6'd9; way_mask = 2'b11;
        lit(1'b0, "T8 pre-edge sees old ptr");
        @(posedge clk);
        #1;
        lit(1'b1, "T8 post-edge sees new ptr");

        // fill set A, read set B in the same cycle
        do_reset(1);
        cycle(1'b0, 1'b1, 6'd10, 1'b0, 6'd11, 2'b11);
        expect_v(6'd10, 2'b11, 1'b1, "T8 filled set changed");
        expect_v(6'd11, 2'b11, 1'b0, "T8 other set unchanged");

        // fill held high, same way, many cycles
        do_reset(1);
        for (i = 0; i < 10; i = i + 1) cycle(1'b0, 1'b1, 6'd9, 1'b1, 6'd9, 2'b11);
        expect_v(6'd9, 2'b11, 1'b0, "T8 held fill way1 -> victim 0");
        for (i = 0; i < 10; i = i + 1) cycle(1'b0, 1'b1, 6'd9, 1'b0, 6'd9, 2'b11);
        expect_v(6'd9, 2'b11, 1'b1, "T8 held fill way0 -> victim 1");

        // fill every cycle with toggling way, same set
        for (i = 0; i < 16; i = i + 1) cycle(1'b0, 1'b1, 6'd3, i % 2, 6'd3, 2'b11);
        scan_all("T8 toggling way");
        // alternating sets every cycle
        for (i = 0; i < 40; i = i + 1)
            cycle(1'b0, 1'b1, (i % 2) ? 6'd4 : 6'd3, (i / 2) % 2, (i % 2) ? 6'd3 : 6'd4, 2'b11);
        scan_all("T8 alternating sets");
        // random burst, fill every cycle
        for (i = 0; i < 400; i = i + 1) begin
            r32 = rnd(0);
            cycle(1'b0, 1'b1, r32[5:0], r32[6], r32[13:8], r32[17:16]);
        end
        scan_all("T8 random burst");

        // ---------------------------------------------------------------- T9
        $display("T9: combinational response (no clock edge)");
        do_reset(1);
        fillc(6'd12, 1'b0);                       // ptr[12] = 1
        @(negedge clk);
        rst = 1'b0; fill = 1'b0; set_idx = 6'd12;
        way_mask = 2'b11; lit(1'b1, "T9 mask 11");
        way_mask = 2'b01; lit(1'b0, "T9 mask 01");
        way_mask = 2'b10; lit(1'b1, "T9 mask 10");
        way_mask = 2'b00; lit(1'b1, "T9 mask 00 == 11");
        way_mask = 2'b01; lit(1'b0, "T9 mask 01 again");
        way_mask = 2'b11;
        set_idx = 6'd13;  lit(1'b0, "T9 set change, same cycle");
        set_idx = 6'd12;  lit(1'b1, "T9 set change back");

        // --------------------------------------------------------------- T10
        $display("T10: random regression (random resets, hot sets, random masks)");
        for (n = 0; n < 60000; n = n + 1) begin
            r32 = rnd(0);
            r2  = rnd(0);
            case (r32[1:0])                                  // read set
                2'd0:    rs = {4'b0000, r32[3:2]};
                2'd1:    rs = 6'd63;
                default: rs = r32[9:4];
            endcase
            case (r2[1:0])                                   // fill set
                2'd0:    fs = {4'b0000, r2[3:2]};
                2'd1:    fs = 6'd63;
                2'd2:    fs = rs;                            // same-set read/fill
                default: fs = r2[9:4];
            endcase
            case (r32[12:10])                                // mask (11 favoured)
                3'd0:    mk = 2'b00;
                3'd1:    mk = 2'b01;
                3'd2:    mk = 2'b10;
                default: mk = 2'b11;
            endcase
            cycle((r32[31:23] == 9'd0),                      // reset ~1/512
                  (r32[20] | r32[21]),                       // fill 3/4
                  fs, r32[22], rs, mk);
            if (n % 2500 == 2499) scan_all("T10 periodic full scan");
        end
        scan_all("T10 end");

        // --------------------------------------------------------------- T11
        $display("T11: functional coverage");
        $display("  fill (mask,way,ptr) combos covered : %0d / 16", count_ones({16'd0, cov_fill}));
        $display("  victim (mask,way) combos covered   : %0d / 6", count_ones({24'd0, cov_vic}));
        if (cov_fill !== 16'hFFFF) begin
            test_errors = test_errors + 1;
            $display("[ERROR] fill coverage hole, map = %b", cov_fill);
        end
        // legal bins: {00,0} {00,1} {01,0} {10,1} {11,0} {11,1}; illegal bins stay 0
        if (cov_vic !== 8'b1110_0111) begin
            test_errors = test_errors + 1;
            $display("[ERROR] victim coverage mismatch, map = %b (expected 11100111)", cov_vic);
        end

        // ---------------------------------------------------------------------
        $display("\n========================================================");
        $display("checks performed : %0d", checks);
        if (test_errors == 0) begin
            $display(">>> ALL FIFO TESTS PASSED <<<");
            $display("PASS fifo (%0d checks)", checks);
        end else begin
            $display(">>> FAILED: %0d error(s) <<<", test_errors);
            $display("FAIL fifo: %0d error(s)", test_errors);
        end
        $display("========================================================\n");
        $finish;
    end

    // watchdog
    initial begin
        #(CLK_PERIOD * 2000000);
        $display("[ERROR] TIMEOUT");
        $finish;
    end

endmodule