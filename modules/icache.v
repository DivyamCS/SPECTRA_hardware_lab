`timescale 1ns / 1ps
`default_nettype none
// =============================================================================
// icache - private instruction cache (one per core)
//   2 KB, 2-way set-associative, 16-byte lines (4 words), 64 sets, read-only,
//   FIFO replacement (fifo.v). addr[3:0] offset, addr[9:4] index, addr[31:10] tag.
//
// Core side (BRAM-like, 1-cycle lookup):
//   * A fetch is ACCEPTED in a cycle where fetch_accept = 1 (the core must
//     present the next address then, and may change it freely otherwise).
//   * The accepted fetch is looked up in the following cycle. On a hit,
//     fetch_ready = 1 and instr is valid in that same cycle, and the next fetch
//     is accepted in that cycle too -> back-to-back hits never stall.
//   * Anything else while lk_valid = 1 is a stall: fetch_stall = 1.
//
// Memory side : mem_req is held until mem_ready;
//   mem_rdata (128-bit line) is sampled in the mem_ready cycle; mem_req drops
//   for at least one cycle between transactions. mem_addr is line-aligned.
//
// Miss flow: RUN -> FILL (wait for mem_ready, write data+tag+valid, fifo fill)
//            -> REPLAY (re-read the arrays at the missed address) -> RUN (hit).
// ic_en = 0 (bypass): every fetch is fetched as a line from memory, the wanted
//   word is returned from a register, arrays / valid / fifo are untouched and
//   no hit/miss pulses are produced.
// =============================================================================
module icache #(
    parameter HAS_ICACHE = 1
) (
    input  wire         clk,
    input  wire         rst,          // synchronous, active high
    input  wire         ic_en,        // 1 = cache on, 0 = bypass

    // core side
    input  wire         fetch_req,
    input  wire [31:0]  fetch_addr,
    output wire         fetch_accept,
    output wire         fetch_ready,
    output wire         fetch_stall,
    output wire [31:0]  instr,

    // memory side
    output reg          mem_req,
    output wire [31:0]  mem_addr,
    input  wire [127:0] mem_rdata,
    input  wire         mem_ready,

    // performance counter events (one pulse per fetch)
    output wire         ic_hit,
    output wire         ic_miss
);

    localparam [1:0] S_RUN = 2'd0, S_FILL = 2'd1, S_REPLAY = 2'd2, S_BYP = 2'd3;

    wire on = ic_en && (HAS_ICACHE != 0);

    // ---------------- lookup-stage registers ----------------
    reg  [1:0]  state;
    reg         lk_valid;
    reg  [31:0] lk_addr;
    reg         vic_r;        // way being filled
    reg         byp_r;        // current memory transaction is a bypass fetch
    reg         rp;           // this lookup is the replay of a miss (already counted)
    reg  [31:0] word_r;       // bypass result

    wire [5:0]  lk_set = lk_addr[9:4];
    wire [21:0] lk_tag = lk_addr[31:10];
    wire [1:0]  lk_w   = lk_addr[3:2];

    // ---------------- valid bits (flip-flops) ----------------
    reg  [63:0] vld0, vld1;
    wire        v0 = vld0[lk_set];
    wire        v1 = vld1[lk_set];

    // ---------------- arrays ----------------
    wire [127:0] dq [0:1];
    wire [21:0]  tq [0:1];

    wire h0 = v0 && (tq[0] == lk_tag);
    wire h1 = v1 && (tq[1] == lk_tag);
    wire hit = on && (h0 || h1);

    wire run    = (state == S_RUN);
    wire lookup = run && lk_valid;
    wire miss   = lookup && !hit;

    // a new fetch is taken whenever nothing is pending
    assign fetch_accept = (run && !miss) || (state == S_BYP);
    assign fetch_ready  = (lookup && hit) || (state == S_BYP);
    assign fetch_stall  = lk_valid && !fetch_ready;

    // ---------------- FIFO victim selection ----------------
    wire fill_wr = (state == S_FILL) && mem_ready && !byp_r;
    wire fifo_victim;
    fifo #(.NUM_SETS(64), .INDEX_BITS(6)) u_fifo (
        .clk      (clk),
        .rst      (rst),
        .set      (lk_set),
        .way_mask (2'b11),
        .victim   (fifo_victim),
        .fill     (fill_wr),
        .fill_set (lk_set),
        .fill_way (vic_r)
    );
    wire victim = !v0 ? 1'b0 : !v1 ? 1'b1 : fifo_victim;   // free way first, else oldest

    // ---------------- data path ----------------
    wire [127:0] hit_line = h1 ? dq[1] : dq[0];
    assign instr = (state == S_BYP) ? word_r : hit_line[32*lk_w +: 32];

    assign mem_addr = {lk_addr[31:4], 4'b0000};

    wire [5:0] rd_set = (state == S_REPLAY) ? lk_set : fetch_addr[9:4];
    wire       rd_en  = fetch_accept || (state == S_REPLAY);

    genvar g;
    generate
        for (g = 0; g < 2; g = g + 1) begin : g_way
            (* ram_style = "block" *) reg [127:0] dm [0:63];
            (* ram_style = "block" *) reg [21:0]  tm [0:63];
            reg [127:0] dr;
            reg [21:0]  tr;
            always @(posedge clk) begin
                if (fill_wr && (vic_r == g)) begin
                    dm[lk_set] <= mem_rdata;
                    tm[lk_set] <= lk_tag;
                end
                if (rd_en) begin
                    dr <= dm[rd_set];
                    tr <= tm[rd_set];
                end
            end
            assign dq[g] = dr;
            assign tq[g] = tr;
        end
    endgenerate

    // ---------------- control ----------------
    always @(posedge clk) begin
        if (rst) begin
            state    <= S_RUN;
            lk_valid <= 1'b0;
            mem_req  <= 1'b0;
            rp       <= 1'b0;
            vld0     <= 64'd0;
            vld1     <= 64'd0;
        end else begin
            if (fetch_accept) begin
                lk_valid <= fetch_req;
                lk_addr  <= fetch_addr;
            end
            if (lookup) rp <= 1'b0;

            case (state)
                S_RUN: if (miss) begin
                    state   <= S_FILL;
                    vic_r   <= victim;
                    byp_r   <= !on;
                    mem_req <= 1'b1;
                end
                S_FILL: if (mem_ready) begin
                    mem_req <= 1'b0;
                    if (byp_r) begin
                        word_r <= mem_rdata[32*lk_w +: 32];
                        state  <= S_BYP;
                    end else begin
                        if (vic_r) vld1[lk_set] <= 1'b1;
                        else       vld0[lk_set] <= 1'b1;
                        state <= S_REPLAY;
                    end
                end
                S_REPLAY: begin
                    rp    <= 1'b1;
                    state <= S_RUN;
                end
                default: state <= S_RUN;      // S_BYP: answered
            endcase
        end
    end

    assign ic_hit  = lookup && hit && !rp;
    assign ic_miss = miss && on;

endmodule

`default_nettype wire
