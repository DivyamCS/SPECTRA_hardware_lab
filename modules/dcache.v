`timescale 1ns / 1ps
`default_nettype none

// =============================================================================
// Step 1: Migrate ports to IF-B burst signals and infer physical Block RAM
// =============================================================================
module dcache (
    input  wire        clk,
    input  wire        rst,
    input  wire        cache_en,

    // IF-A slave interface
    input  wire        req,
    input  wire        we,
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    input  wire [3:0]  be,
    input  wire        owner,
    output wire [31:0] rdata,
    output wire        ready,

    // IF-B master streaming burst interface
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

    output wire        hit_pulse,
    output wire        miss_pulse,
    output wire        owner_pulse
);

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
    wire [7:0]  in_idx   = addr[9:2];

    // Tags & status tracking
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
    wire       hit     = |way_hit;
    wire [1:0] hit_way = way_hit[0] ? 2'd0 : way_hit[1] ? 2'd1 : way_hit[2] ? 2'd2 : 2'd3;

    // Data RAM arrays (inferred as synchronous Block RAM)
    reg [7:0] data_idx;
    wire [31:0] data_q [0:3];
    generate
        for (g = 0; g < 4; g = g + 1) begin : gen_way
            (* ram_style = "block" *) reg [31:0] data_mem [0:255];
            reg [31:0] q;
            always @(posedge clk) begin
                q <= data_mem[data_idx];
            end
            assign data_q[g] = q;
        end
    endgenerate

    // Tag RAM arrays (inferred as synchronous Block RAM)
    generate
        for (g = 0; g < 4; g = g + 1) begin : gen_tag
            (* ram_style = "block" *) reg [21:0] tag_mem [0:63];
            reg [21:0] tq;
            always @(posedge clk) begin
                if (state == 3'd0) tq <= tag_mem[in_idx[7:2]];
            end
            assign tag_q[g] = tq;
        end
    endgenerate

    assign ready       = 1'b0;
    assign rdata       = data_q[hit_way];
    assign hit_pulse   = 1'b0;
    assign miss_pulse  = 1'b0;
    assign owner_pulse = owner_reg;

    assign m_start  = 1'b0;
    assign m_we     = 1'b0;
    assign m_nwords = 1'b1;
    assign m_addr   = 30'd0;
    assign m_wdata  = 32'd0;
    assign m_be     = 4'b1111;

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            state <= 3'd0;
            for (i = 0; i < 64; i = i + 1) begin
                valid[i] <= 4'd0;
                dirty[i] <= 4'd0;
            end
        end
    end

endmodule
`default_nettype wire