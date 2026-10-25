`timescale 1ns / 1ps
`default_nettype none

//=============================================================================
// Testbench: tb_mem_delay
// Target: mem_delay.v
// Latencies: L = 4, 8, 12, 16
//=============================================================================

module tb_mem_delay;

    reg         clk = 1'b0;
    reg         rst = 1'b1;
    always #10 clk = ~clk;

    reg  [1:0]  lat     = 2'd0;
    reg         start   = 1'b0;
    reg         we      = 1'b0;
    reg         nwords  = 1'b0;
    reg  [29:0] addr    = 30'd0;
    reg  [31:0] wdata   = 32'd0;
    reg  [3:0]  be      = 4'hF;

    wire        rvalid;
    wire [31:0] rdata;
    wire        wready;
    wire        done;

    wire [29:0] m_addr;
    wire        m_we;
    wire [3:0]  m_be;
    wire [31:0] m_wdata;
    reg  [31:0] m_rdata = 32'd0;

    mem_delay dut (
        .clk     (clk),
        .rst     (rst),
        .lat     (lat),
        .start   (start),
        .we      (we),
        .addr    (addr),
        .nwords  (nwords),
        .wdata   (wdata),
        .be      (be),
        .rvalid  (rvalid),
        .rdata   (rdata),
        .wready  (wready),
        .done    (done),
        .m_addr  (m_addr),
        .m_we    (m_we),
        .m_be    (m_be),
        .m_wdata (m_wdata),
        .m_rdata (m_rdata)
    );

    // BRAM model and reference model
    reg [31:0] bram  [0:1023];
    reg [31:0] model [0:1023];
    integer nb;

    always @(posedge clk) begin
        m_rdata <= bram[m_addr[9:0]];
        if (m_we) begin
            for (nb = 0; nb < 4; nb = nb + 1) begin
                if (m_be[nb]) bram[m_addr[9:0]][8*nb +: 8] <= m_wdata[8*nb +: 8];
            end
        end
    end

    integer errors = 0;
    integer checks = 0;
    integer seed   = 55;

    task fail(input [8*48-1:0] what, input [31:0] got, input [31:0] want);
        begin
            errors = errors + 1;
            if (errors <= 12) begin
                $display("  [FAIL] %0s: got %08h want %08h (L code %0d, t=%0t)", what, got, want, lat, $time);
            end
        end
    endtask

    function integer lval(input [1:0] c);
        case (c)
            2'd0: lval = 4;
            2'd1: lval = 8;
            2'd2: lval = 12;
            2'd3: lval = 16;
        endcase
    endfunction

    integer c, L, nw, k, n, wcount;
    reg [31:0] wd [0:3];

    task burst(input w, input four, input [29:0] a, input [3:0] bmask, input extra_start);
        begin
            L  = lval(lat);
            nw = four ? 4 : 1;
            for (k = 0; k < 4; k = k + 1) wd[k] = $random(seed);

            // Called at negedge clk: this is cycle 0
            start  = 1'b1;
            we     = w;
            nwords = four;
            addr   = a;
            be     = bmask;
            wcount = 0;

            for (c = 0; c <= L + nw - 1; c = c + 1) begin
                if (c == 1) start = extra_start;
                if (c == 2) start = 1'b0;
                if (c == L + nw - 1 && extra_start) start = 1'b1;

                // Wait for positive edge to register and sample 1ns after posedge
                @(posedge clk);
                #1;
                checks = checks + 3;

                if (rvalid !== (!w && c >= L && c < L + nw))
                    fail("rvalid timing", {31'd0, rvalid}, {31'd0, (!w && c >= L && c < L + nw)});
                if (wready !== (w && c >= L && c < L + nw))
                    fail("wready timing", {31'd0, wready}, {31'd0, (w && c >= L && c < L + nw)});
                if (done !== (c == L + nw - 1))
                    fail("done timing", {31'd0, done}, {31'd0, (c == L + nw - 1)});

                if (rvalid) begin
                    checks = checks + 1;
                    if (rdata !== model[(a + c - L) & 1023])
                        fail("rdata", rdata, model[(a + c - L) & 1023]);
                end

                if (wready) begin
                    for (n = 0; n < 4; n = n + 1) begin
                        if (four || bmask[n])
                            model[(a + c - L) & 1023][8*n +: 8] = wd[c - L][8*n +: 8];
                    end
                    wcount = wcount + 1;
                end

                @(negedge clk);
                if (w && c >= L) wdata = wd[(c - L) & 3];
            end
            start = 1'b0;
        end
    endtask

    task idle(input integer g);
        integer j;
        begin
            for (j = 0; j < g; j = j + 1) begin
                @(posedge clk);
                #1;
                checks = checks + 1;
                if (rvalid || wready || done)
                    fail("pulse while idle", {rvalid, wready, done}, 0);
                @(negedge clk);
            end
        end
    endtask

    task check_mem;
        integer j;
        begin
            for (j = 0; j < 1024; j = j + 1) begin
                checks = checks + 1;
                if (bram[j] !== model[j])
                    fail("memory word", bram[j], model[j]);
            end
        end
    endtask

    integer i, lc, bp, r;
    initial begin
        $display("=================================================================");
        $display(" RUNNING MEM_DELAY TESTBENCH (tb_mem_delay)");
        $display("=================================================================");

        for (i = 0; i < 1024; i = i + 1) begin
            bram[i]  = (i * 32'h01000193) ^ 32'hA5A5A5A5;
            model[i] = bram[i];
        end

        // Clean reset
        @(posedge clk);
        rst = 1'b1;
        @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        for (lc = 0; lc < 4; lc = lc + 1) begin
            lat = lc[1:0];
            $display("[INFO] Testing Latency Setting L = %0d cycles...", lval(lat));

            burst(0, 0, 30'd17, 4'hF, 0);              // 1-word read
            burst(0, 1, 30'd40, 4'hF, 0);              // 4-word read
            for (bp = 0; bp < 16; bp = bp + 1)         // 1-word write, every byte-enable pattern
                burst(1, 0, 30'd100 + bp, bp[3:0], 0);
            burst(1, 1, 30'd200, 4'h0, 0);              // 4-word write
            burst(0, 1, 30'd200, 4'hF, 0);              // read it back

            // Back to back
            burst(0, 0, 30'd300, 4'hF, 1);
            burst(1, 0, 30'd301, 4'h5, 1);
            burst(0, 1, 30'd300, 4'hF, 1);
            idle(3);
            check_mem();
        end

        $display("[INFO] Running 2,000 Randomized Burst Transfers...");
        for (r = 0; r < 2000; r = r + 1) begin
            lat = $random(seed);
            burst($random(seed), $random(seed), $random(seed) & 30'h3FF, $random(seed), $random(seed));
            idle($unsigned($random(seed)) % 4);
        end
        check_mem();

        $display("=================================================================");
        if (errors == 0 && checks > 50000)
            $display(" [PASS] mem_delay (%0d checks: L = 4, 8, 12, 16, 1/4-word R/W, 16 BEs, 2000 bursts)", checks);
        else
            $display(" [FAIL] mem_delay: %0d errors in %0d checks", errors, checks);
        $display("=================================================================");
        $finish;
    end

endmodule

`default_nettype wire