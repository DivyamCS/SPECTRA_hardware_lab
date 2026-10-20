`timescale 1ns / 1ps

module dcache #(
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
    output reg                    mem_we,     // 0 = Read refill burst, 1 = Dirty eviction write
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
    reg [TAG_BITS-1:0] tag_array  [0:NUM_WAYS-1][0:NUM_SETS-1];            
    reg [127:0]        data_array [0:NUM_WAYS-1][0:NUM_SETS-1];            

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
    genvar w;
    generate
        for (w = 0; w < NUM_WAYS; w = w + 1) begin : gen_way_reads
            assign way_tags[w]  = tag_array[w][addr_index];
            assign way_data[w]  = data_array[w][addr_index];
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
    localparam STATE_IDLE       = 2'd0;
    localparam STATE_WRITE_BACK = 2'd1;
    localparam STATE_REFILL     = 2'd2;
    localparam STATE_UPDATE     = 2'd3;

    reg [1:0] state;

    // A new request is only looked up in IDLE and never in the cycle where
    // ready = 1. That cycle is the completion cycle of the previous access, in
    // which the core is still presenting the same request on the bus. Looking
    // it up again would double-count hit/miss pulses, re-update the PLRU and
    // raise a spurious ready for whatever request comes next.
    wire lookup = (state == STATE_IDLE) && req && !ready;
    wire hit    = lookup && cache_en && (|way_match);
    wire miss   = lookup && cache_en && !(|way_match);

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
    reg [1:0]            victim_way_reg;

    wire [1:0]            plru_access_way = plru_refill_update ? victim_way_reg : hit_way;
    wire [INDEX_BITS-1:0] plru_set_idx    = plru_refill_update ? req_addr_reg[9:4] : addr_index;

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
    // Hit Read Data Mux & Refill Bypass Mux
    // FIX 1: Provide direct data forward during STATE_UPDATE
    // -------------------------------------------------------------------------
    wire [127:0] selected_hit_line = way_data[hit_way];
    wire [1:0]   active_word_sel   = (state == STATE_UPDATE) ? req_addr_reg[3:2] : word_select;
    wire [127:0] active_line       = (state == STATE_UPDATE) ? mem_rdata : selected_hit_line;

    assign rdata = (active_word_sel == 2'b00) ? active_line[31:0]   :
                   (active_word_sel == 2'b01) ? active_line[63:32]  :
                   (active_word_sel == 2'b10) ? active_line[95:64]  :
                                                active_line[127:96];

    // -------------------------------------------------------------------------
    // Arbiter Lock: Bus held while FSM is servicing a miss or bypass access
    // -------------------------------------------------------------------------
    assign busy = (state != STATE_IDLE) || (req && !ready);

    // -------------------------------------------------------------------------
    // Write Data Merging Logic
    // -------------------------------------------------------------------------
    reg [127:0] updated_hit_line;
    always @(*) begin
        updated_hit_line = selected_hit_line;
        case (word_select)
            2'b00: begin
                if (wstrb[0]) updated_hit_line[7:0]   = wdata[7:0];
                if (wstrb[1]) updated_hit_line[15:8]  = wdata[15:8];
                if (wstrb[2]) updated_hit_line[23:16] = wdata[23:16];
                if (wstrb[3]) updated_hit_line[31:24] = wdata[31:24];
            end
            2'b01: begin
                if (wstrb[0]) updated_hit_line[39:32] = wdata[7:0];
                if (wstrb[1]) updated_hit_line[47:40] = wdata[15:8];
                if (wstrb[2]) updated_hit_line[55:48] = wdata[23:16];
                if (wstrb[3]) updated_hit_line[63:56] = wdata[31:24];
            end
            2'b10: begin
                if (wstrb[0]) updated_hit_line[71:64] = wdata[7:0];
                if (wstrb[1]) updated_hit_line[79:72] = wdata[15:8];
                if (wstrb[2]) updated_hit_line[87:80] = wdata[23:16];
                if (wstrb[3]) updated_hit_line[95:88] = wdata[31:24];
            end
            2'b11: begin
                if (wstrb[0]) updated_hit_line[103:96]  = wdata[7:0];
                if (wstrb[1]) updated_hit_line[111:104] = wdata[15:8];
                if (wstrb[2]) updated_hit_line[119:112] = wdata[23:16];
                if (wstrb[3]) updated_hit_line[127:120] = wdata[31:24];
            end
        endcase
    end

    reg [127:0] updated_refill_line;
    always @(*) begin
        updated_refill_line = mem_rdata;
        case (req_addr_reg[3:2])
            2'b00: begin
                if (req_wstrb_reg[0]) updated_refill_line[7:0]   = req_wdata_reg[7:0];
                if (req_wstrb_reg[1]) updated_refill_line[15:8]  = req_wdata_reg[15:8];
                if (req_wstrb_reg[2]) updated_refill_line[23:16] = req_wdata_reg[23:16];
                if (req_wstrb_reg[3]) updated_refill_line[31:24] = req_wdata_reg[31:24];
            end
            2'b01: begin
                if (req_wstrb_reg[0]) updated_refill_line[39:32] = req_wdata_reg[7:0];
                if (req_wstrb_reg[1]) updated_refill_line[47:40] = req_wdata_reg[15:8];
                if (req_wstrb_reg[2]) updated_refill_line[55:48] = req_wdata_reg[23:16];
                if (req_wstrb_reg[3]) updated_refill_line[63:56] = req_wdata_reg[31:24];
            end
            2'b10: begin
                if (req_wstrb_reg[0]) updated_refill_line[71:64] = req_wdata_reg[7:0];
                if (req_wstrb_reg[1]) updated_refill_line[79:72] = req_wdata_reg[15:8];
                if (req_wstrb_reg[2]) updated_refill_line[87:80] = req_wdata_reg[23:16];
                if (req_wstrb_reg[3]) updated_refill_line[95:88] = req_wdata_reg[31:24];
            end
            2'b11: begin
                if (req_wstrb_reg[0]) updated_refill_line[103:96]  = req_wdata_reg[7:0];
                if (req_wstrb_reg[1]) updated_refill_line[111:104] = req_wdata_reg[15:8];
                if (req_wstrb_reg[2]) updated_refill_line[119:112] = req_wdata_reg[23:16];
                if (req_wstrb_reg[3]) updated_refill_line[127:120] = req_wdata_reg[31:24];
            end
        endcase
    end

    // -------------------------------------------------------------------------
    // Cache Controller FSM (mem_ready handshake)
    // -------------------------------------------------------------------------
    integer set_i, way_i;

    always @(posedge clk) begin
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
            victim_way_reg     <= 2'b0;

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

            case (state)
                STATE_IDLE: begin
                    if (hit) begin
                        ready     <= 1'b1;
                        hit_pulse <= 1'b1;
                        if (we) begin
                            data_array[hit_way][addr_index] <= updated_hit_line;
                            dirty[hit_way][addr_index]      <= 1'b1;
                        end
                    end else if (miss) begin
                        // Miss detected: freeze request attributes
                        miss_pulse     <= 1'b1;
                        req_addr_reg   <= addr;
                        req_wdata_reg  <= wdata;
                        req_wstrb_reg  <= wstrb;
                        req_we_reg     <= we;
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
                    end
                end

                STATE_WRITE_BACK: begin
                    if (mem_ready) begin
                        mem_req  <= 1'b1;
                        mem_we   <= 1'b0;
                        mem_addr <= {req_addr_reg[31:4], 4'b0000};
                        state    <= STATE_REFILL;
                    end
                end

                STATE_REFILL: begin
                    if (mem_ready) begin
                        mem_req <= 1'b0;
                        state   <= STATE_UPDATE;
                    end
                end

                STATE_UPDATE: begin
                    tag_array[victim_way_reg][req_addr_reg[9:4]] <= req_addr_reg[31:10];
                    valid[victim_way_reg][req_addr_reg[9:4]]     <= 1'b1;
                    plru_refill_update                           <= 1'b1;
                    ready                                        <= 1'b1;

                    if (req_we_reg) begin
                        data_array[victim_way_reg][req_addr_reg[9:4]] <= updated_refill_line;
                        dirty[victim_way_reg][req_addr_reg[9:4]]      <= 1'b1;
                    end else begin
                        data_array[victim_way_reg][req_addr_reg[9:4]] <= mem_rdata;
                        dirty[victim_way_reg][req_addr_reg[9:4]]      <= 1'b0;
                    end

                    state <= STATE_IDLE;
                end
            endcase
        end
    end

endmodule
