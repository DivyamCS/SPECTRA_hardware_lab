`timescale 1ns / 1ps
`default_nettype none

//=============================================================================
// Module: perf_counters
// Description:
//   Performance counters for a run (spec: docs/spec/perf_counters.md,
//   PROTOCOL.md section 3).
//   15 x 32-bit wrapping counters: 0 = CYCLES; 
//   Per core k (at index 1 + 8k): INSTRET, D_HIT, D_MISS, I_HIT, I_MISS,
//                                 ARB_WAIT, BAR_WAIT.
//=============================================================================

module perf_counters (
    input  wire         clk,
    input  wire         rst,
    
    // Control
    input  wire         run_start,
    input  wire         run_stop,
    
    // Core Events
    input  wire [1:0]   ev_instret,
    input  wire [1:0]   ev_ihit,
    input  wire [1:0]   ev_imiss,
    input  wire [1:0]   ev_arbwait,
    input  wire [1:0]   ev_barwait,
    
    // D-Cache Events
    input  wire         ev_dhit,
    input  wire         ev_dmiss,
    input  wire         ev_downer,
    
    // Read Interface
    input  wire [3:0]   rd_sel,
    output wire [31:0]  rd_data,
    output wire [479:0] snap      // counter n at [32n +: 32], n = 0..14
);

    reg [31:0] cnt [0:15];        // index = rd_sel (8 is unused)
    reg        counting;

    //-------------------------------------------------------------------------
    // This cycle's increments
    //-------------------------------------------------------------------------
    wire [15:0] inc;
    assign inc[0] = 1'b1;         // CYCLES always increments when counting
    assign inc[8] = 1'b0;         // Unused

    genvar k;
    generate
        for (k = 0; k < 2; k = k + 1) begin : g_core
            assign inc[1 + 8*k] = ev_instret[k];
            assign inc[2 + 8*k] = ev_dhit  && (ev_downer == k);
            assign inc[3 + 8*k] = ev_dmiss && (ev_downer == k);
            assign inc[4 + 8*k] = ev_ihit[k];
            assign inc[5 + 8*k] = ev_imiss[k];
            assign inc[6 + 8*k] = ev_arbwait[k];
            assign inc[7 + 8*k] = ev_barwait[k];
        end
    endgenerate

    //-------------------------------------------------------------------------
    // Counter Logic
    //-------------------------------------------------------------------------
    integer i;
    always @(posedge clk) begin
        if (rst) begin
            counting <= 1'b0;
            for (i = 0; i < 16; i = i + 1) begin
                cnt[i] <= 32'd0;
            end
        end else if (run_start) begin
            counting <= 1'b1;
            for (i = 0; i < 16; i = i + 1) begin
                cnt[i] <= {31'd0, inc[i]};
            end
        end else begin
            if (run_stop) begin
                counting <= 1'b0;
            end
            if (counting && !run_stop) begin
                for (i = 0; i < 16; i = i + 1) begin
                    if (inc[i]) begin
                        cnt[i] <= cnt[i] + 32'd1;
                    end
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // Output Mux and Snapshot
    //-------------------------------------------------------------------------
    assign rd_data = cnt[rd_sel];

    generate
        for (k = 0; k < 15; k = k + 1) begin : g_snap
            // Skip the unused index 8 when mapping to the contiguous snap vector
            assign snap[32*k +: 32] = (k < 8) ? cnt[k] : cnt[k + 1];
        end
    endgenerate

endmodule

`default_nettype wire