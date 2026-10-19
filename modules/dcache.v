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
    output reg  [DATA_WIDTH-1:0]  rdata,      // Load data to core
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

    wire hit  = req && (|way_match);
    wire miss = req && (!hit);

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
    // Arbiter Lock: Bus held while FSM is servicing a miss or bypass access
    // -------------------------------------------------------------------------
    assign busy = (req && !ready);

endmodule