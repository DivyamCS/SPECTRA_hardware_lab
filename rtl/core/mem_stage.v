`timescale 1ns / 1ps
`default_nettype none
// mem_stage - memory side of the MEM/WB stage of one SPECTRA core (spec: docs/spec/mem_stage.md).
// A valid load or store in MEM/WB presents one IF-A request (interfaces.md section 1) and holds
// it until `ready`; store lanes and byte enables, and load shift and sign/zero extension, as the
// lab's wb.v. Produces the register write and the retire pulse.
//
// The EX/MEM register (in the core wrapper) holds this stage's inputs while the pipeline is
// frozen. If `ready` comes in a cycle that is frozen for another reason (the fetch path waits),
// the access is complete but the instruction stays: the loaded word is kept and the request is
// not presented again. Register write and retire happen only in the cycle the instruction
// leaves MEM/WB (not frozen), so each instruction writes and retires exactly once.

module mem_stage (
    input  wire        clk,
    input  wire        rst,
    // EX/MEM fields
    input  wire        valid,
    input  wire        is_load,
    input  wire        is_store,
    input  wire [1:0]  mem_size,       // 0 byte, 1 half, 2 word (funct3[1:0])
    input  wire        load_unsigned,  // funct3[2]
    input  wire [31:0] addr,
    input  wire [31:0] store_data,     // rs2 after forwarding, unformatted
    input  wire [4:0]  rd,
    input  wire        writes_rd,
    input  wire [31:0] result,         // EX result for non-load instructions
    input  wire        freeze,         // hazard_unit freeze: MEM/WB does not advance
    // IF-A master
    output wire        req,
    output wire        we,
    output wire [31:0] m_addr,
    output reg  [31:0] wdata,
    output reg  [3:0]  be,
    input  wire [31:0] rdata,
    input  wire        ready,
    // to hazard_unit, regfile, forwarding, counters
    output wire        dport_wait,
    output wire        wb_we,
    output wire [4:0]  wb_rd,
    output wire [31:0] wb_data,
    output wire        retire
);

    wire        mem_op = valid && (is_load || is_store);
    reg         done_r;                    // the access completed while MEM/WB was frozen
    reg  [31:0] rdata_r;                   // ... and this is its word

    assign req        = mem_op && !done_r;
    assign we         = is_store;
    assign m_addr     = addr;
    assign dport_wait = req && !ready;

    always @(posedge clk) begin
        if (rst || !freeze) begin
            done_r <= 1'b0;
        end else if (req && ready) begin
            done_r  <= 1'b1;
            rdata_r <= rdata;
        end
    end

    // store lanes and byte enables (loads use the same enables: the lanes wanted)
    always @(*) begin
        case (mem_size)
            2'd0: begin
                wdata = {4{store_data[7:0]}};
                be    = 4'b0001 << addr[1:0];
            end
            2'd1: begin
                wdata = {2{store_data[15:0]}};
                be    = addr[1] ? 4'b1100 : 4'b0011;
            end
            default: begin
                wdata = store_data;
                be    = 4'b1111;
            end
        endcase
    end

    // load: shift the lane down, then sign or zero extend
    wire [31:0] word   = done_r ? rdata_r : rdata;
    wire [31:0] shifted = word >> {addr[1:0], 3'b000};
    reg  [31:0] load_val;
    always @(*) begin
        case (mem_size)
            2'd0:    load_val = load_unsigned ? {24'd0, shifted[7:0]}
                                              : {{24{shifted[7]}}, shifted[7:0]};
            2'd1:    load_val = load_unsigned ? {16'd0, shifted[15:0]}
                                              : {{16{shifted[15]}}, shifted[15:0]};
            default: load_val = word;
        endcase
    end

    assign retire  = valid && !freeze;
    assign wb_we   = retire && writes_rd && (rd != 5'd0);
    assign wb_rd   = rd;
    assign wb_data = is_load ? load_val : result;

endmodule

`default_nettype wire
