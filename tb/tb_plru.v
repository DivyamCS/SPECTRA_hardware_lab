`timescale 1ns / 1ps

// =============================================================================
// Self-checking testbench for plru.v (4-way tree-PLRU, 3 bits per set)
// Updated for Decoupled Ports and way_mask testing.
// =============================================================================
module tb2_plru;

    localparam NUM_SETS   = 64;
    localparam INDEX_BITS = 6;
    localparam CLK_PERIOD = 10;

    reg                  clk;
    reg                  rst;
    reg [INDEX_BITS-1:0] set_idx;
    reg                  access_valid;
    reg [1:0]            access_way;
    reg [3:0]            test_mask;        // Added for masking tests
    wire [1:0]           victim_way;
    wire [1:0]           victim_way_s;     // small (4-set) instance

    // -------------------------------------------------------------------------
    // DUT Instantiations (Mapped to Decoupled Ports)
    // -------------------------------------------------------------------------
    plru #(.NUM_SETS(NUM_SETS), .INDEX_BITS(INDEX_BITS)) dut (
        .clk      (clk), 
        .rst      (rst), 
        .set      (set_idx),             // Decoupled Read
        .way_mask (test_mask), 
        .victim   (victim_way),
        .upd      (access_valid),        // Decoupled Write
        .upd_set  (set_idx), 
        .upd_way  (access_way)
    );

    plru #(.NUM_SETS(4), .INDEX_BITS(2)) dut_small (
        .clk      (clk), 
        .rst      (rst), 
        .set      (set_idx[1:0]), 
        .way_mask (test_mask), 
        .victim   (victim_way_s),
        .upd      (access_valid), 
        .upd_set  (set_idx[1:0]), 
        .upd_way  (access_way)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // -------------------------------------------------------------------------
    // Reference model: explicit truth tables.  State = {b2, b1, b0}
    // -------------------------------------------------------------------------
    function [1:0] vic;
        input [2:0] s;
        begin
            case (s)
                3'd0: vic = 2'd0; 3'd1: vic = 2'd2;
                3'd2: vic = 2'd1; 3'd3: vic = 2'd2;
                3'd4: vic = 2'd0; 3'd5: vic = 2'd3;
                3'd6: vic = 2'd1; 3'd7: vic = 2'd3;
            endcase
        end
    endfunction

    function [2:0] nxt;
        input [2:0] s; input [1:0] w;
        begin
            case ({s, w})
                {3'd0, 2'd0}: nxt = 3'd3;  {3'd0, 2'd1}: nxt = 3'd1;
                {3'd0, 2'd2}: nxt = 3'd4;  {3'd0, 2'd3}: nxt = 3'd0;
                {3'd1, 2'd0}: nxt = 3'd3;  {3'd1, 2'd1}: nxt = 3'd1;
                {3'd1, 2'd2}: nxt = 3'd4;  {3'd1, 2'd3}: nxt = 3'd0;
                {3'd2, 2'd0}: nxt = 3'd3;  {3'd2, 2'd1}: nxt = 3'd1;
                {3'd2, 2'd2}: nxt = 3'd6;  {3'd2, 2'd3}: nxt = 3'd2;
                {3'd3, 2'd0}: nxt = 3'd3;  {3'd3, 2'd1}: nxt = 3'd1;
                {3'd3, 2'd2}: nxt = 3'd6;  {3'd3, 2'd3}: nxt = 3'd2;
                {3'd4, 2'd0}: nxt = 3'd7;  {3'd4, 2'd1}: nxt = 3'd5;
                {3'd4, 2'd2}: nxt = 3'd4;  {3'd4, 2'd3}: nxt = 3'd0;
                {3'd5, 2'd0}: nxt = 3'd7;  {3'd5, 2'd1}: nxt = 3'd5;
                {3'd5, 2'd2}: nxt = 3'd4;  {3'd5, 2'd3}: nxt = 3'd0;
                {3'd6, 2'd0}: nxt = 3'd7;  {3'd6, 2'd1}: nxt = 3'd5;
                {3'd6, 2'd2}: nxt = 3'd6;  {3'd6, 2'd3}: nxt = 3'd2;
                {3'd7, 2'd0}: nxt = 3'd7;  {3'd7, 2'd1}: nxt = 3'd5;
                {3'd7, 2'd2}: nxt = 3'd6;  {3'd7, 2'd3}: nxt = 3'd2;
            endcase
        end
    endfunction

    reg [2:0]  m  [0:NUM_SETS-1];   
    reg [2:0]  ms [0:3];            
    reg [31:0] cov;                 
    integer    mi;

    initial begin
        for (mi = 0; mi < NUM_SETS; mi = mi + 1) m[mi] = 3'd0;
        for (mi = 0; mi < 4;        mi = mi + 1) ms[mi] = 3'd0;
        cov = 32'd0;
        test_mask = 4'b1111;
    end

    always @(posedge clk) begin
        if (rst) begin
            for (mi = 0; mi < NUM_SETS; mi = mi + 1) m[mi] = 3'd0;
            for (mi = 0; mi < 4;        mi = mi + 1) ms[mi] = 3'd0;
        end else if (access_valid) begin
            cov[{m[set_idx], access_way}] = 1'b1;
            m[set_idx]        = nxt(m[set_idx],        access_way);
            ms[set_idx[1:0]]  = nxt(ms[set_idx[1:0]],  access_way);
        end
    end

    // -------------------------------------------------------------------------
    // Checking helpers
    // -------------------------------------------------------------------------
    integer test_errors;
    integer checks;
    reg     chk_en;
    integer seed;

    task chk;
        input [8*32:1] tag;
        reg [1:0] exp_b, exp_s;
        begin
            if (chk_en) begin
                exp_b = vic(m[set_idx]);
                exp_s = vic(ms[set_idx[1:0]]);
                checks = checks + 1;
                if ((^victim_way === 1'bx) || (^victim_way_s === 1'bx)) begin
                    test_errors = test_errors + 1;
                    if (test_errors <= 25)
                        $display("[ERROR] %0s | X/Z on victim_way | set %0d | t=%0t", tag, set_idx, $time);
                end else if (victim_way !== exp_b) begin
                    test_errors = test_errors + 1;
                    if (test_errors <= 25)
                        $display("[ERROR] %0s | set %0d | expected victim %0d, got %0d | t=%0t", tag, set_idx, exp_b, victim_way, $time);
                end else if (victim_way_s !== exp_s) begin
                    test_errors = test_errors + 1;
                    if (test_errors <= 25)
                        $display("[ERROR] %0s (4-set instance) | set %0d | expected %0d, got %0d | t=%0t", tag, set_idx[1:0], exp_s, victim_way_s, $time);
                end
            end
        end
    endtask

    task expect_const;
        input [INDEX_BITS-1:0] s;
        input [1:0]            e;
        input [8*32:1]         tag;
        begin
            @(negedge clk);
            rst = 0; access_valid = 0; set_idx = s;
            #1;
            checks = checks + 1;
            if (victim_way !== e) begin
                test_errors = test_errors + 1;
                if (test_errors <= 25)
                    $display("[ERROR] %0s | set %0d | expected victim %0d, got %0d | t=%0t", tag, s, e, victim_way, $time);
            end
        end
    endtask

    task cycle;
        input                  r;
        input                  v;
        input [INDEX_BITS-1:0] s;
        input [1:0]            w;
        begin
            @(negedge clk);
            rst = r; access_valid = v; set_idx = s; access_way = w;
            #1 chk("pre-edge (comb read)");
            @(posedge clk);
            #1 chk("post-edge (update)");
        end
    endtask

    task scan_all;
        input [8*32:1] tag;
        integer ss;
        begin
            @(negedge clk);
            rst = 0; access_valid = 0;
            for (ss = 0; ss < NUM_SETS; ss = ss + 1) begin
                set_idx = ss;
                #1 chk(tag);
            end
        end
    endtask

    task do_reset;
        input integer len;
        integer rr;
        begin
            for (rr = 0; rr < len; rr = rr + 1) cycle(1'b1, 1'b0, 6'd0, 2'd0);
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
    integer i, j, k, b, n, batch, sq, d, round;
    reg [1:0]  vv, pat;
    reg [3:0]  seen;
    reg [31:0] r32;
    reg [INDEX_BITS-1:0] sa, sb;

    initial begin
        clk = 0; rst = 1; set_idx = 0; access_valid = 0; access_way = 0;
        test_errors = 0; checks = 0; chk_en = 0; seed = 32'h1badb002;

        repeat (2) @(posedge clk);
        #1 chk_en = 1;

        // T1: reset behaviour
        $display("\nT1: reset behaviour");
        scan_all("T1 after power-up reset");
        for (i = 0; i < NUM_SETS; i = i + 1)
            for (j = 0; j < 4; j = j + 1)
                cycle(1'b0, 1'b1, i, j);
        scan_all("T1 after dirtying all sets");
        cycle(1'b1, 1'b1, 6'd17, 2'd3);
        scan_all("T1 reset priority over access");
        for (i = 0; i < NUM_SETS; i = i + 1) begin
            set_idx = i; #1;
            if (victim_way !== 2'd0) begin
                test_errors = test_errors + 1;
                $display("[ERROR] T1 set %0d not way 0 after reset", i);
            end
        end
        for (i = 0; i < 500; i = i + 1) begin
            r32 = rnd(0);
            cycle(1'b0, 1'b1, r32[5:0], r32[7:6]);
        end
        for (i = 0; i < 6; i = i + 1) begin
            r32 = rnd(0);
            cycle(1'b1, r32[8], r32[5:0], r32[7:6]);   
        end
        scan_all("T1 after multi-cycle reset");

        // T2: directed walk on set 5 (constants)
        $display("T2: directed walk on set 5 (constants)");
        expect_const(6'd5, 2'd0, "T2 initial");
        cycle(1'b0, 1'b1, 6'd5, 2'd0);   expect_const(6'd5, 2'd2, "T2 after way 0");
        cycle(1'b0, 1'b1, 6'd5, 2'd2);   expect_const(6'd5, 2'd1, "T2 after way 2");
        cycle(1'b0, 1'b1, 6'd5, 2'd1);   expect_const(6'd5, 2'd3, "T2 after way 1");
        cycle(1'b0, 1'b1, 6'd5, 2'd3);   expect_const(6'd5, 2'd0, "T2 after way 3");
        cycle(1'b0, 1'b1, 6'd5, 2'd0);
        cycle(1'b0, 1'b1, 6'd5, 2'd1);
        cycle(1'b0, 1'b1, 6'd5, 2'd2);   expect_const(6'd5, 2'd0, "T2 after hits 0,1,2");
        cycle(1'b0, 1'b1, 6'd5, 2'd2);   expect_const(6'd5, 2'd0, "T2 repeat way 2");
        cycle(1'b0, 1'b1, 6'd5, 2'd0);   expect_const(6'd5, 2'd3, "T2 after way 0 again");

        // T3: cold-fill order on every set
        $display("T3: cold-fill order on every set");
        do_reset(1);
        for (i = 0; i < NUM_SETS; i = i + 1) begin
            seen = 4'b0000;
            for (k = 0; k < 12; k = k + 1) begin           
                case (k % 4)
                    0: pat = 2'd0; 1: pat = 2'd2;
                    2: pat = 2'd1; default: pat = 2'd3;
                endcase
                @(negedge clk); rst = 0; access_valid = 0; set_idx = i; #1;
                vv = victim_way;
                checks = checks + 1;
                if (vv !== pat) begin
                    test_errors = test_errors + 1;
                    if (test_errors <= 25) $display("[ERROR] T3 set %0d step %0d: expected %0d got %0d", i, k, pat, vv);
                end
                if (k % 4 == 0) seen = 4'b0000;
                if (seen[vv]) begin
                    test_errors = test_errors + 1;
                    $display("[ERROR] T3 set %0d: way %0d chosen twice in one round", i, vv);
                end
                seen[vv] = 1'b1;
                cycle(1'b0, 1'b1, i, vv);                   
            end
        end
        scan_all("T3 end");

        // T4: exhaustive access sequences (4^5 = 1024) from reset
        $display("T4: exhaustive access sequences (4^5 = 1024) from reset");
        for (batch = 0; batch < 16; batch = batch + 1) begin
            do_reset(1);
            for (i = 0; i < NUM_SETS; i = i + 1) begin
                sq = batch * 64 + i;
                for (d = 0; d < 5; d = d + 1)
                    cycle(1'b0, 1'b1, i, (sq >> (2 * d)) & 3);
            end
            scan_all("T4 batch end");
        end

        // T5: invariants (accessed way never next victim, opposite half)
        $display("T5: invariants (accessed way never next victim, opposite half)");
        for (round = 0; round < 3; round = round + 1)
            for (i = 0; i < NUM_SETS; i = i + 1)
                for (j = 0; j < 4; j = j + 1) begin
                    r32 = rnd(0);
                    cycle(1'b0, 1'b1, i, r32[1:0]);            
                    cycle(1'b0, 1'b1, i, r32[3:2]);
                    cycle(1'b0, 1'b1, i, j);                   
                    checks = checks + 1;
                    if (victim_way === j[1:0]) begin
                        test_errors = test_errors + 1;
                        if (test_errors <= 25) $display("[ERROR] T5 set %0d: just-accessed way %0d chosen as victim", i, j);
                    end
                    if (victim_way[1] === j[1]) begin
                        test_errors = test_errors + 1;
                        if (test_errors <= 25) $display("[ERROR] T5 set %0d: victim %0d in same half as accessed way %0d", i, victim_way, j);
                    end
                end

        // T6: set isolation
        $display("T6: set isolation (every index bit, boundary sets)");
        for (b = 0; b < 8; b = b + 1) begin
            case (b)
                6: sa = 6'd0; 7: sa = 6'd63; default: sa = 6'd1 << b;
            endcase
            for (j = 0; j < 4; j = j + 1) begin
                do_reset(1);
                cycle(1'b0, 1'b1, sa, j);
                scan_all("T6 only one set may change");
            end
        end

        // T7: idle invariance
        $display("T7: idle invariance (access_valid = 0, other inputs wiggle)");
        for (i = 0; i < 100; i = i + 1) begin
            r32 = rnd(0);
            cycle(1'b0, 1'b1, r32[5:0], r32[7:6]);
        end
        for (i = 0; i < 300; i = i + 1) begin
            r32 = rnd(0);
            cycle(1'b0, 1'b0, r32[5:0], r32[7:6]);             
        end
        scan_all("T7 after idle wiggle");

        // T8: back-to-back accesses
        $display("T8: back-to-back accesses");
        do_reset(1);
        for (i = 0; i < 12; i = i + 1) cycle(1'b0, 1'b1, 6'd3, i % 4);
        for (i = 0; i < 12; i = i + 1) cycle(1'b0, 1'b1, 6'd3, 3 - (i % 4));
        scan_all("T8 same set, varying way");
        for (i = 0; i < 40; i = i + 1) cycle(1'b0, 1'b1, (i % 2) ? 6'd4 : 6'd3, (i / 2) % 4);
        scan_all("T8 alternating sets");
        for (i = 0; i < 10; i = i + 1) cycle(1'b0, 1'b1, 6'd9, 2'd1);
        scan_all("T8 same way repeated");
        for (i = 0; i < 400; i = i + 1) begin
            r32 = rnd(0);
            cycle(1'b0, 1'b1, r32[5:0], r32[7:6]);
        end
        scan_all("T8 random burst");

        // T9: random regression
        $display("T9: random regression (random resets, hot sets)");
        for (n = 0; n < 40000; n = n + 1) begin
            r32 = rnd(0);
            sb = (r32[9:8] == 2'd0) ? {4'b0000, r32[1:0]} :
                 (r32[9:8] == 2'd1) ? 6'd63 : r32[5:0];
            cycle((r32[20:12] == 9'd0),            
                  (r32[10] | r32[11]),             
                  sb, r32[23:22]);
            if (n % 2500 == 2499) scan_all("T9 periodic full scan");
        end
        scan_all("T9 end");

        // T10: functional coverage
        $display("T10: functional coverage");
        $display("  tree-state x way transitions covered: %0d / 32", count_ones(cov));
        if (count_ones(cov) !== 32) begin
            test_errors = test_errors + 1;
            $display("[ERROR] coverage hole, mask = %b", cov);
        end

        // T11: Way Mask Override
        $display("T11: way_mask hardware overrides");
        @(negedge clk);
        rst = 0; access_valid = 0; set_idx = 6'd15; test_mask = 4'b1111;
        #1;
        vv = victim_way; 
        
        if (vv == 2'd0) test_mask = 4'b1110;
        else if (vv == 2'd1) test_mask = 4'b1101;
        else if (vv == 2'd2) test_mask = 4'b1011;
        else test_mask = 4'b0111;
        
        #1; 
        if (victim_way === vv) begin
            test_errors = test_errors + 1;
            $display("[ERROR] T11: Mask failed to redirect victim away from locked way %0d", vv);
        end
        test_mask = 4'b1111;

        // ===================================================================
        $display("\n========================================================");
        $display("checks performed : %0d", checks);
        if (test_errors == 0) begin
            $display(">>> ALL PLRU TESTS PASSED <<<");
            $display("PASS plru (%0d checks)", checks);
        end else begin
            $display(">>> FAILED: %0d error(s) <<<", test_errors);
            $display("FAIL plru: %0d error(s)", test_errors);
        end
        $display("========================================================\n");
        $finish;
    end

    initial begin
        #(CLK_PERIOD * 2000000);
        $display("[ERROR] TIMEOUT");
        $finish;
    end
endmodule