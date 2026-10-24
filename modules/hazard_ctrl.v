////////////////////////////////////////////////////////////
// Hazard Controller
//
// Responsibilities:
// 1. Freeze the pipeline during a data-memory wait.
// 2. Hold execution during a multi-cycle MUL/DIV operation.
// 3. Insert a bubble into the EX-to-WB path when EX is held.
// 4. Flush the front end after a taken branch or jump.
// 5. Freeze the pipeline while the instruction-memory output
//    is not valid.
//
// All control signals are active-high.
// Reset is synchronous and active-high.
////////////////////////////////////////////////////////////

module hazard_ctrl (
    input  wire clk,
    input  wire reset,

    // External stall, e.g. shared-cache arbitration
    input  wire external_stall_i,

    // Instruction-memory interface
    input  wire icache_valid_i,

    // Data-memory interface
    input  wire dmem_req_i,
    input  wire dmem_ready_i,

    // Multi-cycle execution
    input  wire md_wait_i,

    // Control-flow resolution
    input  wire branch_taken_i,

    // Pipeline controls
    output reg  freeze_all_o,
    output reg  hold_ex_o,
    output reg  bubble_ex_o,
    output reg  flush_if_o
);

    ////////////////////////////////////////////////////////////
    // Combinational Hazard Detection
    ////////////////////////////////////////////////////////////

    always @(*) begin

        // Safe defaults
        freeze_all_o = 1'b0;
        hold_ex_o    = 1'b0;
        bubble_ex_o  = 1'b0;
        flush_if_o   = 1'b0;

        if (!reset) begin

            // FIX: The original code declared icache_valid_i
            // but ignored it. That allowed the controller to
            // report no stall while instruction data was invalid.
            // Freeze pipeline progress until the instruction
            // memory supplies valid data.
            if (!icache_valid_i)
                freeze_all_o = 1'b1;

            // A pending data request blocks pipeline progress.
            if (dmem_req_i && !dmem_ready_i)
                freeze_all_o = 1'b1;

            // External arbitration can also stall this core.
            if (external_stall_i)
                freeze_all_o = 1'b1;

            // A multi-cycle operation must remain in EX
            // until its result is ready.
            if (md_wait_i) begin
                hold_ex_o   = 1'b1;
                bubble_ex_o = 1'b1;
            end

            // Redirect the front end after a taken branch.
            if (branch_taken_i)
                flush_if_o = 1'b1;

        end
    end

    // This controller is combinational; no state requires reset.

endmodule