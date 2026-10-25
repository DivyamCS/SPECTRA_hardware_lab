`timescale 1ns / 1ps
`default_nettype none
// tb_dcache_random - driven by tb/dcache/run_random.py. dcache + mem_delay +
// dmem_bram (empty) replays the files v00.mem .. v03.mem written by run.py from
// tools/gen_cache_vectors.py (four random seeds; write-back / write-allocate, PLRU), each once
// for every L = 5, 6, 8, 10, after a reset with an empty memory. Per access (line "op addr wdata be rdata hit victim dirty c5 c6 c8 c10"):
//   ready in exactly cN cycles; ev_hit / ev_miss = hit; a filled way = victim (4 = no fill);
//   a write-back first exactly when dirty = 1; loads return rdata (the memory image's word).
// Prints "PASS dcache_random (...)" or FAIL with the first mismatches.

module tb_dcache_random;

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

    integer errors = 0, total = 0, n_hit = 0, n_dirty = 0, run_errors;
    integer fd, cf, fi, li, r, line, k, c, nh, nm, wb_seen, filled;
    task fail(input [8*40-1:0] what, input [31:0] got, input [31:0] want);
        begin
            errors = errors + 1; run_errors = run_errors + 1;
            if (errors <= 15) $display("%0s: got %0h want %0h (file v%02d, L code %0d, line %0d, addr %08h)",
                                       what, got, want, fi, lat, line, addr);
        end
    endtask

    integer op, hit, victim, dirty, cy [0:3];
    reg [31:0] a, d, rd;
    reg [3:0]  b;
    reg [8*16-1:0] fname;

    initial begin
        for (fi = 0; fi < 4; fi = fi + 1)
            for (li = 0; li < 4; li = li + 1) begin
                // reset with an empty memory and this configuration
                @(negedge clk);
                rst = 1'b1; lat = li;
                for (k = 0; k < 32768; k = k + 1) u_mem.mem[k] = 32'd0;
                @(negedge clk); @(negedge clk); rst = 1'b0;
                run_errors = 0;
                $sformat(fname, "v%02d.mem", fi);
                fd = $fopen(fname, "r");
                line = 0;
                while (!$feof(fd)) begin
                    r = $fscanf(fd, "%d %h %h %h %h %d %d %d %d %d %d %d\n",
                                op, a, d, b, rd, hit, victim, dirty, cy[0], cy[1], cy[2], cy[3]);
                    if (r == 12) begin
                        line = line + 1; total = total + 1;
                        @(negedge clk);
                        req = 1'b1; we = op; addr = a; wdata = d; be = b;
                        c = 1; nh = 0; nm = 0; wb_seen = 0; filled = 4;
                        #1;
                        while (!ready && c < 300) begin
                            if (ev_hit) nh = nh + 1;
                            if (ev_miss) nm = nm + 1;
                            if (dut.state == 3'd2) wb_seen = 1;             // S_WB
                            if (dut.state == 3'd4 && m_done) filled = dut.victim_way_reg; // refill ends
                            @(negedge clk); #1; c = c + 1;
                        end
                        if (ev_hit) nh = nh + 1;
                        if (ev_miss) nm = nm + 1;
                        if (c != cy[li]) fail("ready cycle", c, cy[li]);
                        if (nh != hit || nm != 1 - hit) fail("hit/miss pulse", {nh[3:0], nm[3:0]}, hit ? 8'h10 : 8'h01);
                        if (filled != victim) fail("way filled", filled, victim);
                        if (wb_seen != dirty) fail("write-back", wb_seen, dirty);
                        if (op == 0 && rdata !== rd) fail("load data", rdata, rd);
                        n_hit = n_hit + hit; n_dirty = n_dirty + dirty;
                        @(negedge clk); req = 1'b0;
                    end
                end
                $fclose(fd);
                if (run_errors != 0)
                    $display("file v%02d L code %0d: %0d errors", fi, li, run_errors);
            end
        if (errors == 0 && total > 0)
            $display("PASS dcache_random (%0d accesses = 4 files x 4 L; %0d hits, %0d dirty evictions; 0 mismatches in data, hit/miss, victim and cycles)",
                     total, n_hit, n_dirty);
        else
            $display("FAIL dcache_random: %0d errors in %0d accesses", errors, total);
        $finish;
    end

endmodule

`default_nettype wire
