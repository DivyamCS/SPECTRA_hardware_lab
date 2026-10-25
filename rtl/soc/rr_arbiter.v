`timescale 1ns / 1ps
`default_nettype none
// rr_arbiter - round-robin arbiter: two cores' IF-A data ports onto one IF-A port + owner
// (spec: docs/spec/rr_arbiter.md; reference model tools/arbiter_ref.py).
// A request on a free port is granted and forwarded in the same cycle (no extra cycle when
// uncontended). The grant is held until that request's ready; the port is free again in the
// next cycle. When both cores are waiting on a free port, the one not granted last time wins
// (core 0 wins the first tie). ready / rdata go only to the owner. ev_arbwaitN is 1 in every
// cycle core N's request waits while the port serves (or is just granted to) the other core.
//
// BARRIER (spec 1.0.1): a BARRIER read (a load from 0x2000_000C) never takes the shared port -
// held there, it would lock the other core out of reaching the barrier. It is parked instead:
// bar_req[k] goes to lock_barrier from the cycle after the request, and when lock_barrier
// raises bar_release[k] the core gets ready with rdata 0 (cycle 2 when it releases at once, as
// for any MMIO access). The other core keeps using the port meanwhile. This is rv32sim's model:
// a core at the barrier is suspended and does not occupy the data port.

module rr_arbiter (
    input  wire        clk,
    input  wire        rst,
    // IF-A slave 0 (core 0)
    input  wire        req0,
    input  wire        we0,
    input  wire [31:0] addr0,
    input  wire [31:0] wdata0,
    input  wire [3:0]  be0,
    output wire [31:0] rdata0,
    output wire        ready0,
    // IF-A slave 1 (core 1)
    input  wire        req1,
    input  wire        we1,
    input  wire [31:0] addr1,
    input  wire [31:0] wdata1,
    input  wire [3:0]  be1,
    output wire [31:0] rdata1,
    output wire        ready1,
    // IF-A master (to addr_decode)
    output wire        m_req,
    output wire        m_we,
    output wire [31:0] m_addr,
    output wire [31:0] m_wdata,
    output wire [3:0]  m_be,
    output wire        m_owner,
    input  wire [31:0] m_rdata,
    input  wire        m_ready,
    // BARRIER (to/from lock_barrier)
    output reg  [1:0]  bar_req,
    input  wire [1:0]  bar_release,
    // counter events
    output wire        ev_arbwait0,
    output wire        ev_arbwait1
);

    reg  busy, owner_r, last;

    // BARRIER reads are parked, not arbitrated
    wire bar0 = req0 && !we0 && addr0 == 32'h2000000C;
    wire bar1 = req1 && !we1 && addr1 == 32'h2000000C;
    wire rq0  = req0 && !bar0;
    wire rq1  = req1 && !bar1;
    wire bar_done0 = bar_req[0] && bar_release[0];
    wire bar_done1 = bar_req[1] && bar_release[1];

    // who has the port this cycle
    wire pick = (rq0 && rq1) ? !last : rq1;           // 0 or 1 when the port is free
    wire g    = busy ? owner_r : pick;
    wire any  = busy || rq0 || rq1;

    assign m_req   = busy ? 1'b1 : (rq0 || rq1);
    assign m_owner = g;
    assign m_we    = g ? we1    : we0;
    assign m_addr  = g ? addr1  : addr0;
    assign m_wdata = g ? wdata1 : wdata0;
    assign m_be    = g ? be1    : be0;

    assign ready0  = (m_ready && any && !g) || bar_done0;
    assign ready1  = (m_ready && any && g) || bar_done1;
    assign rdata0  = bar_done0 ? 32'd0 : m_rdata;
    assign rdata1  = bar_done1 ? 32'd0 : m_rdata;

    assign ev_arbwait0 = rq0 && any && g;
    assign ev_arbwait1 = rq1 && any && !g;

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0; owner_r <= 1'b0; last <= 1'b1; bar_req <= 2'b00;
        end else begin
            // a parked BARRIER read: pending from the cycle after it appears until its release
            bar_req[0] <= bar0 && !bar_done0;
            bar_req[1] <= bar1 && !bar_done1;
            if (!busy) begin
                if (rq0 || rq1) begin
                    last <= pick; owner_r <= pick;
                    busy <= !m_ready;                // a ready in the grant cycle ends it at once
                end
            end else if (m_ready) begin
                busy <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
