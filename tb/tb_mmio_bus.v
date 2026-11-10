`timescale 1ns / 1ps
`default_nettype none
// tb_mmio_bus - driven by tb/mmio/run.py (mmio_map.mem = the register table of
// PROTOCOL.md section 3, "offset code access core index"). mmio_bus with the real lock_barrier
// and perf_counters. For every register: ready in the cycle of sel; a read (R) returns the
// expected value - CORE_ID for both owners, NCORES, CONFIG, SWITCHES, debounced BUTTONS, LOCK
// test-and-set, BARRIER 0, CYCLES and all 14 per-core counters after a run with known event
// counts; a write (W) has its effect - RUN_START / RUN_STOP, LEDS, SEG7, SEG7_DP, a 1-cycle
// pulse with data and owner for GEN_DONE, CHECKSUM, ROW_DONE, MROW_DONE, LOCK release by 0.
// Reads of W-only registers return 0; writes to R-only registers change nothing; every
// offset not in the map reads 0 and a write there changes nothing. Prints one PASS/FAIL line.

module tb_mmio_bus;

    reg         clk = 1'b0, rst = 1'b1;
    always #10 clk = ~clk;

    reg         sel = 0, we = 0, owner = 0;
    reg  [7:0]  off = 0;
    reg  [31:0] wdata = 0;
    wire [31:0] rdata, rd_data, st_data;
    wire        ready, lock_rd, lock_wr0, lock_rdata, run_start, run_stop;
    wire        st_gen_done, st_checksum, st_row_done, st_mrow_done, st_owner, st_maze_frame, st_maze_map;
    wire [3:0]  rd_sel;
    wire [15:0] leds;
    wire [26:0] seg7_val;
    wire [7:0]  seg7_dp;
    wire [31:0] seg7_txt;
    wire [479:0] snap;
    reg  [15:0] cfg = 16'hBEEF, sw_live = 16'h1357;
    reg  [3:0]  btn = 4'b0000;
    reg  [1:0]  ncores = 2'd2;

    mmio_bus #(.DEB_BITS(3)) dut (.clk(clk), .rst(rst), .sel(sel), .we(we), .off(off), .wdata(wdata),
        .owner(owner), .rdata(rdata), .ready(ready), .cfg(cfg), .ncores(ncores), .sw_live(sw_live),
        .btn(btn), .lock_rd(lock_rd), .lock_wr0(lock_wr0), .lock_rdata(lock_rdata),
        .run_start(run_start), .run_stop(run_stop), .rd_sel(rd_sel), .rd_data(rd_data),
        .leds(leds), .seg7_val(seg7_val), .seg7_dp(seg7_dp), .seg7_txt(seg7_txt),
        .st_gen_done(st_gen_done), .st_checksum(st_checksum), .st_row_done(st_row_done),
        .st_mrow_done(st_mrow_done), .st_maze_frame(st_maze_frame), .st_maze_map(st_maze_map),
        .st_data(st_data), .st_owner(st_owner));
    lock_barrier u_lb (.clk(clk), .rst(rst), .ncores(ncores), .lock_rd(lock_rd), .lock_wr0(lock_wr0),
        .owner(owner), .lock_rdata(lock_rdata), .bar_req(2'b00), .bar_release(),
        .ev_barwait0(), .ev_barwait1());
    // events into the counters, driven by the TB (ev[n] = pulse for counter index n)
    reg  [15:0] ev = 0;
    perf_counters u_pc (.clk(clk), .rst(rst), .run_start(run_start), .run_stop(run_stop),
        .ev_instret({ev[9], ev[1]}), .ev_ihit({ev[12], ev[4]}), .ev_imiss({ev[13], ev[5]}),
        .ev_arbwait({ev[14], ev[6]}), .ev_barwait({ev[15], ev[7]}),
        .ev_dhit(ev[2] | ev[10]), .ev_dmiss(ev[3] | ev[11]), .ev_downer(ev[10] | ev[11]),
        .rd_sel(rd_sel), .rd_data(rd_data), .snap(snap));

    integer errors = 0, checks = 0, regs = 0;
    task fail(input [8*44-1:0] what, input [31:0] got, input [31:0] want);
        begin
            errors = errors + 1;
            if (errors <= 15) $display("%0s: got %08h want %08h (offset %02h owner %0d)", what, got, want, off, owner);
        end
    endtask

    // pulses seen during the last access
    integer n_gen, n_chk, n_row, n_mrow, n_start, n_stop, n_mzf, n_mzm;
    reg [31:0] p_data; reg p_owner;
    always @(posedge clk) begin
        if (st_gen_done)  begin n_gen  = n_gen + 1;  p_data = st_data; p_owner = st_owner; end
        if (st_checksum)  begin n_chk  = n_chk + 1;  p_data = st_data; p_owner = st_owner; end
        if (st_row_done)  begin n_row  = n_row + 1;  p_data = st_data; p_owner = st_owner; end
        if (st_mrow_done) begin n_mrow = n_mrow + 1; p_data = st_data; p_owner = st_owner; end
        if (st_maze_frame) begin n_mzf = n_mzf + 1; p_data = st_data; p_owner = st_owner; end
        if (st_maze_map)  begin n_mzm = n_mzm + 1;  p_data = st_data; p_owner = st_owner; end
        if (run_start) n_start = n_start + 1;
        if (run_stop)  n_stop = n_stop + 1;
    end
    task clear_pulses; begin n_gen = 0; n_chk = 0; n_row = 0; n_mrow = 0; n_start = 0; n_stop = 0; n_mzf = 0; n_mzm = 0; end endtask

    // one access, one cycle of sel; returns read data
    reg [31:0] got;
    task acc(input w, input [7:0] o, input [31:0] d, input ow);
        begin
            @(negedge clk); sel = 1; we = w; off = o; wdata = d; owner = ow;
            #1; checks = checks + 1;
            if (!ready) fail("ready in the cycle of sel", 0, 1);
            got = rdata;
            @(negedge clk); sel = 0; we = 0;
        end
    endtask
    task rd_expect(input [7:0] o, input ow, input [31:0] want, input [8*24-1:0] what);
        begin acc(0, o, 0, ow); checks = checks + 1; if (got !== want) fail(what, got, want); end
    endtask
    task outputs_unchanged(input [15:0] l, input [26:0] s, input [7:0] d);
        begin
            checks = checks + 2;
            if (leds !== l || seg7_val !== s || seg7_dp !== d) fail("an output changed", {leds, seg7_dp}, {l, d});
            if (n_gen + n_chk + n_row + n_mrow + n_start + n_stop + n_mzf + n_mzm != 0) fail("a pulse fired", 1, 0);
        end
    endtask

    // TIMER reference: clk cycles since reset, counted here
    reg [31:0] tb_cycles = 0, t1;
    always @(posedge clk) tb_cycles <= rst ? 32'd0 : tb_cycles + 32'd1;

    // map
    integer mo [0:63], mc [0:63], ma [0:63], mk [0:63], mj [0:63], nm = 0, fd, r, a, b, c, d, e, i, k, o2;
    reg mapped [0:63];
    integer evcount [0:15];
    reg [15:0] l_s; reg [26:0] s_s; reg [7:0] d_s;
    initial begin
        for (i = 0; i < 64; i = i + 1) mapped[i] = 0;
        fd = $fopen("mmio_map.mem", "r");
        while (!$feof(fd)) begin
            r = $fscanf(fd, "%h %h %h %h %h\n", a, b, c, d, e);
            if (r == 5) begin mo[nm] = a; mc[nm] = b; ma[nm] = c; mk[nm] = d; mj[nm] = e; mapped[a >> 2] = 1; nm = nm + 1; end
        end
        $fclose(fd);
        clear_pulses;
        repeat (2) @(negedge clk); rst = 0;
        // buttons settle through the debouncer
        btn = 4'b1010; repeat (20) @(negedge clk);
        // a run with known counts: counter n gets 3 + n events
        acc(1, 8'h14, 0, 0);                                     // RUN_START (offset from the map below too)
        for (i = 0; i < 16; i = i + 1) evcount[i] = (i == 0 || i == 8) ? 0 : 3 + i;
        // the core counters together (counter n gets 3 + n pulses) ...
        for (k = 0; k < 20; k = k + 1) begin
            @(negedge clk);
            for (i = 1; i < 16; i = i + 1)
                ev[i] = (i != 8 && i != 2 && i != 3 && i != 10 && i != 11) && (k < 3 + i);
        end
        // ... and the D-cache ones one at a time (the D-cache gives one event per cycle)
        for (i = 2; i < 12; i = i + 1) if (i == 2 || i == 3 || i == 10 || i == 11)
            for (k = 0; k < 3 + i; k = k + 1) begin @(negedge clk); ev = 16'd1 << i; end
        @(negedge clk); ev = 0;
        acc(1, 8'h18, 0, 0);                                     // RUN_STOP
        // pass 0: every register but RUN_START / RUN_STOP (which clear and restart the counters);
        // pass 1: those two
        for (k = 0; k < 2; k = k + 1)
        for (i = 0; i < nm; i = i + 1) if ((mc[i] == 6 || mc[i] == 7) == (k == 1)) begin
            regs = regs + 1;
            clear_pulses;
            case (mc[i])
                1:  begin rd_expect(mo[i], 0, 0, "CORE_ID owner 0"); rd_expect(mo[i], 1, 1, "CORE_ID owner 1"); end
                2:  rd_expect(mo[i], 0, ncores, "NCORES");
                3:  rd_expect(mo[i], 1, cfg, "CONFIG");
                4:  rd_expect(mo[i], 1, 0, "BARRIER reads 0");
                5:  begin
                        rd_expect(mo[i], 0, 0, "LOCK acquire");
                        rd_expect(mo[i], 1, 1, "LOCK busy");
                        acc(1, mo[i], 32'd5, 0); rd_expect(mo[i], 0, 1, "LOCK not released by 5");
                        acc(1, mo[i], 32'd0, 1); rd_expect(mo[i], 1, 0, "LOCK released by 0");
                        acc(1, mo[i], 32'd0, 1);
                    end
                6:  begin acc(1, mo[i], 0, 0); checks = checks + 1; if (n_start != 1) fail("RUN_START pulse", n_start, 1);
                          acc(1, 8'h18, 0, 0); end           // stop again so the counters stay
                7:  begin acc(1, mo[i], 0, 0); checks = checks + 1; if (n_stop != 1) fail("RUN_STOP pulse", n_stop, 1); end
                8, 9, 12, 13, 21, 22: begin
                        acc(1, mo[i], 32'hC0DE0000 + mo[i], 1);
                        checks = checks + 3;
                        if ((mc[i] == 8 ? n_gen : mc[i] == 9 ? n_chk : mc[i] == 12 ? n_row : mc[i] == 13 ? n_mrow :
                             mc[i] == 21 ? n_mzf : n_mzm) != 1) fail("event pulse", 0, 1);
                        if (n_gen + n_chk + n_row + n_mrow + n_mzf + n_mzm != 1)
                            fail("only that pulse", n_gen + n_chk + n_row + n_mrow + n_mzf + n_mzm, 1);
                        if (p_data !== 32'hC0DE0000 + mo[i] || p_owner !== 1'b1) fail("pulse data / owner", p_data, 32'hC0DE0000 + mo[i]);
                    end
                10: begin acc(1, mo[i], 32'h0001A5C3, 0); checks = checks + 1; if (leds !== 16'hA5C3) fail("LEDS", leds, 16'hA5C3); end
                11: begin acc(1, mo[i], 32'h05F5E0FF, 0); checks = checks + 1; if (seg7_val !== 27'd99999999) fail("SEG7", seg7_val, 99999999); end
                17: begin acc(1, mo[i], 32'h00000084, 0); checks = checks + 1; if (seg7_dp !== 8'h84) fail("SEG7_DP", seg7_dp, 8'h84); end
                20: begin acc(1, mo[i], 32'h17300000, 0); checks = checks + 1; if (seg7_txt !== 32'h17300000) fail("SEG7_TXT", seg7_txt, 32'h17300000); end
                23: begin                              // MAZE_SAVE_*: read back what was written
                        acc(1, mo[i], 32'h4D5A0000 + mo[i], 1);
                        rd_expect(mo[i], 0, 32'h4D5A0000 + mo[i], "MAZE_SAVE read back");
                    end
                14: rd_expect(mo[i], 0, u_pc.cnt[0], "CYCLES");
                15: rd_expect(mo[i], 0, sw_live, "SWITCHES");
                16: rd_expect(mo[i], 0, 32'h0000000A, "BUTTONS (debounced)");
                18: rd_expect(mo[i], 0, evcount[1 + 8 * mk[i] + mj[i]], "counter");
                19: begin                              // TIMER: = this TB's cycle count, not frozen
                        acc(0, mo[i], 0, 0); t1 = got; checks = checks + 1;
                        // acc returns one clock edge after its sample, so the sample time is tb_cycles - 1
                        if (t1 !== tb_cycles - 32'd1) fail("TIMER = cycles since reset", t1, tb_cycles - 32'd1);
                        repeat (37) @(negedge clk);
                        acc(0, mo[i], 0, 1); checks = checks + 1;
                        if (got - t1 !== 32'd39) fail("TIMER advances 1 per cycle after RUN_STOP", got - t1, 39);
                    end
                default: fail("unknown code in the map", mc[i], 0);
            endcase
            // the other direction: reads of W-only read 0, writes to R-only change nothing
            clear_pulses;
            if (ma[i] == 2) rd_expect(mo[i], 0, 0, "read of a W-only register");
            if (ma[i] == 1) begin
                clear_pulses;
                l_s = leds; s_s = seg7_val; d_s = seg7_dp;
                acc(1, mo[i], 32'hFFFFFFFF, 0);
                outputs_unchanged(l_s, s_s, d_s);
            end
        end
        // offsets not in the map: read 0, write changes nothing
        for (o2 = 0; o2 < 64; o2 = o2 + 1) if (!mapped[o2]) begin
            clear_pulses;
            rd_expect(o2 << 2, 0, 0, "unmapped offset reads 0");
            clear_pulses;
            acc(1, o2 << 2, 32'hFFFFFFFF, 1);
            outputs_unchanged(leds, seg7_val, seg7_dp);
            checks = checks + 1;
            if (u_lb.lock !== 1'b0) fail("unmapped write touched LOCK", u_lb.lock, 0);
        end
        // MAZE_SAVE_* keep their values through a reset (BTNC keeps the maze pose)
        @(negedge clk); rst = 1; repeat (3) @(negedge clk); rst = 0;
        rd_expect(8'hA0, 0, 32'h4D5A00A0, "MAZE_SAVE_X after reset");
        rd_expect(8'hA8, 0, 32'h4D5A00A8, "MAZE_SAVE_A after reset");
        if (errors == 0 && regs == nm && nm == 38)          // 24 registers + 14 counters (PROTOCOL.md)
            $display("PASS mmio_bus (%0d checks: %0d map entries from PROTOCOL.md, both directions, every unmapped offset)", checks, nm);
        else
            $display("FAIL mmio_bus: %0d errors in %0d checks, %0d map entries", errors, checks, nm);
        $finish;
    end

endmodule

`default_nettype wire
