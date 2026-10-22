`timescale 1ns / 1ps
`default_nettype none

// =============================================================================
// FIFO Replacement Policy for 2-Way Set-Associative I-Cache
// 
// Features:
// - Parameterized for easy resizing.
// - 1-bit pointer per set (0 = Way 0, 1 = Way 1).
// - Decoupled read (set) and write (fill_set) ports for 0-stall pipelining.
// - 2-bit way_mask support to gracefully bypass defective or locked ways.
// =============================================================================

module fifo #(
    parameter NUM_SETS   = 64,
    parameter INDEX_BITS = 6
)(
    input  wire                   clk,
    input  wire                   rst,
    
    // --- Decoupled Read Port (Combinational) ---
    input  wire [INDEX_BITS-1:0]  set,        // Set being looked up
    input  wire [1:0]             way_mask,   // 2-bit mask for 2-way cache
    output wire                   victim,     // 1-bit output (Way 0 or Way 1)
    
    // --- Decoupled Write Port (Synchronous) ---
    input  wire                   fill,       // 1 = a line was filled this cycle
    input  wire [INDEX_BITS-1:0]  fill_set,   // Set that was filled
    input  wire                   fill_way    // Way that was filled
);

    // FIFO pointer memory: 1 bit per set (points to the oldest way)
    reg ptr [0:NUM_SETS-1];

    // -------------------------------------------------------------------------
    // Victim selection (Combinational)
    // -------------------------------------------------------------------------
    // Safety fallback: if mask is 00, assume both ways are enabled (11)
    wire [1:0] en = (way_mask == 2'b00) ? 2'b11 : way_mask;
    
    // Current pointer for the requested set
    wire p = ptr[set];
    
    // Pick the pointer's way if it is enabled. Otherwise, pick the opposite way.
    assign victim = en[p] ? p : ~p;

    // -------------------------------------------------------------------------
    // FIFO Update (Synchronous)
    // -------------------------------------------------------------------------
    integer i;
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < NUM_SETS; i = i + 1) begin
                ptr[i] <= 1'b0;
            end
        end else if (fill) begin
            // FIFO rules: move the pointer to the OTHER way (~fill_way),
            // UNLESS that other way is disabled by the mask.
            if (en[~fill_way]) 
                ptr[fill_set] <= ~fill_way;
            else
                ptr[fill_set] <= fill_way; 
        end
    end

endmodule

`default_nettype wire