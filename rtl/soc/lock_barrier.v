`timescale 1ns / 1ps
`default_nettype none
// lock_barrier - LOCK and BARRIER (spec: docs/spec/lock_barrier.md, PROTOCOL.md section 3).
// LOCK: a read returns the lock bit (0 = acquired, 1 = busy) and sets it in the same cycle; a
// write of 0 clears it. The single data port serialises the cores, so two back-to-back reads
// give exactly one 0. BARRIER (spec 1.0.1): bar_req[k] = core k's BARRIER read is parked in
// rr_arbiter; when as many cores wait as are running (ncores) every waiting core is released in
// the same cycle (combinational bar_release), so with one core it releases at once.
// ev_barwaitk = 1 in every cycle core k waits.

module lock_barrier (
    input  wire       clk,
    input  wire       rst,
    input  wire [1:0] ncores,
    input  wire       lock_rd,
    input  wire       lock_wr0,
    input  wire       owner,           // the core of the LOCK access (not needed: any core releases)
    output wire       lock_rdata,
    input  wire [1:0] bar_req,
    output wire [1:0] bar_release,
    output wire       ev_barwait0,
    output wire       ev_barwait1
);

    reg  lock;
    wire [1:0] waiting = {1'b0, bar_req[0]} + {1'b0, bar_req[1]};

    assign lock_rdata  = lock;
    assign bar_release = (waiting == ncores) ? bar_req : 2'b00;
    assign ev_barwait0 = bar_req[0] && !bar_release[0];
    assign ev_barwait1 = bar_req[1] && !bar_release[1];

    always @(posedge clk) begin
        if (rst)           lock <= 1'b0;
        else if (lock_rd)  lock <= 1'b1;
        else if (lock_wr0) lock <= 1'b0;
    end

endmodule

`default_nettype wire
