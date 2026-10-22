`timescale 1ns / 1ps
`default_nettype none

// =============================================================================
// Hybrid Tree pseudo-LRU for a 4-way set-associative cache
// 
// Features:
// - Parameterized sizes (NUM_SETS, INDEX_BITS)
// - Decoupled read (set) and write (upd_set) ports for pipelining without stalls
// - way_mask support (0000 defaults to all ways enabled; disabled ways are bypassed)
// - Safe synthesis using concatenated state updates and default_nettype none
// =============================================================================

module plru #(
    parameter NUM_SETS   = 64,
    parameter INDEX_BITS = 6
)(
    input  wire                   clk,
    input  wire                   rst,
    
    // --- Decoupled Read Port (Combinational) ---
    input  wire [INDEX_BITS-1:0]  set,        // Set being looked up
    input  wire [3:0]             way_mask,   // 1 = way enabled, 0 = way disabled
    output wire [1:0]             victim,     // Way to replace
    
    // --- Decoupled Write Port (Synchronous) ---
    input  wire                   upd,        // 1 = a hit or refill occurred this cycle
    input  wire [INDEX_BITS-1:0]  upd_set,    // Set to update
    input  wire [1:0]             upd_way     // Way that was just accessed
);

    // Tree memory: {b2, b1, b0} per set
    reg [2:0] bits [0:NUM_SETS-1];

    // -------------------------------------------------------------------------
    // Victim selection (Combinational)
    // -------------------------------------------------------------------------
    wire [3:0] en       = (way_mask == 4'd0) ? 4'b1111 : way_mask;
    wire       left_ok  = en[0] || en[1];
    wire       right_ok = en[2] || en[3];
    wire [2:0] b        = bits[set];

    // Follow b0 unless that side is entirely disabled
    wire       right = b[0] ? right_ok : !left_ok;
    wire [1:0] leaf  = right ? {1'b1, b[2]} : {1'b0, b[1]};
    
    // Pick the chosen leaf if enabled, otherwise fallback to its sibling
    assign victim = en[leaf] ? leaf : {leaf[1], ~leaf[0]};

    // -------------------------------------------------------------------------
    // Tree update (Synchronous)
    // -------------------------------------------------------------------------
    integer i;
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < NUM_SETS; i = i + 1) begin
                bits[i] <= 3'b000;
            end
        end else if (upd) begin
            // Point away from the accessed way using concatenation for clean synthesis
            if (!upd_way[1]) 
                bits[upd_set] <= {bits[upd_set][2], ~upd_way[0], 1'b1};
            else             
                bits[upd_set] <= {~upd_way[0], bits[upd_set][1], 1'b0};
        end
    end

endmodule

`default_nettype wire