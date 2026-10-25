`timescale 1ns / 1ps
`default_nettype none
// core - one SPECTRA RV32IM core, 3 stages IF/ID, EX, MEM/WB (spec: docs/spec/core.md).
// Wrapper only: instantiates decoder, regfile, hazard_unit, execute, mem_stage and (simulation
// only) commit_trace, plus the pipeline registers: fetch PC, ID/EX and EX/MEM, each with a
// valid bit, plus the core's I-cache and its I-side mem_delay in front of the IMEM port.
//
// Fetch: one fetch at a time goes to the I-cache from the registered fetch PC; on a hit
// the answer comes the next cycle and the next fetch goes out in that same cycle, so straight
// code runs at one instruction per cycle. ID decodes the answer in the cycle it arrives (as the
// BRAM output); if ID holds, the answer waits in a one-entry buffer, and no new fetch
// goes out while it would stay full. With no instruction for ID, ic_wait freezes the pipeline
// (the fetch logic itself is never frozen). A squash drops the instruction in ID and the buffer
// (no fetch is in flight then: see the invariant below) and fetches the target in the next cycle: 2 bubbles on hits, as with the BRAM. After reset ID is empty until the first answer.
//
// Stage advance rules (hazard_unit): nothing moves under freeze; under ex_hold MEM/WB moves and
// gets a bubble; under interlock EX gets a bubble and IF/ID hold; otherwise all move.

module core #(
    parameter HART_ID    = 0,
    parameter HAS_MD     = 1,          // removal parameters (area builds): MUL/DIV,
    parameter HAS_FWD    = 1,          // forwarding,
    parameter HAS_ICACHE = 1           // I-cache
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [15:0] cfg,            // IF-D config word
    // IF-A data port (master)
    output wire        d_req,
    output wire        d_we,
    output wire [31:0] d_addr,
    output wire [31:0] d_wdata,
    output wire [3:0]  d_be,
    input  wire [31:0] d_rdata,
    input  wire        d_ready,
    // instruction memory port (16 KB, word address, 1-cycle read)
    output wire [11:0] imem_addr,
    input  wire [31:0] imem_rdata,
    // event pulses for perf_counters
    output wire        ev_instret,
    output wire        ev_ihit,
    output wire        ev_imiss
);

    // ------------------------------------------------------------ hazard decisions
    wire fwd_a, fwd_b, interlock, freeze, ex_hold, squash, if_hold;
    wire md_busy, dport_wait, ex_taken, ic_wait;

    wire ex_move = !freeze && !ex_hold;               // EX takes a new instruction (or a bubble)
    wire mw_move = !freeze;                           // MEM/WB takes a new instruction (or a bubble)
    wire id_adv  = ex_move && !interlock;             // ID/EX takes the instruction in ID

    // ------------------------------------------------------------ IF: I-cache and I-side delay
    wire        fetch_req, fetch_ready;
    wire [31:0] fetch_instr, ex_target;
    wire        im_start, im_we, im_nwords, im_rvalid, im_wready, im_done, ib_we;
    wire [29:0] im_addr, ib_addr;
    wire [31:0] im_wdata, im_rdata, ib_wdata;
    wire [3:0]  im_be, ib_be;

    reg  [31:0] pc_f;                                 // next address to fetch
    reg         fq_valid;                             // a fetch is outstanding
    reg  [31:0] fq_pc;
    reg         fb_valid;                             // an answer waiting for ID
    reg  [31:0] fb_pc, fb_instr;

    // the instruction in ID: the buffered answer, else this cycle's answer
    wire        ans      = fq_valid && fetch_ready;
    wire        id_valid = fb_valid || ans;
    wire [31:0] id_pc    = fb_valid ? fb_pc : fq_pc;
    wire [31:0] id_instr = fb_valid ? fb_instr : fetch_instr;
    assign      ic_wait  = !id_valid;                 // the fetch path has no instruction

    // a new fetch goes out when the cache is free (none outstanding, or it answers now), no
    // answer will be left waiting in the buffer, and no squash is redirecting the stream.
    // Invariant: no fetch is in flight at a squash. A squash needs freeze = 0, so ID holds the
    // instruction after the branch; the fetch after that one goes out only in the cycle ID gives
    // it up, and not in a squash cycle. So no wrong-path fetch is ever issued (checked in SIM).
    wire        fb_next  = id_valid && !id_adv && !squash;
    assign      fetch_req = (!fq_valid || fetch_ready) && !fb_next && !squash;

    always @(posedge clk) begin
        if (rst) begin
            pc_f <= 32'd0; fq_valid <= 1'b0; fb_valid <= 1'b0;
        end else begin
            if (fetch_req) begin
                fq_valid <= 1'b1; fq_pc <= pc_f;
            end else if (fetch_ready) begin
                fq_valid <= 1'b0;
            end
            fb_valid <= fb_next;
            if (fb_next && !fb_valid) begin fb_pc <= fq_pc; fb_instr <= fetch_instr; end
            if (squash)         pc_f <= ex_target;
            else if (fetch_req) pc_f <= pc_f + 32'd4;
        end
    end

    icache #(.HAS_ICACHE(HAS_ICACHE)) u_ic (
        .clk(clk), .rst(rst), .ic_en(cfg[7]), .fetch_req(fetch_req), .fetch_addr(pc_f),
        .fetch_ready(fetch_ready), .instr(fetch_instr),
        .m_start(im_start), .m_we(im_we), .m_addr(im_addr), .m_nwords(im_nwords),
        .m_wdata(im_wdata), .m_be(im_be), .m_rvalid(im_rvalid), .m_rdata(im_rdata),
        .m_wready(im_wready), .m_done(im_done), .ic_hit(ev_ihit), .ic_miss(ev_imiss));
    mem_delay u_imd (
        .clk(clk), .rst(rst), .lat(cfg[4:3]), .start(im_start), .we(im_we), .addr(im_addr),
        .nwords(im_nwords), .wdata(im_wdata), .be(im_be), .rvalid(im_rvalid), .rdata(im_rdata),
        .wready(im_wready), .done(im_done), .m_addr(ib_addr), .m_we(ib_we), .m_be(ib_be),
        .m_wdata(ib_wdata), .m_rdata(imem_rdata));
    assign imem_addr = ib_addr[11:0];

`ifdef SIM
    always @(posedge clk)
        if (!rst && squash && fq_valid && !fetch_ready)
            $display("FAIL core: a fetch was in flight at a squash (pc_f %08h, t=%0t)", pc_f, $time);
`endif

    // ------------------------------------------------------------ ID
    wire [4:0]  id_rs1, id_rs2, id_rd;
    wire        id_uses_rs1, id_uses_rs2, id_writes_rd, id_use_imm, id_is_lui, id_is_auipc;
    wire        id_is_jal, id_is_jalr, id_is_branch, id_is_load, id_is_store, id_load_unsigned;
    wire        id_is_md, id_illegal;
    wire [31:0] id_imm;
    wire [3:0]  id_alu_op;
    wire [2:0]  id_br_cond, id_md_op;
    wire [1:0]  id_mem_size;

    decoder u_dec (
        .instr(id_instr), .rs1(id_rs1), .rs2(id_rs2), .rd(id_rd),
        .uses_rs1(id_uses_rs1), .uses_rs2(id_uses_rs2), .writes_rd(id_writes_rd), .imm(id_imm),
        .alu_op(id_alu_op), .use_imm(id_use_imm), .is_lui(id_is_lui), .is_auipc(id_is_auipc),
        .is_jal(id_is_jal), .is_jalr(id_is_jalr), .is_branch(id_is_branch), .br_cond(id_br_cond),
        .is_load(id_is_load), .is_store(id_is_store), .mem_size(id_mem_size),
        .load_unsigned(id_load_unsigned), .is_md(id_is_md), .md_op(id_md_op), .illegal(id_illegal));

    wire        wb_we;
    wire [4:0]  wb_rd;
    wire [31:0] wb_data;
    wire [31:0] id_rs1_val, id_rs2_val;
    regfile u_rf (.clk(clk), .rst(rst), .raddr1(id_rs1), .raddr2(id_rs2), .rdata1(id_rs1_val),
                  .rdata2(id_rs2_val), .we(wb_we), .waddr(wb_rd), .wdata(wb_data));

    // ------------------------------------------------------------ ID/EX register
    reg         ex_valid, ex_use_imm, ex_is_lui, ex_is_auipc, ex_is_jal, ex_is_jalr, ex_is_branch;
    reg         ex_is_load, ex_is_store, ex_load_unsigned, ex_is_md, ex_writes_rd;
    reg  [31:0] ex_pc, ex_instr, ex_rs1_val, ex_rs2_val, ex_imm;
    reg  [4:0]  ex_rs1, ex_rs2, ex_rd;
    reg  [3:0]  ex_alu_op;
    reg  [2:0]  ex_br_cond, ex_md_op;
    reg  [1:0]  ex_mem_size;

    always @(posedge clk) begin
        if (rst) begin
            ex_valid <= 1'b0;
        end else if (ex_move) begin
            ex_valid         <= id_valid && !interlock && !squash;
            ex_pc            <= id_pc;
            ex_instr         <= id_instr;
            ex_rs1_val       <= id_rs1_val;
            ex_rs2_val       <= id_rs2_val;
            ex_imm           <= id_imm;
            ex_rs1           <= id_rs1;
            ex_rs2           <= id_rs2;
            ex_rd            <= id_rd;
            ex_writes_rd     <= id_writes_rd;
            ex_alu_op        <= id_alu_op;
            ex_use_imm       <= id_use_imm;
            ex_is_lui        <= id_is_lui;
            ex_is_auipc      <= id_is_auipc;
            ex_is_jal        <= id_is_jal;
            ex_is_jalr       <= id_is_jalr;
            ex_is_branch     <= id_is_branch;
            ex_br_cond       <= id_br_cond;
            ex_is_load       <= id_is_load;
            ex_is_store      <= id_is_store;
            ex_mem_size      <= id_mem_size;
            ex_load_unsigned <= id_load_unsigned;
            ex_is_md         <= id_is_md;
            ex_md_op         <= id_md_op;
        end
    end

    // ------------------------------------------------------------ EX
    wire [31:0] ex_result, ex_mem_addr, ex_store_data;
    execute #(.HAS_MD(HAS_MD)) u_ex (
        .clk(clk), .rst(rst), .valid(ex_valid), .pc(ex_pc), .rs1_val(ex_rs1_val),
        .rs2_val(ex_rs2_val), .imm(ex_imm), .alu_op(ex_alu_op), .use_imm(ex_use_imm),
        .is_lui(ex_is_lui), .is_auipc(ex_is_auipc), .is_jal(ex_is_jal), .is_jalr(ex_is_jalr),
        .is_branch(ex_is_branch), .br_cond(ex_br_cond), .is_md(ex_is_md), .md_op(ex_md_op),
        .fwd_a(fwd_a), .fwd_b(fwd_b), .mw_result(wb_data), .freeze(freeze),
        .result(ex_result), .taken(ex_taken), .target(ex_target), .mem_addr(ex_mem_addr),
        .store_data(ex_store_data), .md_busy(md_busy));

    // ------------------------------------------------------------ EX/MEM register
    reg         mw_valid, mw_is_load, mw_is_store, mw_load_unsigned, mw_writes_rd;
    reg  [31:0] mw_pc, mw_instr, mw_result, mw_addr, mw_store_data;
    reg  [4:0]  mw_rd;
    reg  [1:0]  mw_mem_size;

    always @(posedge clk) begin
        if (rst) begin
            mw_valid <= 1'b0;
        end else if (mw_move) begin
            mw_valid         <= ex_valid && !ex_hold;  // a held MUL/DIV leaves a bubble behind
            mw_pc            <= ex_pc;
            mw_instr         <= ex_instr;
            mw_result        <= ex_result;
            mw_addr          <= ex_mem_addr;
            mw_store_data    <= ex_store_data;
            mw_rd            <= ex_rd;
            mw_writes_rd     <= ex_writes_rd;
            mw_is_load       <= ex_is_load;
            mw_is_store      <= ex_is_store;
            mw_mem_size      <= ex_mem_size;
            mw_load_unsigned <= ex_load_unsigned;
        end
    end

    // ------------------------------------------------------------ MEM/WB
    wire retire;
    mem_stage u_mem (
        .clk(clk), .rst(rst), .valid(mw_valid), .is_load(mw_is_load), .is_store(mw_is_store),
        .mem_size(mw_mem_size), .load_unsigned(mw_load_unsigned), .addr(mw_addr),
        .store_data(mw_store_data), .rd(mw_rd), .writes_rd(mw_writes_rd), .result(mw_result),
        .freeze(freeze),
        .req(d_req), .we(d_we), .m_addr(d_addr), .wdata(d_wdata), .be(d_be), .rdata(d_rdata),
        .ready(d_ready),
        .dport_wait(dport_wait), .wb_we(wb_we), .wb_rd(wb_rd), .wb_data(wb_data), .retire(retire));

    hazard_unit #(.HAS_FWD(HAS_FWD)) u_hz (
        .fwd_en(cfg[0]),
        .id_valid(id_valid), .id_rs1(id_rs1), .id_rs2(id_rs2),
        .id_uses_rs1(id_uses_rs1), .id_uses_rs2(id_uses_rs2),
        .ex_valid(ex_valid), .ex_rs1(ex_rs1), .ex_rs2(ex_rs2), .ex_rd(ex_rd),
        .ex_writes_rd(ex_writes_rd),
        .mw_valid(mw_valid), .mw_rd(mw_rd), .mw_writes_rd(mw_writes_rd), .ex_taken(ex_taken),
        .md_busy(md_busy), .dport_wait(dport_wait), .ic_wait(ic_wait),
        .fwd_a(fwd_a), .fwd_b(fwd_b), .interlock(interlock), .freeze(freeze), .ex_hold(ex_hold),
        .squash(squash), .if_hold(if_hold));

    assign ev_instret = retire;

`ifdef SIM
    commit_trace #(.HART_ID(HART_ID)) u_trace (
        .clk(clk), .rst(rst), .retire(retire), .pc(mw_pc), .instr(mw_instr), .wb_we(wb_we),
        .wb_rd(wb_rd), .wb_data(wb_data), .is_load(mw_is_load), .is_store(mw_is_store),
        .mem_size(mw_mem_size), .addr(mw_addr), .store_data(mw_store_data));
`endif

endmodule

`default_nettype wire
