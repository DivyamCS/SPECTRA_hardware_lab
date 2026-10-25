`timescale 1ns / 1ps
`default_nettype none
// icache - private instruction cache of one core: 2 KB, 2-way, 16-byte lines, 64 sets, FIFO,
// read-only (spec: docs/spec/icache.md, PROTOCOL.md sections 6-7, tools/cache_model.py ways=2).
// Index addr[9:4], tag addr[31:10]; data in two 256 x 32 block RAMs, tags in two 64 x 22 block
// RAMs, valid bits in flip-flops, FIFO pointers in fifo. IF-B master to the core's own
// mem_delay (-> IMEM).
//
// Like a synchronous BRAM: a fetch accepted in cycle t is looked up in t + 1, and on a hit
// `fetch_ready` and `instr` come in t + 1 while the next fetch is accepted in that same cycle,
// so straight hits never stall. A miss starts a 4-word line burst in the lookup cycle and
// answers the cycle after its done: L + 4 extra cycles. With IC = 0 (or HAS_ICACHE = 0) every
// fetch is a 1-word burst: L + 1 extra; arrays untouched, no pulses. A fill goes to the lowest
// invalid way, else the FIFO victim: fifo (2 ways) keeps one pointer per
// set, moved to the other way after each fill; hits never move it (first in, first out). ic_hit / ic_miss pulse once per fetch in its lookup cycle when IC = 1.
// The core holds fetch_req and fetch_addr until fetch_ready, and asks again only for a new fetch.

module icache #(
    parameter HAS_ICACHE = 1
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        ic_en,          // cfg[7]
    input  wire        fetch_req,
    input  wire [31:0] fetch_addr,
    output wire        fetch_ready,
    output wire [31:0] instr,
    // IF-B master
    output wire        m_start,
    output wire        m_we,
    output wire [29:0] m_addr,
    output wire        m_nwords,
    output wire [31:0] m_wdata,
    output wire [3:0]  m_be,
    input  wire        m_rvalid,
    input  wire [31:0] m_rdata,
    input  wire        m_wready,
    input  wire        m_done,
    // counter events
    output wire        ic_hit,
    output wire        ic_miss
);

    localparam S_RUN = 2'd0, S_MISS = 2'd1, S_RESP = 2'd2;

    wire        on = ic_en && (HAS_ICACHE != 0);

    reg  [1:0]  state;
    reg         lk_valid;                  // a fetch was accepted last cycle: look it up now
    reg  [31:0] lk_addr;
    reg  [31:0] word_r;                    // the fetched word of a miss / IC = 0 burst
    reg         vic_r, line_r;
    reg  [1:0]  rcnt;

    wire [5:0]  lk_set  = lk_addr[9:4];
    wire [21:0] lk_tag  = lk_addr[31:10];

    reg  [1:0]  valid [0:63];
    wire [21:0] tag_q [0:1];
    wire [31:0] d_q   [0:1];

    wire [1:0]  v_set = valid[lk_set];
    wire        h0 = v_set[0] && tag_q[0] == lk_tag;
    wire        h1 = v_set[1] && tag_q[1] == lk_tag;
    wire        hit = on && (h0 || h1);
    wire        lookup = (state == S_RUN) && lk_valid;

    // accept a new fetch whenever no burst is pending: on a hit, in RESP, or when idle
    wire        accept = (state == S_RESP) || (state == S_RUN && !(lookup && !hit));
    wire        start  = lookup && !hit;
    wire        fifo_vic;
    wire        victim = !v_set[0] ? 1'b0 : !v_set[1] ? 1'b1 : fifo_vic;
    wire        refill_wr  = (state == S_MISS) && line_r && m_rvalid;
    wire        refill_end = (state == S_MISS) && line_r && m_done;

    assign fetch_ready = (lookup && hit) || (state == S_RESP);
    assign instr       = (state == S_RESP) ? word_r : (h1 ? d_q[1] : d_q[0]);
    assign ic_hit      = lookup && hit;
    assign ic_miss     = lookup && on && !hit;

    assign m_start  = start;
    assign m_we     = 1'b0;
    assign m_nwords = start ? on : line_r;
    assign m_addr   = (start ? on : line_r) ? {lk_addr[31:4], 2'b00} : lk_addr[31:2];
    assign m_wdata  = 32'd0;
    assign m_be     = 4'b1111;

    // FIFO replacement: the pointer of the set moves past the way filled, at the end of a refill
    fifo u_fifo (.clk(clk), .rst(rst), .set(lk_set), .way_mask(2'b11), .victim(fifo_vic),
                 .fill(refill_end), .fill_set(lk_set), .fill_way(vic_r));

    // arrays: read at accept with the new fetch address; written during a refill
    wire [7:0]  rd_idx = fetch_addr[9:2];
    wire [7:0]  wr_idx = {lk_set, rcnt};
    genvar g;
    generate
        for (g = 0; g < 2; g = g + 1) begin : g_way
            (* ram_style = "block" *) reg [31:0] dm [0:255];
            (* ram_style = "block" *) reg [21:0] tm [0:63];
            reg [31:0] dq;
            reg [21:0] tq;
            always @(posedge clk) begin
                if (refill_wr && vic_r == g) dm[wr_idx] <= m_rdata;
                if (accept) dq <= dm[rd_idx];
            end
            always @(posedge clk) begin
                if (refill_end && vic_r == g) tm[lk_set] <= lk_tag;
                if (accept) tq <= tm[rd_idx[7:2]];
            end
            assign d_q[g]   = dq;
            assign tag_q[g] = tq;
        end
    endgenerate

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            state <= S_RUN; lk_valid <= 1'b0;
            for (i = 0; i < 64; i = i + 1) valid[i] <= 2'b00;
        end else begin
            if (accept) begin
                lk_valid <= fetch_req;
                lk_addr  <= fetch_addr;
            end
            case (state)
                S_RUN: if (start) begin
                    state <= S_MISS; vic_r <= victim; line_r <= on; rcnt <= 2'd0;
                end
                S_MISS: begin
                    if (m_rvalid) begin
                        rcnt <= rcnt + 2'd1;
                        if (!line_r || rcnt == lk_addr[3:2]) word_r <= m_rdata;
                    end
                    if (m_done) begin
                        state <= S_RESP;
                        if (line_r) valid[lk_set][vic_r] <= 1'b1;
                    end
                end
                default: state <= S_RUN;                     // S_RESP: answered, back to RUN
            endcase
        end
    end

endmodule

`default_nettype wire
