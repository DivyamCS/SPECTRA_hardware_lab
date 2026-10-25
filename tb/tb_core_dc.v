`timescale 1ns / 1ps
`default_nettype none
// tb_core_dc - tb_core with the real data side. The core's IF-A data
// port is split here by address (no arbiter yet): 0x1000_0000-0x1001_FFFF -> dcache (cfg DC)
// -> D-side mem_delay (cfg LAT) -> dmem_bram (dmem.hex); 0x2000_0000-0x2000_00FF
// -> the MMIO stub (ready in cycle 2); anything else -> ready in cycle 2, rdata 0, and a
// decode error that fails the run (interfaces.md section 1 rule 5). IMEM as in tb_core.
// Everything else (cfg.mem, maxcyc.mem, CHECKSUM end, watchdog, trace_rtl0.txt) as tb_core.

module tb_core_dc;

    reg         clk = 1'b0, rst = 1'b1;
    always #10 clk = ~clk;

    reg  [15:0] cfg_mem [0:0];
    reg  [15:0] cfg = 16'h0093;
    reg  [31:0] maxcyc_mem [0:0];
    integer     max_cycles = 10000000;

    wire        d_req, d_we;
    wire [31:0] d_addr, d_wdata;
    wire [3:0]  d_be;
    reg  [31:0] d_rdata;
    reg         d_ready;
    wire [11:0] imem_addr;
    reg  [31:0] imem_rdata = 32'd0;
    wire        ev_instret, ev_ihit, ev_imiss;

    core #(.HART_ID(0)) dut (
        .clk(clk), .rst(rst), .cfg(cfg),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_wdata(d_wdata), .d_be(d_be),
        .d_rdata(d_rdata), .d_ready(d_ready),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata),
        .ev_instret(ev_instret), .ev_ihit(ev_ihit), .ev_imiss(ev_imiss));

    // ---------------------------------------------------------------- memories
    reg [31:0] imem [0:4095];
    integer i;
    initial begin
        $readmemh("imem.hex", imem);
        cfg_mem[0] = 16'h0093;
        $readmemh("cfg.mem", cfg_mem);
        cfg = cfg_mem[0];
        maxcyc_mem[0] = 32'd10000000;
        $readmemh("maxcyc.mem", maxcyc_mem);
        max_cycles = maxcyc_mem[0];
    end
    always @(posedge clk) imem_rdata <= imem[imem_addr];

    // ---------------------------------------------------------------- run state
    reg         counting = 1'b0, done = 1'b0, decode_err = 1'b0;
    integer     cycles = 0, run_cycles = 0, instret = 0, run_instret = 0, idle = 0;
    reg  [31:0] checksum = 32'd0;
    always @(posedge clk) if (!rst) begin
        cycles = cycles + 1;
        if (ev_instret) begin instret = instret + 1; idle = 0; end else idle = idle + 1;
        if (counting) begin
            run_cycles = run_cycles + 1;
            if (ev_instret) run_instret = run_instret + 1;
        end
    end

    // ---------------------------------------------------------------- data side split
    wire        is_dmem = (d_addr[31:17] == 15'h0800);          // 0x1000_0000-0x1001_FFFF
    wire        is_mmio = (d_addr[31:8] == 24'h200000);
    wire        dc_ready, dc_ev_hit, dc_ev_miss, dc_ev_owner;
    wire [31:0] dc_rdata;
    wire        m_start, m_we, m_nwords, m_rvalid, m_wready, m_done, b_we;
    wire [29:0] m_addr, b_addr;
    wire [31:0] m_wdata, m_rdata, b_wdata, b_rdata;
    wire [3:0]  m_be, b_be;

    dcache u_dc (.clk(clk), .rst(rst), .cfg_dc(cfg[1]),
                 .req(d_req && is_dmem), .we(d_we), .addr(d_addr),
                 .wdata(d_wdata), .be(d_be), .owner(1'b0), .rdata(dc_rdata), .ready(dc_ready),
                 .m_start(m_start), .m_we(m_we), .m_addr(m_addr), .m_nwords(m_nwords),
                 .m_wdata(m_wdata), .m_be(m_be), .m_rvalid(m_rvalid), .m_rdata(m_rdata),
                 .m_wready(m_wready), .m_done(m_done),
                 .ev_hit(dc_ev_hit), .ev_miss(dc_ev_miss), .ev_owner(dc_ev_owner));
    mem_delay u_dmd (.clk(clk), .rst(rst), .lat(cfg[4:3]), .start(m_start), .we(m_we), .addr(m_addr),
                     .nwords(m_nwords), .wdata(m_wdata), .be(m_be), .rvalid(m_rvalid), .rdata(m_rdata),
                     .wready(m_wready), .done(m_done), .m_addr(b_addr), .m_we(b_we), .m_be(b_be),
                     .m_wdata(b_wdata), .m_rdata(b_rdata));
    dmem_bram #(.INIT_FILE("dmem.hex")) u_dmem (.clk(clk), .addr(b_addr[14:0]), .we(b_we),
                                                .be(b_be), .wdata(b_wdata), .rdata(b_rdata));

    // D-cache hit/miss pulses inside RUN_START..RUN_STOP (tb/top/check_hits.py compares them with Python)
    integer     dhit = 0, dmiss = 0;
    always @(posedge clk) if (!rst && counting) begin
        if (dc_ev_hit) dhit = dhit + 1;
        if (dc_ev_miss) dmiss = dmiss + 1;
    end

    reg  [31:0] mmio_rd;
    always @(*) begin
        case (d_addr[7:0])
            8'h00:   mmio_rd = 32'd0;                               // CORE_ID
            8'h04:   mmio_rd = 32'd1;                               // NCORES
            8'h08:   mmio_rd = {16'd0, cfg};                        // CONFIG
            8'h0C:   mmio_rd = 32'd0;                               // BARRIER: returns at once
            8'h10:   mmio_rd = 32'd0;                               // LOCK: acquired
            8'h34:   mmio_rd = run_cycles;                          // CYCLES
            8'h38:   mmio_rd = {16'd0, cfg};                        // SWITCHES
            8'h3C:   mmio_rd = 32'd0;                               // BUTTONS
            8'h50:   mmio_rd = run_instret;                         // core 0 INSTRET
            8'h54:   mmio_rd = dhit;                                // core 0 D_HIT
            8'h58:   mmio_rd = dmiss;                               // core 0 D_MISS
            default: mmio_rd = 32'd0;                               // other counters
        endcase
    end

    // MMIO stub and decode errors: ready in cycle 2
    reg         io_ready = 1'b0;
    reg  [31:0] io_rdata = 32'd0;
    always @(posedge clk) begin
        io_ready <= 1'b0;
        if (!rst && d_req && !is_dmem && !io_ready) begin
            io_ready <= 1'b1;
            if (is_mmio) begin
                if (d_we) begin
                    case (d_addr[7:0])
                        8'h14: begin counting <= 1'b1; run_cycles = 0; run_instret = 0; dhit = 0; dmiss = 0; end
                        8'h18: counting <= 1'b0;
                        8'h20: begin checksum <= d_wdata; done <= 1'b1; end
                        default: ;
                    endcase
                end else io_rdata <= mmio_rd;
            end else begin
                io_rdata <= 32'd0;
                decode_err <= 1'b1;
                $display("decode error: %s %08h at cycle %0d", d_we ? "store" : "load", d_addr, cycles);
            end
        end
    end
    always @(*) begin
        d_ready = dc_ready || io_ready;
        d_rdata = dc_ready ? dc_rdata : io_rdata;
    end

`ifdef TIMING_DUMP
    // ---------------------------------------------------------------- timing dump
    // C1 = the N-th cycle (tdump.mem word 0, default 5) inside the run in which the loop's first
    // instruction (tdump.mem word 1: its address, found in demo.lst by tb/timing/run.py; 0xAD4
    // in the earlier build) has just entered ID with a bubble in EX (right after the taken bne);
    // rows C1-C30 go to timing_rtl.txt: "C id_valid id_pc ex_valid ex_pc mw_valid mw_pc freeze
    // ex_hold squash interlock ic_wait dport_wait", after a line "R0 n" = instructions retired
    // before C1.
    reg  [31:0] tdump_mem [0:1];
    reg  [31:0] t_pc = 32'h00000AD4;
    integer     t_n = 0, t_want = 5, t_row = 0, t_fd, t_ret = 0;
    reg         t_on = 1'b0, t_prev_ad4 = 1'b0;
    initial begin
        tdump_mem[0] = 32'd5; tdump_mem[1] = 32'h00000AD4; $readmemh("tdump.mem", tdump_mem);
        t_want = tdump_mem[0]; t_pc = tdump_mem[1];
    end
    always @(negedge clk) if (!rst) begin
        if (!t_on && t_row == 0 && counting && dut.id_valid && dut.id_pc == t_pc &&
            !dut.ex_valid && !t_prev_ad4) begin
            t_n = t_n + 1;
            if (t_n == t_want) begin
                t_on = 1'b1;
                t_fd = $fopen("timing_rtl.txt", "w");
                $fwrite(t_fd, "R0 %0d\n", t_ret);
            end
        end
        if (t_on) begin
            t_row = t_row + 1;
            $fwrite(t_fd, "%0d %0d %x %0d %x %0d %x %0d %0d %0d %0d %0d %0d\n", t_row,
                    dut.id_valid, dut.id_pc, dut.ex_valid, dut.ex_pc, dut.mw_valid, dut.mw_pc,
                    dut.freeze, dut.ex_hold, dut.squash, dut.interlock, dut.ic_wait, dut.dport_wait);
            if (t_row == 30) begin t_on = 1'b0; $fclose(t_fd); end
        end
        t_prev_ad4 = dut.id_valid && dut.id_pc == t_pc;
    end
    always @(posedge clk) if (!rst && ev_instret && !t_on && t_row == 0) t_ret = t_ret + 1;
`endif

    // ---------------------------------------------------------------- run control
    initial begin
        repeat (3) @(posedge clk);
        #1 rst = 1'b0;
        while (!done && idle < 100000 && cycles < max_cycles && !decode_err) @(posedge clk);
        repeat (4) @(posedge clk);                                  // let the CHECKSUM store retire
        if (done && !decode_err) begin
            $display("CHECKSUM %08h cycles %0d instret %0d (run %0d cycles, %0d instructions)",
                     checksum, cycles, instret, run_cycles, run_instret);
            $display("DCACHE hits %0d misses %0d (inside RUN_START..RUN_STOP)", dhit, dmiss);
            $display("PASS core");
        end else if (idle >= 100000)
            $display("FAIL core: watchdog, no instruction retired for 100000 cycles (cycle %0d, pc %08h)",
                     cycles, dut.id_pc);
        else if (decode_err)
            $display("FAIL core: decode error");
        else
            $display("FAIL core: no CHECKSUM write after %0d cycles", cycles);
        $finish;
    end

endmodule

`default_nettype wire
