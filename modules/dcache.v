`timescale 1ns / 1ps

// =============================================================================
// 4-way set-associative, write-back / write-allocate data cache
//   - 64 sets, 16-byte lines, tree-PLRU replacement
//   - Variable-latency main memory through a mem_req / mem_ready handshake
//   - cache_en = 0 -> uncached bypass (line read, and read-modify-write for stores)
//
// Memory-side protocol assumed:
//   * mem_req is held high until the memory answers with a mem_ready pulse.
//   * mem_ready is only meaningful while mem_req = 1. mem_rdata is sampled on
//     the cycle mem_ready = 1 (it does not have to stay valid afterwards).
//   * mem_req is dropped for at least one cycle between two transactions.
//
// Core-side protocol:
//   * The core holds re/we/addr/wdata/wstrb until it sees ready = 1.
//   * ready is a one-cycle registered pulse; rdata is valid in that cycle.
//   * busy = 1 stalls the arbiter until the access completes.
// =============================================================================
module dcached #(
    parameter ADDR_WIDTH            = 32,   // total 32 bit address
    parameter DATA_WIDTH            = 32,
    parameter LINE_SIZE_BYTES       = 16,
    parameter NUM_WAYS              = 4,
    parameter NUM_SETS              = 64,   
    parameter BLOCK_OFFSET_BITS     = 4,    // 16 bytes (lsb)
    parameter INDEX_BITS            = 6,    // 64 sets
    parameter TAG_BITS              = 22    // 32-10 (msb)
)(
    input  wire                   clk,
    input  wire                   rst,

    // =========================================================================
    // 1. Core / Arbiter Memory Bus Interface
    // =========================================================================
    input  wire                   re,         // Read enable (LW, LH, LB)
    input  wire                   we,         // Write enable (SW, SH, SB)
    input  wire [ADDR_WIDTH-1:0]  addr,       // 32-bit physical address
    input  wire [DATA_WIDTH-1:0]  wdata,      // Store data from core
    input  wire [3:0]             wstrb,      // Byte enable mask
    output wire [DATA_WIDTH-1:0]  rdata,      // Load data to core
    output reg                    ready,      // Single-cycle acknowledge pulse
    output wire                   busy,       // Locks Arbiter during misses/refills

    // =========================================================================
    // 2. Main Memory (DMEM / mem_delay) Interface
    // =========================================================================
    output reg                    mem_req,    // Memory access request
    output reg                    mem_we,     // 0 = Read refill, 1 = Dirty eviction / bypass store
    output reg  [ADDR_WIDTH-1:0]  mem_addr,   // 16-byte aligned base address
    output reg  [127:0]           mem_wdata,  // 128-bit dirty block written back
    input  wire [127:0]           mem_rdata,  // 128-bit new block read from memory
    input  wire                   mem_ready,  // Memory completed the current request

    // =========================================================================
    // 3. Configuration & Performance Telemetry
    // =========================================================================
    input  wire                   cache_en,   // Slide switch: 1 = Cache ON, 0 = Bypass
    output reg                    hit_pulse,  // 1-cycle pulse to MMIO counter on hits
    output reg                    miss_pulse  // 1-cycle pulse to MMIO counter on misses
);

    // Memory read/write request from CPU
    wire req = (re | we);

    // -------------------------------------------------------------------------
    // Address Field Decomposition
    // -------------------------------------------------------------------------
    wire [TAG_BITS-1:0]          addr_tag    = addr[31:10];                 
    wire [INDEX_BITS-1:0]        addr_index  = addr[9:4];                   
    wire [BLOCK_OFFSET_BITS-1:0] addr_offset = addr[3:0];                   
    wire [1:0]                   word_select = addr[3:2];                   // Word 0, 1, 2, or 3 in line

    // -------------------------------------------------------------------------
    // Status Arrays: Valid & Dirty Bits (4 Ways x 64 Sets)
    // -------------------------------------------------------------------------
    reg valid [0:NUM_WAYS-1][0:NUM_SETS-1];                                 
    reg dirty [0:NUM_WAYS-1][0:NUM_SETS-1];                                 

    // -------------------------------------------------------------------------
    // Tag Arrays: 4 Ways x 64 Sets (22-bit Tag per entry)
    // Data Arrays: 4 Ways x 64 Sets (128-bit / 16-byte Line per entry)
    // -------------------------------------------------------------------------

    // -------------------------------------------------------------------------
    // Read Stage: Retrieve Tags and Data for the Indexed Set
    // -------------------------------------------------------------------------
    wire [TAG_BITS-1:0] way_tags  [0:NUM_WAYS-1];
    wire [127:0]        way_data  [0:NUM_WAYS-1];
    wire                way_valid [0:NUM_WAYS-1];
    wire                way_dirty [0:NUM_WAYS-1];

    // -------------------------------------------------------------------------
    // Parallel Way Read (Elaboration-Time Unrolling):
    // The 'generate' block acts as a compile-time macro rather than a sequential 
    // runtime loop: it instructs the synthesis tool (Vivado) to physically duplicate 
    // the read wiring for all 4 ways in parallel. This drives the tag, data, valid, 
    // and dirty bits of Way 0 through Way 3 concurrently into our tag comparators 
    // for single-cycle hit/miss evaluation.
    // -------------------------------------------------------------------------
    // -------------------------------------------------------------------------
    // Shared write port into the per-way RAMs (assigned further down, once hit,
    // hit_way and the merged lines exist). A store hit and a line install can
    // never happen in the same cycle, so one write port per way is enough.
    // -------------------------------------------------------------------------
    wire                  wr_data_en;
    wire                  wr_tag_en;
    wire [1:0]            wr_way;
    wire [INDEX_BITS-1:0] wr_idx;
    wire [127:0]          wr_data;
    wire [TAG_BITS-1:0]   wr_tag;

    genvar w;
    generate
        for (w = 0; w < NUM_WAYS; w = w + 1) begin : gen_way_reads
            // One 2-D array per way, one write port, async read -> Vivado infers
            // distributed (LUT) RAM. No reset on purpose: valid[] gates every read.
            (* ram_style = "distributed" *) reg [TAG_BITS-1:0] tag_mem  [0:NUM_SETS-1];
            (* ram_style = "distributed" *) reg [127:0]        data_mem [0:NUM_SETS-1];

            always @(posedge clk) begin
                if (wr_data_en && (wr_way == w)) data_mem[wr_idx] <= wr_data;
                if (wr_tag_en  && (wr_way == w)) tag_mem[wr_idx]  <= wr_tag;
            end

            assign way_tags[w]  = tag_mem[addr_index];
            assign way_data[w]  = data_mem[addr_index];
            assign way_valid[w] = valid[w][addr_index];
            assign way_dirty[w] = dirty[w][addr_index];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Parallel Tag Comparison (Evaluated simultaneously across all 4 ways)
    // -------------------------------------------------------------------------
    wire [NUM_WAYS-1:0] way_match;
    assign way_match[0] = way_valid[0] && (way_tags[0] == addr_tag);
    assign way_match[1] = way_valid[1] && (way_tags[1] == addr_tag);
    assign way_match[2] = way_valid[2] && (way_tags[2] == addr_tag);
    assign way_match[3] = way_valid[3] && (way_tags[3] == addr_tag);

    // Note: hit only occurs while IDLE to prevent false hit pulses mid-refill
    localparam [2:0] STATE_IDLE       = 3'd0;
    localparam [2:0] STATE_WRITE_BACK = 3'd1;  // waiting for dirty-victim write ack
    localparam [2:0] STATE_REFILL     = 3'd2;  // waiting for line read data
    localparam [2:0] STATE_UPDATE     = 3'd3;  // install line into the arrays
    localparam [2:0] STATE_GAP        = 3'd4;  // mem_req low for one cycle between transactions
    localparam [2:0] STATE_BYP_RD     = 3'd5;  // bypass: line read
    localparam [2:0] STATE_BYP_WR     = 3'd6;  // bypass store: line write-back

    reg [2:0] state;

    // A new request is only looked up in IDLE and never in the cycle where
    // ready = 1. That cycle is the completion cycle of the previous access, in
    // which the core is still presenting the same request on the bus. Looking
    // it up again would double-count hit/miss pulses, re-update the PLRU and
    // raise a spurious ready for whatever request comes next.
    wire lookup     = (state == STATE_IDLE) && req && !ready;
    wire hit        = lookup && cache_en && (|way_match);
    wire miss       = lookup && cache_en && !(|way_match);
    wire bypass_req = lookup && !cache_en;

    // Encode matching way index (00, 01, 10, or 11)
    reg [1:0] hit_way;
    always @(*) begin
        case (way_match)
            4'b0001: hit_way = 2'd0;
            4'b0010: hit_way = 2'd1;
            4'b0100: hit_way = 2'd2;
            4'b1000: hit_way = 2'd3;
            default: hit_way = 2'd0;
        endcase
    end

    // -------------------------------------------------------------------------
    // Tree-PLRU Replacement Instantiation
    // -------------------------------------------------------------------------
    wire [1:0] plru_victim_way;
    reg        plru_refill_update;
    wire       plru_access_en = hit || plru_refill_update;

    // Latched registers to protect against CPU address wobble during stalls
    reg [ADDR_WIDTH-1:0] req_addr_reg;
    reg [DATA_WIDTH-1:0] req_wdata_reg;
    reg [3:0]            req_wstrb_reg;
    reg                  req_we_reg;
    reg                  req_byp_reg;      // 1 = this request is an uncached bypass access
    reg [1:0]            victim_way_reg;
    reg [127:0]          refill_data_reg;  // line captured when memory acknowledges a read
    reg                  rf_fwd_q;         // ready cycle after a miss: serve rdata from refill_data_reg

    wire [INDEX_BITS-1:0] req_index = req_addr_reg[9:4];
    wire [TAG_BITS-1:0]   req_tag   = req_addr_reg[31:10];

    wire [1:0]            plru_access_way = plru_refill_update ? victim_way_reg : hit_way;
    wire [INDEX_BITS-1:0] plru_set_idx    = plru_refill_update ? req_index      : addr_index;

    plru u_plru (
        .clk         (clk),
        .rst         (rst),
        .set_idx     (plru_set_idx),
        .access_valid(plru_access_en),
        .access_way  (plru_access_way),
        .victim_way  (plru_victim_way)
    );

    // Victim line metadata for dirty eviction
    wire         victim_dirty    = way_dirty[plru_victim_way];
    wire         victim_valid    = way_valid[plru_victim_way];
    wire [21:0]  victim_tag      = way_tags[plru_victim_way];
    wire [127:0] victim_data     = way_data[plru_victim_way];
    wire [31:0]  victim_mem_addr = {victim_tag, addr_index, 4'b0000};

    // -------------------------------------------------------------------------
    // Load data mux
    // FIX: in STATE_UPDATE, and in the ready cycle after a miss, data comes from the
    // captured line (refill_data_reg), not from the arrays and not from mem_rdata.
    // -------------------------------------------------------------------------
    wire [127:0] selected_hit_line = way_data[hit_way];
    wire         use_rf            = (state == STATE_UPDATE) || rf_fwd_q;
    wire [127:0] active_line       = use_rf ? refill_data_reg : selected_hit_line;
    wire [1:0]   active_word_sel   = use_rf ? req_addr_reg[3:2] : word_select;

    assign rdata = active_line[{active_word_sel, 5'b00000} +: 32];

    // -------------------------------------------------------------------------
    // Arbiter Lock: Bus held while FSM is servicing a miss or bypass access
    // -------------------------------------------------------------------------
    assign busy = (state != STATE_IDLE) || (req && !ready);

    // -------------------------------------------------------------------------
    // Byte-enable merge of one 32-bit word into a 128-bit line
    // -------------------------------------------------------------------------
    function [127:0] merge_line;
        input [127:0] line;
        input [1:0]   wsel;
        input [31:0]  data;
        input [3:0]   strb;
        reg   [127:0] r;
        reg   [31:0]  wd;
        begin
            r  = line;
            wd = line[{wsel, 5'b00000} +: 32];
            if (strb[0]) wd[7:0]   = data[7:0];
            if (strb[1]) wd[15:8]  = data[15:8];
            if (strb[2]) wd[23:16] = data[23:16];
            if (strb[3]) wd[31:24] = data[31:24];
            r[{wsel, 5'b00000} +: 32] = wd;
            merge_line = r;
        end
    endfunction


    // Store hit: merge into the live cache line using live core signals
    wire [127:0] updated_hit_line  = merge_line(selected_hit_line, word_select, wdata, wstrb);

    // Store miss / bypass store: merge into the captured memory line using latched signals
    wire [127:0] updated_refill_line = merge_line(refill_data_reg, req_addr_reg[3:2],
                                                  req_wdata_reg, req_wstrb_reg);

    // Write-port drive: line install (STATE_UPDATE) or store hit
    wire upd_now = (state == STATE_UPDATE);
    assign wr_data_en = upd_now | (hit & we);
    assign wr_tag_en  = upd_now;
    assign wr_way     = upd_now ? victim_way_reg : hit_way;
    assign wr_idx     = upd_now ? req_index      : addr_index;
    assign wr_tag     = req_tag;
    assign wr_data    = upd_now ? (req_we_reg ? updated_refill_line : refill_data_reg)
                                : updated_hit_line;

    // -------------------------------------------------------------------------
    // Cache Controller FSM (mem_ready handshake)
    // -------------------------------------------------------------------------
    integer set_i, way_i;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state              <= STATE_IDLE;
            ready              <= 1'b0;
            mem_req            <= 1'b0;
            mem_we             <= 1'b0;
            mem_addr           <= 32'b0;
            mem_wdata          <= 128'b0;
            hit_pulse          <= 1'b0;
            miss_pulse         <= 1'b0;
            plru_refill_update <= 1'b0;
            req_addr_reg       <= 32'b0;
            req_wdata_reg      <= 32'b0;
            req_wstrb_reg      <= 4'b0;
            req_we_reg         <= 1'b0;
            req_byp_reg        <= 1'b0;
            victim_way_reg     <= 2'b0;
            refill_data_reg    <= 128'b0;
            rf_fwd_q           <= 1'b0;

            for (way_i = 0; way_i < NUM_WAYS; way_i = way_i + 1) begin
                for (set_i = 0; set_i < NUM_SETS; set_i = set_i + 1) begin
                    valid[way_i][set_i] <= 1'b0;
                    dirty[way_i][set_i] <= 1'b0;
                end
            end
        end else begin
            ready              <= 1'b0;
            hit_pulse          <= 1'b0;
            miss_pulse         <= 1'b0;
            plru_refill_update <= 1'b0;
            rf_fwd_q           <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    if (hit) begin
                        ready     <= 1'b1;
                        hit_pulse <= 1'b1;
                        if (we) begin
                            dirty[hit_way][addr_index]      <= 1'b1;
                        end
                    end else if (miss) begin
                        // Freeze request attributes
                        miss_pulse     <= 1'b1;
                        req_addr_reg   <= addr;
                        req_wdata_reg  <= wdata;
                        req_wstrb_reg  <= wstrb;
                        req_we_reg     <= we;
                        req_byp_reg    <= 1'b0;
                        victim_way_reg <= plru_victim_way;

                        if (victim_valid && victim_dirty) begin
                            mem_req   <= 1'b1;
                            mem_we    <= 1'b1;
                            mem_addr  <= victim_mem_addr;
                            mem_wdata <= victim_data;
                            state     <= STATE_WRITE_BACK;
                        end else begin
                            mem_req   <= 1'b1;
                            mem_we    <= 1'b0;
                            mem_addr  <= {addr[31:4], 4'b0000};
                            state     <= STATE_REFILL;
                        end
                    end else if (bypass_req) begin
                        // Uncached access: always fetch the line first
                        // (needed for loads; for stores it is the read half of a RMW)
                        req_addr_reg  <= addr;
                        req_wdata_reg <= wdata;
                        req_wstrb_reg <= wstrb;
                        req_we_reg    <= we;
                        req_byp_reg   <= 1'b1;
                        mem_req       <= 1'b1;
                        mem_we        <= 1'b0;
                        mem_addr      <= {addr[31:4], 4'b0000};
                        state         <= STATE_BYP_RD;
                    end
                end

                STATE_WRITE_BACK: begin
                    if (mem_ready) begin
                        mem_req <= 1'b0;
                        mem_we  <= 1'b0;
                        state   <= STATE_GAP;
                    end
                end

                STATE_GAP: begin
                    mem_req  <= 1'b1;
                    mem_addr <= {req_addr_reg[31:4], 4'b0000};
                    if (req_byp_reg) begin
                        // Bypass store: write back the merged line
                        mem_we    <= 1'b1;
                        mem_wdata <= updated_refill_line;
                        state     <= STATE_BYP_WR;
                    end else begin
                        // Cache miss: refill the requested line
                        mem_we    <= 1'b0;
                        state     <= STATE_REFILL;
                    end
                end

                STATE_REFILL: begin
                    if (mem_ready) begin
                        refill_data_reg <= mem_rdata;
                        mem_req         <= 1'b0;
                        state           <= STATE_UPDATE;
                    end
                end

                STATE_UPDATE: begin
                    valid[victim_way_reg][req_index]     <= 1'b1;
                    plru_refill_update                           <= 1'b1;
                    ready                                        <= 1'b1;
                    rf_fwd_q                                     <= 1'b1;

                    if (req_we_reg) begin
                        dirty[victim_way_reg][req_index]      <= 1'b1;
                    end else begin
                        dirty[victim_way_reg][req_index]      <= 1'b0;
                    end

                    state <= STATE_IDLE;
                end
                STATE_BYP_RD: begin
                    if (mem_ready) begin
                        refill_data_reg <= mem_rdata;
                        mem_req         <= 1'b0;
                        if (req_we_reg) begin
                            state    <= STATE_GAP;
                        end else begin
                            ready    <= 1'b1;
                            rf_fwd_q <= 1'b1;
                            state    <= STATE_IDLE;
                        end
                    end
                end

                STATE_BYP_WR: begin
                    if (mem_ready) begin
                        mem_req <= 1'b0;
                        mem_we  <= 1'b0;
                        ready   <= 1'b1;
                        state   <= STATE_IDLE;
                    end
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

endmodule