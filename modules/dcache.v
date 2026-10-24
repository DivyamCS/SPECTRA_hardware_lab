`timescale 1ns / 1ps
`default_nettype none

// =============================================================================
// dcache : shared D-cache, 4 KB, 4-way, 16-byte lines, 64 sets
//          write-back / write-allocate, tree-PLRU replacement, synchronous reset
//
// IF-A slave (towards the arbiter / addr_decode) and IF-B master (towards mem_delay).
// Index addr[9:4], tag addr[31:10]. Data in four 256 x 32 block RAMs (one per way,
// byte-write); tags in four 64 x 22 block RAMs; valid and dirty in flip-flops.
// On a miss the lowest invalid way is filled first, otherwise the PLRU victim is used.
// cache_en = 0 : every access is a 1-word burst straight to memory (bypass).
// cache_en may only change together with a reset (a dirty line would go stale otherwise).
// =============================================================================
module dcache (
    input  wire        clk,
    input  wire        rst,
    input  wire        cache_en,       // 1 = cache on, 0 = bypass

    // IF-A slave
    input  wire        req,
    input  wire        we,
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    input  wire [3:0]  be,
    input  wire        owner,
    output wire [31:0] rdata,
    output wire        ready,

    // IF-B master (to mem_delay)
    output wire        m_start,
    output wire        m_we,
    output wire [29:0] m_addr,
    output wire        m_nwords,       // 0 = 1 word, 1 = 4 words
    output wire [31:0] m_wdata,
    output wire [3:0]  m_be,
    input  wire        m_rvalid,
    input  wire [31:0] m_rdata,
    input  wire        m_wready,
    input  wire        m_done,

    // counter events
    output wire        hit_pulse,
    output wire        miss_pulse,
    output wire        owner_pulse
);

    localparam [2:0] STATE_IDLE      = 3'd0,
                     STATE_LOOKUP    = 3'd1,
                     STATE_WRITEBACK = 3'd2,
                     STATE_REFILL_GO = 3'd3,
                     STATE_REFILL    = 3'd4,
                     STATE_BYPASS    = 3'd5,
                     STATE_RESP      = 3'd6;

    reg  [2:0]  state;
    reg         we_reg, owner_reg;
    reg  [31:0] addr_reg, wdata_reg, rdata_reg;
    reg  [3:0]  be_reg;
    reg  [1:0]  victim_way_reg;
    reg  [21:0] victim_tag_reg;
    reg  [1:0]  wb_cnt, rf_cnt;

    wire [5:0]  set_idx  = addr_reg[9:4];
    wire [1:0]  word_idx = addr_reg[3:2];
    wire [21:0] tag_in   = addr_reg[31:10];
    wire in_lookup       = (state == STATE_LOOKUP);

    wire [21:0] tag_q [0:3];
    reg  [3:0]  valid [0:63];
    reg  [3:0]  dirty [0:63];

    wire [3:0]  valid_set = valid[set_idx];
    wire [3:0]  dirty_set = dirty[set_idx];
    wire [3:0]  way_hit;
    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : gen_cmp
            assign way_hit[g] = valid_set[g] && (tag_q[g] == tag_in);
        end
    endgenerate
    wire        hit     = |way_hit;
    wire [1:0]  hit_way = way_hit[0] ? 2'd0 : way_hit[1] ? 2'd1 : way_hit[2] ? 2'd2 : 2'd3;

    wire [3:0]  free_way     = ~valid_set;
    wire [1:0]  plru_victim;
    wire [1:0]  victim_way   = free_way[0] ? 2'd0 : free_way[1] ? 2'd1 : free_way[2] ? 2'd2 :
                               free_way[3] ? 2'd3 : plru_victim;
    wire        victim_dirty = valid_set[victim_way] && dirty_set[victim_way];

    wire refill_end = (state == STATE_REFILL) && m_done;
    wire cache_hit  = in_lookup && cache_en && hit;
    wire allocate   = in_lookup && cache_en && !hit;

    //new wires for updated plru instantiation
    wire        plru_upd     = cache_hit || refill_end;
    wire [5:0]  plru_upd_set = set_idx;
    wire [1:0]  plru_upd_way = cache_hit ? hit_way : victim_way_reg;

    plru #(
        .NUM_SETS(64),
        .INDEX_BITS(6)
    ) u_plru (
        .clk      (clk),
        .rst      (rst),
        // Read port: queried during LOOKUP
        .set      (set_idx),
        .way_mask (4'b1111),       // All 4 ways enabled
        .victim   (plru_victim),
        // Write port: updated on a hit or when refill ends
        .upd      (plru_upd),
        .upd_set  (plru_upd_set),
        .upd_way  (plru_upd_way)
    );

    wire [7:0]  in_idx  = addr[9:2];
    wire [1:0]  wb_word = wb_cnt + {1'b0, m_wready};
    reg  [7:0]  data_idx;
    always @(*) begin
        case (state)
            STATE_IDLE:      data_idx = in_idx;
            STATE_LOOKUP:    data_idx = (cache_en && hit) ? addr_reg[9:2] : {set_idx, 2'd0};
            STATE_WRITEBACK: data_idx = {set_idx, wb_word};
            default:         data_idx = {set_idx, rf_cnt};
        endcase
    end

    wire [31:0] byte_mask = {{8{be_reg[3]}}, {8{be_reg[2]}}, {8{be_reg[1]}}, {8{be_reg[0]}}};
    wire        fill_is_req_word = (rf_cnt == word_idx);
    wire [31:0] fill_data = (we_reg && fill_is_req_word) ? ((m_rdata & ~byte_mask) | (wdata_reg & byte_mask))
                                                         : m_rdata;
    wire        store_hit_wr = cache_hit && we_reg;
    wire        fill_wr      = (state == STATE_REFILL) && m_rvalid;

    wire [31:0] data_q [0:3];
    generate
        for (g = 0; g < 4; g = g + 1) begin : gen_way
            (* ram_style = "block" *) reg [31:0] data_mem [0:255];
            reg  [31:0] q;
            wire        wr  = (store_hit_wr && hit_way == g) || (fill_wr && victim_way_reg == g);
            wire [3:0]  wbe = fill_wr ? 4'b1111 : be_reg;
            wire [31:0] wd  = fill_wr ? fill_data : wdata_reg;
            always @(posedge clk) begin
                if (wr) begin
                    if (wbe[0]) data_mem[data_idx][ 7: 0] <= wd[ 7: 0];
                    if (wbe[1]) data_mem[data_idx][15: 8] <= wd[15: 8];
                    if (wbe[2]) data_mem[data_idx][23:16] <= wd[23:16];
                    if (wbe[3]) data_mem[data_idx][31:24] <= wd[31:24];
                end
                q <= data_mem[data_idx];
            end
            assign data_q[g] = q;
        end
    endgenerate

    generate
        for (g = 0; g < 4; g = g + 1) begin : gen_tag
            (* ram_style = "block" *) reg [21:0] tag_mem [0:63];
            reg [21:0] tq;
            always @(posedge clk) begin
                if (refill_end && victim_way_reg == g) tag_mem[set_idx] <= tag_in;
                if (state == STATE_IDLE) tq <= tag_mem[in_idx[7:2]];
            end
            assign tag_q[g] = tq;
        end
    endgenerate

    wire [21:0] victim_tag_now = in_lookup ? tag_q[victim_way] : victim_tag_reg;

    wire start_wb     = allocate && victim_dirty;
    wire start_refill = (allocate && !victim_dirty) || (state == STATE_REFILL_GO);
    wire start_single = in_lookup && !cache_en;

    assign m_start  = start_wb || start_refill || start_single;
    assign m_we     = (start_wb || state == STATE_WRITEBACK) ? 1'b1 :
                      (start_refill || state == STATE_REFILL) ? 1'b0 : we_reg;
    assign m_nwords = !(start_single || state == STATE_BYPASS);
    assign m_addr   = (start_wb || state == STATE_WRITEBACK) ? {victim_tag_now, set_idx, 2'b00} :
                      (start_refill || state == STATE_REFILL) ? {addr_reg[31:4], 2'b00} : addr_reg[31:2];
    assign m_wdata  = (state == STATE_WRITEBACK) ? data_q[victim_way_reg] : wdata_reg;
    assign m_be     = (state == STATE_WRITEBACK) ? 4'b1111 : be_reg;

    assign ready       = cache_hit || (state == STATE_RESP);
    assign rdata       = (state == STATE_RESP) ? rdata_reg : data_q[hit_way];
    assign hit_pulse   = in_lookup && cache_en && hit;
    assign miss_pulse  = in_lookup && cache_en && !hit;
    assign owner_pulse = owner_reg;

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            state <= STATE_IDLE;
            for (i = 0; i < 64; i = i + 1) begin
                valid[i] <= 4'd0;
                dirty[i] <= 4'd0;
            end
        end else begin
            case (state)
                STATE_IDLE: if (req) begin
                    state <= STATE_LOOKUP;
                    addr_reg <= addr; we_reg <= we; wdata_reg <= wdata; be_reg <= be; owner_reg <= owner;
                end
                STATE_LOOKUP: begin
                    wb_cnt <= 2'd0; rf_cnt <= 2'd0;
                    victim_way_reg <= victim_way; victim_tag_reg <= tag_q[victim_way];
                    if (cache_hit) begin
                        state <= STATE_IDLE;
                        if (we_reg) dirty[set_idx][hit_way] <= 1'b1;
                    end else if (start_wb) begin
                        state <= STATE_WRITEBACK;
                    end else if (allocate) begin
                        state <= STATE_REFILL;
                    end else begin
                        state <= STATE_BYPASS;
                    end
                end
                STATE_WRITEBACK: begin
                    if (m_wready) wb_cnt <= wb_cnt + 2'd1;
                    if (m_done) state <= STATE_REFILL_GO;
                end
                STATE_REFILL_GO: state <= STATE_REFILL;
                STATE_REFILL: begin
                    if (m_rvalid) begin
                        rf_cnt <= rf_cnt + 2'd1;
                        if (fill_is_req_word) rdata_reg <= m_rdata;
                    end
                    if (m_done) begin
                        state <= STATE_RESP;
                        valid[set_idx][victim_way_reg] <= 1'b1;
                        dirty[set_idx][victim_way_reg] <= we_reg;
                    end
                end
                STATE_BYPASS: begin
                    if (m_rvalid) rdata_reg <= m_rdata;
                    if (m_done) state <= STATE_RESP;
                end
                STATE_RESP: state <= STATE_IDLE;
                default:    state <= STATE_IDLE;
            endcase
        end
    end

endmodule
`default_nettype wire