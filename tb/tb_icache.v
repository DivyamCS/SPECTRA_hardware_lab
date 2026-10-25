`timescale 1ns / 1ps
`default_nettype none
// tb_icache - driven by tb/icache/run.py (imem.hex and fetch.mem in the run
// directory). icache + mem_delay + imem_bram. A pipelined master: each fetch is presented in the
// same cycle as the previous fetch_ready (as the core does), so a run of hits costs one cycle each. For IC = 1 and IC = 0 and every L: the
// cycle of each fetch_ready (the request's first cycle = 1) equals fetch.mem's, the word equals
// imem.hex, ic_hit / ic_miss equal the Python hit/miss sequence (none with IC = 0), and no
// fetch_ready comes without a request. Prints one PASS/FAIL line.

module tb_icache;

    reg         clk = 1'b0, rst = 1'b1;
    always #10 clk = ~clk;

    reg         ic_en = 1'b1;
    reg  [1:0]  lat = 2'd0;
    reg         fetch_req = 1'b0;
    reg  [31:0] fetch_addr = 32'd0;
    wire        fetch_ready, ic_hit, ic_miss;
    wire [31:0] instr;
    wire        m_start, m_we, m_nwords, m_rvalid, m_wready, m_done, b_we;
    wire [29:0] m_addr, b_addr;
    wire [31:0] m_wdata, m_rdata, b_wdata, b_rdata;
    wire [3:0]  m_be, b_be;

    icache dut (.clk(clk), .rst(rst), .ic_en(ic_en), .fetch_req(fetch_req), .fetch_addr(fetch_addr),
                .fetch_ready(fetch_ready), .instr(instr),
                .m_start(m_start), .m_we(m_we), .m_addr(m_addr), .m_nwords(m_nwords),
                .m_wdata(m_wdata), .m_be(m_be), .m_rvalid(m_rvalid), .m_rdata(m_rdata),
                .m_wready(m_wready), .m_done(m_done), .ic_hit(ic_hit), .ic_miss(ic_miss));
    mem_delay u_md (.clk(clk), .rst(rst), .lat(lat), .start(m_start), .we(m_we), .addr(m_addr),
                    .nwords(m_nwords), .wdata(m_wdata), .be(m_be), .rvalid(m_rvalid), .rdata(m_rdata),
                    .wready(m_wready), .done(m_done), .m_addr(b_addr), .m_we(b_we), .m_be(b_be),
                    .m_wdata(b_wdata), .m_rdata(b_rdata));
    imem_bram #(.INIT_FILE("imem.hex")) u_imem (.clk(clk), .addr_a(b_addr[11:0]), .rdata_a(b_rdata),
                                               .addr_b(12'd0), .rdata_b());

    localparam MAXF = 8192;
    reg  [31:0] f_addr [0:MAXF-1];
    reg         f_hit  [0:MAXF-1];
    integer     f_c1 [0:3][0:MAXF-1];
    integer     f_c0 [0:3][0:MAXF-1];
    reg  [31:0] imem [0:4095];
    integer     nf = 0, fd, r, hit_i, c5, c6, c8, c10, n5, n6, n8, n10;
    reg  [31:0] a;

    integer errors = 0, checks = 0, total = 0, mode, li, k, c, want_c, nh, nm, cycles_run;
    task fail(input [8*40-1:0] what, input [31:0] got, input [31:0] want);
        begin
            errors = errors + 1;
            if (errors <= 15) $display("%0s: got %0h want %0h (IC %0d, L code %0d, fetch %0d at %08h)",
                                       what, got, want, ic_en, lat, k, f_addr[k]);
        end
    endtask

    initial begin
        $readmemh("imem.hex", imem);
        fd = $fopen("fetch.mem", "r");
        while (!$feof(fd)) begin
            r = $fscanf(fd, "%h %d %d %d %d %d %d %d %d %d\n", a, hit_i, c5, c6, c8, c10, n5, n6, n8, n10);
            if (r == 10) begin
                f_addr[nf] = a; f_hit[nf] = hit_i;
                f_c1[0][nf] = c5; f_c1[1][nf] = c6; f_c1[2][nf] = c8; f_c1[3][nf] = c10;
                f_c0[0][nf] = n5; f_c0[1][nf] = n6; f_c0[2][nf] = n8; f_c0[3][nf] = n10;
                nf = nf + 1;
            end
        end
        $fclose(fd);
        for (mode = 1; mode >= 0; mode = mode - 1)
            for (li = 0; li < 4; li = li + 1) begin
                @(negedge clk);
                rst = 1'b1; ic_en = mode; lat = li; fetch_req = 1'b0;
                @(negedge clk); @(negedge clk); rst = 1'b0;
                // drive just after a rising edge, so a new fetch shares the cycle of the last ready
                @(posedge clk); #1;
                fetch_req = 1'b1; fetch_addr = f_addr[0];
                k = 0; c = 1; nh = 0; nm = 0; cycles_run = 0;
                while (k < nf && cycles_run < 2000000) begin
                    // this cycle: count pulses, look for the answer to fetch k
                    if (ic_hit) nh = nh + 1;
                    if (ic_miss) nm = nm + 1;
                    if (fetch_ready) begin
                        checks = checks + 3; total = total + 1;
                        want_c = mode ? f_c1[li][k] : f_c0[li][k];
                        if (c != want_c) fail("ready cycle", c, want_c);
                        if (instr !== imem[f_addr[k][13:2]]) fail("instruction", instr, imem[f_addr[k][13:2]]);
                        if (mode && (nh != f_hit[k] || nm != 1 - f_hit[k])) fail("hit/miss pulse", {nh[3:0], nm[3:0]}, f_hit[k] ? 8'h10 : 8'h01);
                        if (!mode && (nh != 0 || nm != 0)) fail("pulse with IC = 0", {nh[3:0], nm[3:0]}, 0);
                        k = k + 1; c = 1; nh = 0; nm = 0;
                        if (k < nf) fetch_addr = f_addr[k];        // the next fetch, this same cycle
                        else fetch_req = 1'b0;
                    end
                    @(posedge clk); #1;
                    c = c + 1; cycles_run = cycles_run + 1;
                end
                checks = checks + 1;
                if (k != nf) fail("fetches answered", k, nf);
                // no answer without a request
                repeat (30) begin
                    checks = checks + 1;
                    if (fetch_ready) fail("fetch_ready without a request", 1, 0);
                    @(posedge clk); #1;
                end
            end
        if (errors == 0 && total == 8 * nf)
            $display("PASS icache (%0d fetches x IC 1/0 x 4 L = %0d answers; hit/miss = Python, exact cycles, every word)",
                     nf, total);
        else
            $display("FAIL icache: %0d errors, %0d answers of %0d", errors, total, 8 * nf);
        $finish;
    end

endmodule

`default_nettype wire
