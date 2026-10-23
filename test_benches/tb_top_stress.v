`timescale 1ns / 1ps
`default_nettype none

// =============================================================================
// tb_dual_core_stress : two RV32I cores sharing ONE 4-way set-associative D-Cache
//                       through dc_arb2 + addr_decode, backed by mem_delay + dmem_bram.
//
// 5 Stress Phases (generated programmatically):
//   Phase 0 : Set Contention (Different addresses, exact same cache sets)
//   Phase 1 : Set Contention + Random External Pipeline Stalls (1-8 cycles)
//   Phase 2 : Thrashing Contention (Over-allocating sets to force PLRU dirty writebacks)
//   Phase 3 : Producer-Consumer Synchronization (Atomic flag/ack handshake in RAM)
//   Phase 4 : Producer-Consumer Synchronization + External Stall Injection
// =============================================================================

module tb_dual_core_stress;

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg inj = 1'b0;
    always #5 clk = ~clk; // 100 MHz clock

    integer seed = 32'h1234ABCD;

    // ---- Explicit Dummy Wires for Unused Module Ports (Verilog-2001 Compliance)
    wire unused_pulse0, unused_pulse1, unused_pulse2;

    // ---- Interconnect: Arbiter -> Decoder (IF-A Slave)
    wire        c_re, c_we, c_ready;
    wire [31:0] c_addr, c_wdata, c_rdata;
    wire [ 3:0] c_wstrb;
    wire        c_owner;

    // ---- Interconnect: Decoder -> D-Cache (IF-A Master)
    wire        dc_req, dc_we, dc_owner, dc_ready;
    wire [31:0] dc_addr, dc_wdata, dc_rdata;
    wire [ 3:0] dc_be;

    // ---- Decoder -> MMIO (Uncached port)
    wire        io_sel, io_we, io_owner, decode_err;
    wire [ 7:0] io_off;
    wire [31:0] io_wdata;

    // ---- D-Cache -> mem_delay (IF-B Master)
    wire        b_start, b_we, b_nwords, b_rvalid, b_wready, b_done;
    wire [29:0] b_addr;
    wire [31:0] b_wdata, b_rdata;
    wire [ 3:0] b_be;

    // ---- mem_delay -> BRAM Port
    wire [29:0] m_addr;
    wire        m_we;
    wire [ 3:0] m_be;
    wire [31:0] m_wdata, m_rdata;

    wire hit_pulse, miss_pulse, owner_pulse;

    // =========================================================================
    // Core 0 Instantiation
    // =========================================================================
    wire [31:0] pc0, ia0, id0, rda0, wra0, wrd0, rdd0;
    wire        rdr0, wrr0, exc0;
    wire [ 3:0] wrb0;
    wire        ast0, areq0, agnt0, are0, awe0, aready0;
    wire [31:0] aaddr0, awd0;
    wire [ 3:0] aws0;
    reg         ext0, stq0;
    integer     cnt0 = 0;
    wire        stall0 = ast0 | ext0;

    always @(posedge clk or posedge rst) begin
        if (rst) stq0 <= 1'b0;
        else     stq0 <= stall0;
    end

    // Random stall injection (simulates pipeline stalls like mul/div/icache)
    always @(posedge clk) begin
        if (rst || !inj) begin
            ext0 <= 1'b0;
            cnt0 = 0;
        end else if (cnt0 > 0) begin
            cnt0 = cnt0 - 1;
            ext0 <= (cnt0 != 0);
        end else if (($random(seed) & 7) == 0) begin
            cnt0 = 1 + ($random(seed) & 7);
            ext0 <= 1'b1;
        end
    end

    pipe P0 (
        .clk(clk), .reset(rst), .stall(stall0), .exception(exc0), .pc_out(pc0),
        .inst_mem_is_valid(1'b1), .inst_mem_read_data(id0), .dmem_read_data_temp(rdd0),
        .dmem_write_valid(1'b1), .dmem_read_valid(1'b1), .inst_mem_address(ia0),
        .dmem_read_ready(rdr0), .dmem_read_address(rda0), .dmem_write_ready(wrr0),
        .dmem_write_address(wra0), .dmem_write_data(wrd0), .dmem_write_byte(wrb0)
    );

    instr_mem I0 (
        .clk(clk), .en(~stq0), .pc(ia0), .instr(id0)
    );

    dcache_adapter AD0 (
        .clk(clk), .rst(rst), .pipe_stall_q(stq0),
        .dmem_read_ready(rdr0), .dmem_read_address(rda0), .dmem_write_ready(wrr0),
        .dmem_write_address(wra0), .dmem_write_data(wrd0), .dmem_write_byte(wrb0),
        .dmem_read_data_temp(rdd0), .stall(ast0), .req(areq0), .gnt(agnt0),
        .dc_re(are0), .dc_we(awe0), .dc_addr(aaddr0), .dc_wdata(awd0), .dc_wstrb(aws0),
        .dc_rdata(c_rdata), .dc_ready(aready0)
    );

    // =========================================================================
    // Core 1 Instantiation
    // =========================================================================
    wire [31:0] pc1, ia1, id1, rda1, wra1, wrd1, rdd1;
    wire        rdr1, wrr1, exc1;
    wire [ 3:0] wrb1;
    wire        ast1, areq1, agnt1, are1, awe1, aready1;
    wire [31:0] aaddr1, awd1;
    wire [ 3:0] aws1;
    reg         ext1, stq1;
    integer     cnt1 = 0;
    wire        stall1 = ast1 | ext1;

    always @(posedge clk or posedge rst) begin
        if (rst) stq1 <= 1'b0;
        else     stq1 <= stall1;
    end

    always @(posedge clk) begin
        if (rst || !inj) begin
            ext1 <= 1'b0;
            cnt1 = 0;
        end else if (cnt1 > 0) begin
            cnt1 = cnt1 - 1;
            ext1 <= (cnt1 != 0);
        end else if (($random(seed) & 7) == 0) begin
            cnt1 = 1 + ($random(seed) & 7);
            ext1 <= 1'b1;
        end
    end

    pipe P1 (
        .clk(clk), .reset(rst), .stall(stall1), .exception(exc1), .pc_out(pc1),
        .inst_mem_is_valid(1'b1), .inst_mem_read_data(id1), .dmem_read_data_temp(rdd1),
        .dmem_write_valid(1'b1), .dmem_read_valid(1'b1), .inst_mem_address(ia1),
        .dmem_read_ready(rdr1), .dmem_read_address(rda1), .dmem_write_ready(wrr1),
        .dmem_write_address(wra1), .dmem_write_data(wrd1), .dmem_write_byte(wrb1)
    );

    instr_mem I1 (
        .clk(clk), .en(~stq1), .pc(ia1), .instr(id1)
    );

    dcache_adapter AD1 (
        .clk(clk), .rst(rst), .pipe_stall_q(stq1),
        .dmem_read_ready(rdr1), .dmem_read_address(rda1), .dmem_write_ready(wrr1),
        .dmem_write_address(wra1), .dmem_write_data(wrd1), .dmem_write_byte(wrb1),
        .dmem_read_data_temp(rdd1), .stall(ast1), .req(areq1), .gnt(agnt1),
        .dc_re(are1), .dc_we(awe1), .dc_addr(aaddr1), .dc_wdata(awd1), .dc_wstrb(aws1),
        .dc_rdata(c_rdata), .dc_ready(aready1)
    );

    // =========================================================================
    // Memory Hierarchy: Arbiter -> Decoder -> D-Cache -> mem_delay -> BRAM
    // =========================================================================

    dc_arb2 ARB (
        .clk(clk), .rst(rst),
        .req0(areq0), .re0(are0), .we0(awe0), .addr0(aaddr0), .wdata0(awd0), .wstrb0(aws0),
        .req1(areq1), .re1(are1), .we1(awe1), .addr1(aaddr1), .wdata1(awd1), .wstrb1(aws1),
        .gnt0(agnt0), .gnt1(agnt1),
        .re(c_re), .we(c_we), .addr(c_addr), .wdata(c_wdata), .wstrb(c_wstrb),
        .ready(c_ready), .ready0(aready0), .ready1(aready1)
    );

    assign c_owner = agnt1; // 0 = Core 0, 1 = Core 1

    addr_decode DEC (
        .clk(clk), .rst(rst),
        .req(c_re | c_we), .we(c_we), .addr(c_addr), .wdata(c_wdata), .be(c_wstrb), .owner(c_owner),
        .rdata(c_rdata), .ready(c_ready),
        .dc_req(dc_req), .dc_we(dc_we), .dc_addr(dc_addr), .dc_wdata(dc_wdata), .dc_be(dc_be), .dc_owner(dc_owner),
        .dc_rdata(dc_rdata), .dc_ready(dc_ready),
        .io_sel(io_sel), .io_we(io_we), .io_off(io_off), .io_wdata(io_wdata), .io_owner(io_owner),
        .io_rdata(32'd0), .io_ready(1'b0), .decode_err(decode_err)
    );

    dcache DCACHE (
        .clk(clk), .rst(rst), .cache_en(1'b1),
        .req(dc_req), .we(dc_we), .addr(dc_addr), .wdata(dc_wdata), .be(dc_be), .owner(dc_owner),
        .rdata(dc_rdata), .ready(dc_ready),
        .m_start(b_start), .m_we(b_we), .m_addr(b_addr), .m_nwords(b_nwords),
        .m_wdata(b_wdata), .m_be(b_be), .m_rvalid(b_rvalid), .m_rdata(b_rdata),
        .m_wready(b_wready), .m_done(b_done),
        .hit_pulse(hit_pulse), .miss_pulse(miss_pulse), .owner_pulse(owner_pulse)
    );

    mem_delay MEM (
        .clk(clk), .rst(rst), .lat(2'd0), // L = 4 cycles
        .start(b_start), .we(b_we), .addr(b_addr), .nwords(b_nwords),
        .wdata(b_wdata), .be(b_be),
        .rvalid(b_rvalid), .rdata(b_rdata), .wready(b_wready), .done(b_done),
        .m_addr(m_addr), .m_we(m_we), .m_be(m_be), .m_wdata(m_wdata), .m_rdata(m_rdata)
    );

    dmem_bram #(.INIT_FILE("")) BRAM (
        .clk(clk), .addr(m_addr[14:0]), .we(m_we), .be(m_be),
        .wdata(m_wdata), .rdata(m_rdata)
    );

    // =========================================================================
    // Protocol Assertions & Starvation Monitors
    // =========================================================================
    integer merr = 0, wait0 = 0, wait1 = 0, sr0 = 0, sr1 = 0;
    reg     p_v, p_re, p_we, p_rdy;
    reg [31:0] p_addr, p_wd;
    reg [ 3:0] p_ws;

    task merror(input [8*40-1:0] what);
        begin
            merr = merr + 1;
            if (merr <= 8) $display("MON ERROR @%0t: %0s", $time, what);
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            p_v <= 0; p_rdy <= 0; wait0 = 0; wait1 = 0; sr0 = 0; sr1 = 0;
        end else begin
            if (agnt0 === 1'b1 && agnt1 === 1'b1)      merror("both cores granted simultaneously");
            if (aready0 === 1'b1 && aready1 === 1'b1)  merror("ready pulsed to both cores");
            if (aready0 === 1'b1 && agnt0 !== 1'b1)    merror("ready0 without grant0");
            if (aready1 === 1'b1 && agnt1 !== 1'b1)    merror("ready1 without grant1");
            if ((^{agnt0, agnt1, aready0, aready1, ast0, ast1, c_ready, c_re, c_we}) === 1'bx)
                                                       merror("X on control bus");
            if (p_v && !p_rdy) begin
                if (c_re !== p_re || c_we !== p_we || c_addr !== p_addr)
                    merror("request changed before ready returned");
                if (p_we && (c_wdata !== p_wd || c_wstrb !== p_ws))
                    merror("write payload mutated before ready");
            end
            p_v    <= c_re | c_we;
            p_re   <= c_re;
            p_we   <= c_we;
            p_rdy  <= c_ready;
            p_addr <= c_addr;
            p_wd   <= c_wdata;
            p_ws   <= c_wstrb;

            // Starvation Watchdogs (>400 cycles waiting for arbiter grant)
            wait0 = (areq0 && !agnt0) ? wait0 + 1 : 0; if (wait0 == 400) merror("core0 starved");
            wait1 = (areq1 && !agnt1) ? wait1 + 1 : 0; if (wait1 == 400) merror("core1 starved");

            // Hang Watchdogs (>3000 cycles stalled)
            sr0 = (ast0 === 1'b1) ? sr0 + 1 : 0; if (sr0 == 3000) merror("core0 pipeline stall hang");
            sr1 = (ast1 === 1'b1) ? sr1 + 1 : 0; if (sr1 == 3000) merror("core1 pipeline stall hang");
        end
    end

    // =========================================================================
    // Programmatic Assembly Generators
    // =========================================================================

    function [31:0] enc_lui(input [4:0] rd, input [19:0] imm);
        enc_lui = {imm, rd, 7'b0110111};
    endfunction

    function [31:0] enc_addi(input [4:0] rd, input [4:0] rs1, input [11:0] imm);
        enc_addi = {imm, rs1, 3'b000, rd, 7'b0010011};
    endfunction

    function [31:0] enc_add(input [4:0] rd, input [4:0] rs1, input [4:0] rs2);
        enc_add = {7'b0000000, rs2, rs1, 3'b000, rd, 7'b0110011};
    endfunction

    function [31:0] enc_sw(input [4:0] rs2, input [4:0] rs1, input [11:0] imm);
        enc_sw = {imm[11:5], rs2, rs1, 3'b010, imm[4:0], 7'b0100011};
    endfunction

    function [31:0] enc_lw(input [4:0] rd, input [4:0] rs1, input [11:0] imm);
        enc_lw = {imm, rs1, 3'b010, rd, 7'b0000011};
    endfunction

    function [31:0] enc_bne(input [4:0] rs1, input [4:0] rs2, input [12:0] imm);
        enc_bne = {imm[12], imm[10:5], rs2, rs1, 3'b001, imm[4:1], imm[11], 7'b1100011};
    endfunction

    function [31:0] enc_beq(input [4:0] rs1, input [4:0] rs2, input [12:0] imm);
        enc_beq = {imm[12], imm[10:5], rs2, rs1, 3'b000, imm[4:1], imm[11], 7'b1100011};
    endfunction

    function [31:0] enc_jal(input [4:0] rd, input [20:0] imm);
        enc_jal = {imm[20], imm[10:1], imm[11], imm[19:12], rd, 7'b1101111};
    endfunction

    task load_contention_prog(input integer core_id, input [31:0] base_addr, input integer stride, input integer count);
        integer p;
        reg [4:0] base_reg, val_reg, idx_reg, bound_reg, accum_reg, temp_reg, end_reg;
        begin
            base_reg  = 5'd1;
            val_reg   = 5'd2;
            idx_reg   = 5'd3;
            bound_reg = 5'd4;
            accum_reg = 5'd5;
            temp_reg  = 5'd6;
            end_reg   = 5'd31;

            p = 0;
            write_imem(core_id, p, enc_lui(base_reg, base_addr[31:12])); p = p + 1;
            write_imem(core_id, p, enc_addi(base_reg, base_reg, base_addr[11:0])); p = p + 1;
            write_imem(core_id, p, enc_addi(val_reg, 5'd0, 12'd10 + core_id)); p = p + 1;
            write_imem(core_id, p, enc_addi(idx_reg, 5'd0, 12'd0)); p = p + 1;
            write_imem(core_id, p, enc_addi(bound_reg, 5'd0, count)); p = p + 1;

            // Store loop
            write_imem(core_id, p, enc_sw(val_reg, base_reg, 12'd0)); p = p + 1;
            write_imem(core_id, p, enc_addi(base_reg, base_reg, stride)); p = p + 1;
            write_imem(core_id, p, enc_addi(val_reg, val_reg, 12'd1)); p = p + 1;
            write_imem(core_id, p, enc_addi(idx_reg, idx_reg, 12'd1)); p = p + 1;
            write_imem(core_id, p, enc_bne(idx_reg, bound_reg, -13'd16)); p = p + 1;

            // Reset pointer for readback
            write_imem(core_id, p, enc_lui(base_reg, base_addr[31:12])); p = p + 1;
            write_imem(core_id, p, enc_addi(base_reg, base_reg, base_addr[11:0])); p = p + 1;
            write_imem(core_id, p, enc_addi(idx_reg, 5'd0, 12'd0)); p = p + 1;
            write_imem(core_id, p, enc_addi(accum_reg, 5'd0, 12'd0)); p = p + 1;

            // Readback loop
            write_imem(core_id, p, enc_lw(temp_reg, base_reg, 12'd0)); p = p + 1;
            write_imem(core_id, p, enc_add(accum_reg, accum_reg, temp_reg)); p = p + 1;
            write_imem(core_id, p, enc_addi(base_reg, base_reg, stride)); p = p + 1;
            write_imem(core_id, p, enc_addi(idx_reg, idx_reg, 12'd1)); p = p + 1;
            write_imem(core_id, p, enc_bne(idx_reg, bound_reg, -13'd16)); p = p + 1;

            // Completion flag (0xDEADC000 + 0xFFFFFEEF = 0xDEADBEEF)
            write_imem(core_id, p, enc_lui(end_reg, 20'hDEADC)); p = p + 1;
            write_imem(core_id, p, enc_addi(end_reg, end_reg, 12'hEEF)); p = p + 1;
            write_imem(core_id, p, enc_jal(5'd0, 21'd0)); p = p + 1;
        end
    endtask

    task load_handshake_prog();
        integer p0, p1;
        reg [4:0] flag_reg, data_reg, val_reg, end_reg;
        begin
            flag_reg = 5'd1;
            data_reg = 5'd2;
            val_reg  = 5'd3;
            end_reg  = 5'd31;

            // Core 0: Producer
            p0 = 0;
            write_imem(0, p0, enc_lui(flag_reg, 20'h10000)); p0 = p0 + 1;
            write_imem(0, p0, enc_addi(flag_reg, flag_reg, 12'h100)); p0 = p0 + 1;
            write_imem(0, p0, enc_lui(data_reg, 20'h10000)); p0 = p0 + 1;
            write_imem(0, p0, enc_addi(data_reg, data_reg, 12'h104)); p0 = p0 + 1;

            write_imem(0, p0, enc_lui(val_reg, 20'h12345)); p0 = p0 + 1;
            write_imem(0, p0, enc_addi(val_reg, val_reg, 12'h678)); p0 = p0 + 1;
            write_imem(0, p0, enc_sw(val_reg, data_reg, 12'd0)); p0 = p0 + 1;

            write_imem(0, p0, enc_addi(val_reg, 5'd0, 12'd1)); p0 = p0 + 1;
            write_imem(0, p0, enc_sw(val_reg, flag_reg, 12'd0)); p0 = p0 + 1;

            write_imem(0, p0, enc_lw(val_reg, flag_reg, 12'd0)); p0 = p0 + 1;
            write_imem(0, p0, enc_addi(5'd4, 5'd0, 12'd2)); p0 = p0 + 1;
            write_imem(0, p0, enc_bne(val_reg, 5'd4, -13'd8)); p0 = p0 + 1;

            write_imem(0, p0, enc_lui(end_reg, 20'hDEADC)); p0 = p0 + 1;
            write_imem(0, p0, enc_addi(end_reg, end_reg, 12'hEEF)); p0 = p0 + 1;
            write_imem(0, p0, enc_jal(5'd0, 21'd0)); p0 = p0 + 1;

            // Core 1: Consumer
            p1 = 0;
            write_imem(1, p1, enc_lui(flag_reg, 20'h10000)); p1 = p1 + 1;
            write_imem(1, p1, enc_addi(flag_reg, flag_reg, 12'h100)); p1 = p1 + 1;
            write_imem(1, p1, enc_lui(data_reg, 20'h10000)); p1 = p1 + 1;
            write_imem(1, p1, enc_addi(data_reg, data_reg, 12'h104)); p1 = p1 + 1;

            write_imem(1, p1, enc_lw(val_reg, flag_reg, 12'd0)); p1 = p1 + 1;
            write_imem(1, p1, enc_beq(val_reg, 5'd0, -13'd4)); p1 = p1 + 1;

            write_imem(1, p1, enc_lw(5'd5, data_reg, 12'd0)); p1 = p1 + 1;

            write_imem(1, p1, enc_addi(val_reg, 5'd0, 12'd2)); p1 = p1 + 1;
            write_imem(1, p1, enc_sw(val_reg, flag_reg, 12'd0)); p1 = p1 + 1;

            write_imem(1, p1, enc_lui(end_reg, 20'hDEADC)); p1 = p1 + 1;
            write_imem(1, p1, enc_addi(end_reg, end_reg, 12'hEEF)); p1 = p1 + 1;
            write_imem(1, p1, enc_jal(5'd0, 21'd0)); p1 = p1 + 1;
        end
    endtask

    task write_imem(input integer core_id, input integer addr, input [31:0] word);
        begin
            if (core_id == 0) I0.imem[addr] = word;
            else              I1.imem[addr] = word;
        end
    endtask

    // =========================================================================
    // Phase Runner Sequencer
    // =========================================================================
    integer ph, k, t, d0, d1, bad, total_bad;

    task run_phase(input integer p);
        begin
            inj = (p == 1) || (p == 2) || (p == 4);
            rst = 1'b1;

            for (k = 0; k < 1024; k = k + 1) begin
                I0.imem[k] = 32'h00000013; // NOP (addi x0, x0, 0)
                I1.imem[k] = 32'h00000013;
            end
            for (k = 0; k < 2048; k = k + 1) begin
                BRAM.mem[k] = 32'h00000000;
            end

            case (p)
                0, 1: begin
                    load_contention_prog(0, 32'h1000_0000, 32'd64, 16);
                    load_contention_prog(1, 32'h1000_0800, 32'd64, 16);
                end
                2: begin
                    load_contention_prog(0, 32'h1000_0000, 32'd1024, 24);
                    load_contention_prog(1, 32'h1000_0010, 32'd1024, 24);
                end
                3, 4: begin
                    load_handshake_prog();
                end
            endcase

            repeat (5) @(posedge clk);
            rst = 1'b0;
            t = 0; d0 = 0; d1 = 0; merr = 0;

            repeat (50) @(posedge clk);

            while ((!d0 || !d1) && t < 200000) begin
                @(posedge clk);
                t = t + 1;
                if (P0.regs[31] === 32'hDEADBEEF) d0 = 1;
                if (P1.regs[31] === 32'hDEADBEEF) d1 = 1;
            end

            repeat (50) @(posedge clk);

            bad = 0;
            if (!d0) begin bad = bad + 1; $display("FAIL: Core 0 timeout (PC = %08h)", pc0); end
            if (!d1) begin bad = bad + 1; $display("FAIL: Core 1 timeout (PC = %08h)", pc1); end
            if (merr != 0) begin bad = bad + 1; $display("FAIL: %0d bus monitor errors occurred", merr); end

            if (p == 3 || p == 4) begin
                if (P1.regs[5] !== 32'h12345678) begin
                    bad = bad + 1;
                    $display("FAIL: Handshake payload mismatch! Core 1 x5 got %h, expected 12345678", P1.regs[5]);
                end
            end

            $display("      %0s (%0d clocks)", bad == 0 ? "PASS" : "FAILED", t);
            total_bad = total_bad + bad;
        end
    endtask

    initial begin
        total_bad = 0;
        $display("================================================================");
        $display("STARTING DUAL-CORE STRESS TEST SUITE (5 PHASES)");
        $display("================================================================");

        for (ph = 0; ph < 5; ph = ph + 1) begin
            case (ph)
                0: $display("---- Phase 0: Way Contention (Disjoint Regions, Same Sets)");
                1: $display("---- Phase 1: Way Contention + Random Pipeline Stall Injection");
                2: $display("---- Phase 2: Cache Thrashing (PLRU Eviction & Dirty Writeback)");
                3: $display("---- Phase 3: Shared-Data Handshake (Producer-Consumer)");
                4: $display("---- Phase 4: Shared-Data Handshake + Random Pipeline Stalls");
            endcase
            run_phase(ph);
        end

        $display("================================================================");
        if (total_bad == 0) $display("ALL 5 PHASES PASSED SUCCESSFULLY!");
        else                $display("FAIL: %0d total problem(s) detected across phases", total_bad);
        $display("================================================================");
        $finish;
    end

endmodule

`default_nettype wire