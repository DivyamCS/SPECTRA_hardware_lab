`timescale 1ns / 1ps
`default_nettype none
// hazard_unit - data-hazard decisions for one SPECTRA core (spec: docs/spec/hazard_unit.md).
// Purely combinational. Forwarding MEM/WB -> EX for rs1, rs2 and store data
// (FWD = 1), or a 1-cycle interlock on every distance-1 dependence (FWD = 0). Distance 2 needs
// neither: the register file is read in ID and is write-through.
// global freeze (data port or fetch path waiting) and the MUL/DIV hold (EX keeps
// the MUL/DIV, MEM/WB finishes and receives a bubble).
// the lab's 2-instruction squash after a taken branch, JAL or JALR resolved in EX,
// issued only when the pipeline moves, so a branch in EX during a stall redirects once, after it.
// Priority: freeze > ex_hold > squash > interlock.
// HAS_FWD = 0 removes the forwarding muxes; the core then behaves as FWD = 0.

module hazard_unit #(
    parameter HAS_FWD = 1
) (
    input  wire       fwd_en,          // IF-D cfg[0] FWD
    // instruction in ID
    input  wire       id_valid,
    input  wire [4:0] id_rs1,
    input  wire [4:0] id_rs2,
    input  wire       id_uses_rs1,
    input  wire       id_uses_rs2,
    // instruction in EX
    input  wire       ex_valid,
    input  wire [4:0] ex_rs1,
    input  wire [4:0] ex_rs2,
    input  wire [4:0] ex_rd,
    input  wire       ex_writes_rd,
    // instruction in MEM/WB
    input  wire       mw_valid,
    input  wire [4:0] mw_rd,
    input  wire       mw_writes_rd,
    input  wire       ex_taken,        // taken branch, JAL or JALR resolved in EX this cycle
    // stall causes
    input  wire       md_busy,         // MUL/DIV in EX has not finished
    input  wire       dport_wait,      // MEM/WB has an IF-A request without ready
    input  wire       ic_wait,         // the fetch path has no instruction this cycle
    // decisions
    output wire       fwd_a,           // EX operand A from the MEM/WB result
    output wire       fwd_b,           // EX operand B (and store data) from the MEM/WB result
    output wire       interlock,       // FWD = 0: hold IF and ID, bubble into EX
    output wire       freeze,          // hold every stage (no register advances)
    output wire       ex_hold,         // hold IF, ID and EX; MEM/WB advances and gets a bubble
    output wire       squash,          // invalidate IF/ID and the fetch in flight; redirect IF
    output wire       if_hold          // IF re-reads the ID address: freeze | ex_hold | a distance-1
                                       // dependence, NOT gated by squash (timing: the fetch address
                                       // must not wait for the branch decision)
);

    wire fwd_on = fwd_en && (HAS_FWD != 0);

    // A result in MEM/WB that a later instruction may need (x0 is never a result).
    wire mw_result = mw_valid && mw_writes_rd && (mw_rd != 5'd0);
    assign fwd_a = fwd_on && ex_valid && mw_result && (mw_rd == ex_rs1);
    assign fwd_b = fwd_on && ex_valid && mw_result && (mw_rd == ex_rs2);

    // Without forwarding, an instruction in ID that reads the register written by the one in EX
    // waits one cycle: then the producer is in MEM/WB and the write-through read sees it.
    wire ex_result = ex_valid && ex_writes_rd && (ex_rd != 5'd0);
    wire raw_d1    = !fwd_on && id_valid && ex_result &&
                     ((id_uses_rs1 && ex_rd == id_rs1) || (id_uses_rs2 && ex_rd == id_rs2));

    // Nothing advances while the data port or the fetch path waits; the pipeline resumes in the
    // cycle after the cause clears. A MUL/DIV still busy keeps EX (and so IF and ID) in place.
    // fwd_a / fwd_b stay valid through a freeze (the producer does not move). Under ex_hold the
    // producer leaves MEM/WB; the MUL/DIV took its operands when it started.
    assign freeze    = dport_wait || ic_wait;
    assign ex_hold   = md_busy && !freeze;

    // The two younger instructions are wrong-path: drop them (they never write, store, start a
    // MUL/DIV, issue on IF-A or retire). An interlock on the dropped instruction in ID is moot.
    assign squash    = ex_taken && !freeze && !ex_hold;
    assign interlock = raw_d1 && !freeze && !ex_hold && !squash;

    // When a squash and a distance-1 dependence meet, IF re-reads the ID address; that fetch is
    // dropped by the squash anyway, and the fetch PC takes the target.
    assign if_hold   = freeze || ex_hold || raw_d1;

endmodule

`default_nettype wire
