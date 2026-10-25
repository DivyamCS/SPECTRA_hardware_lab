`timescale 1ns / 1ps
`default_nettype none
// tb_addr_decode - addr_decode between a requesting master (the TB) and stub
// slaves: a D-cache stub (ready in cycle 2) and an MMIO stub (ready in the cycle of sel, or
// N cycles later for offset 0x0C, like a BARRIER read). For the first and last word of each
// range and one past each end, as load and store with owner 0 and 1:
//   routed to exactly one place (dc_req / io_sel / neither), fields and owner forwarded,
//   ready in cycle 2 (MMIO: sel in cycle 2, + N for the delayed offset), unmapped: rdata 0,
//   nothing downstream, decode_err set and sticky; back-to-back requests.
// Prints one PASS/FAIL line.

module tb_addr_decode;

    reg         clk = 1'b0, rst = 1'b1;
    always #10 clk = ~clk;
    reg         req = 0, we = 0, owner = 0;
    reg  [31:0] addr = 0, wdata = 0;
    reg  [3:0]  be = 4'hF;
    wire [31:0] rdata, dc_addr, dc_wdata, io_wdata;
    wire        ready, dc_req, dc_we, dc_owner, io_sel, io_we, io_owner, decode_err;
    wire [3:0]  dc_be;
    wire [7:0]  io_off;
    reg         dc_ready = 0, io_ready_d = 0;
    reg  [31:0] dc_rdata = 0;

    // MMIO stub: ready with sel, except offset 0x0C: ready BAR_N cycles after sel rises
    localparam BAR_N = 5;
    integer    sel_cyc = 0;
    wire       io_ready = io_sel && (io_off != 8'h0C || sel_cyc >= BAR_N);
    wire [31:0] io_rdata = {24'hA00000, io_off} ^ {31'd0, io_owner};
    always @(posedge clk) sel_cyc <= io_sel && !io_ready ? sel_cyc + 1 : 0;

    // D-cache stub: ready in cycle 2 of its request
    always @(posedge clk) begin
        dc_ready <= dc_req && !dc_ready;
        dc_rdata <= dc_addr ^ 32'h5555AAAA;
    end

    addr_decode dut (.clk(clk), .rst(rst), .req(req), .we(we), .addr(addr), .wdata(wdata), .be(be),
        .owner(owner), .rdata(rdata), .ready(ready),
        .dc_req(dc_req), .dc_we(dc_we), .dc_addr(dc_addr), .dc_wdata(dc_wdata), .dc_be(dc_be),
        .dc_owner(dc_owner), .dc_rdata(dc_rdata), .dc_ready(dc_ready),
        .io_sel(io_sel), .io_we(io_we), .io_off(io_off), .io_wdata(io_wdata), .io_owner(io_owner),
        .io_rdata(io_rdata), .io_ready(io_ready), .decode_err(decode_err));

    integer errors = 0, checks = 0;
    task fail(input [8*44-1:0] what, input [31:0] got, input [31:0] want);
        begin
            errors = errors + 1;
            if (errors <= 15) $display("%0s: got %08h want %08h (addr %08h we %0d owner %0d)", what, got, want, addr, we, owner);
        end
    endtask

    // one access; kind 0 = D-cache, 1 = MMIO, 2 = unmapped. Called at a negedge; returns at
    // the negedge after ready with the request dropped only if `drop` (else the caller's next
    // access takes over in that cycle: back to back)
    integer c, want_c, saw_dc, saw_io;
    reg [31:0] want_r;
    task acc(input w, input [31:0] a, input o, input integer kind, input drop);
        begin
            req = 1; we = w; addr = a; owner = o; wdata = a ^ 32'h0F0F0F0F; be = 4'b0110;
            c = 1; saw_dc = 0; saw_io = 0;
            #1;
            while (!ready && c < 50) begin
                if (dc_req) saw_dc = 1;
                if (io_sel) begin
                    saw_io = 1;
                    checks = checks + 4;
                    if (io_we !== w) fail("io_we", io_we, w);
                    if (io_off !== a[7:0]) fail("io_off", io_off, a[7:0]);
                    if (io_wdata !== wdata) fail("io_wdata", io_wdata, wdata);
                    if (io_owner !== o) fail("io_owner", io_owner, o);
                end
                @(negedge clk); #1; c = c + 1;
            end
            if (dc_req) begin
                saw_dc = 1;
                checks = checks + 4;
                if (dc_addr !== a || dc_we !== w || dc_be !== 4'b0110) fail("dc fields", dc_addr, a);
                if (dc_owner !== o) fail("dc_owner", dc_owner, o);
            end
            if (io_sel) saw_io = 1;
            want_c = (kind == 1 && a[7:0] == 8'h0C) ? 2 + BAR_N : 2;
            want_r = (kind == 0) ? (a ^ 32'h5555AAAA) : (kind == 1) ? ({24'hA00000, a[7:0]} ^ o) : 32'd0;
            checks = checks + 4;
            if (c != want_c) fail("ready cycle", c, want_c);
            if (!w && rdata !== want_r) fail("rdata", rdata, want_r);
            if (saw_dc !== (kind == 0)) fail("routed to the D-cache", saw_dc, kind == 0);
            if (saw_io !== (kind == 1)) fail("routed to MMIO", saw_io, kind == 1);
            @(negedge clk);
            if (drop) req = 0;
        end
    endtask

    integer i, o, w;
    reg [31:0] A [0:11];
    integer    K [0:11];
    initial begin
        A[0]  = 32'h0FFFFFFC; K[0]  = 2;      // one below the D range
        A[1]  = 32'h10000000; K[1]  = 0;      // first word of the D range
        A[2]  = 32'h1001FFFC; K[2]  = 0;      // last word
        A[3]  = 32'h10020000; K[3]  = 2;      // one past
        A[4]  = 32'h1FFFFFFC; K[4]  = 2;
        A[5]  = 32'h20000000; K[5]  = 1;      // first MMIO register
        A[6]  = 32'h200000FC; K[6]  = 1;      // last MMIO offset
        A[7]  = 32'h20000100; K[7]  = 2;      // one past
        A[8]  = 32'h1FFFFFFC; K[8]  = 2;
        A[9]  = 32'h00000000; K[9]  = 2;      // IMEM is not on the data port
        A[10] = 32'h2000000C; K[10] = 1;      // BARRIER-like: ready held
        A[11] = 32'hFFFFFFFC; K[11] = 2;
        repeat (2) @(negedge clk); rst = 0;
        // mapped accesses first: decode_err stays 0
        for (o = 0; o < 2; o = o + 1)
            for (w = 0; w < 2; w = w + 1)
                for (i = 0; i < 12; i = i + 1) if (K[i] != 2) acc(w, A[i], o, K[i], 1);
        checks = checks + 1;
        if (decode_err !== 1'b0) fail("decode_err before any unmapped access", decode_err, 0);
        // then everything, back to back (no idle cycle between requests)
        for (o = 0; o < 2; o = o + 1)
            for (w = 0; w < 2; w = w + 1)
                for (i = 0; i < 12; i = i + 1) acc(w, A[i], o, K[i], 0);
        req = 0;
        repeat (3) @(negedge clk);
        checks = checks + 1;
        if (decode_err !== 1'b1) fail("decode_err sticky", decode_err, 1);
        rst = 1; @(negedge clk); rst = 0; #1;
        checks = checks + 1;
        if (decode_err !== 1'b0) fail("decode_err cleared by reset", decode_err, 0);
        if (errors == 0 && checks > 300)
            $display("PASS addr_decode (%0d checks: range edges, loads and stores, owners, cycle-2 timing, delayed MMIO ready, sticky decode_err, back to back)", checks);
        else
            $display("FAIL addr_decode: %0d errors in %0d checks", errors, checks);
        $finish;
    end

endmodule

`default_nettype wire
