`timescale 1ns / 1ps
`default_nettype none
// tb_core - one core on ideal memory (spec: docs/spec/core.md, tests).
//  * IMEM: 16 KB, imem.hex, synchronous 1-cycle read (as imem_bram).
//  * Data memory: 128 KB at 0x1000_0000 (dmem.hex in the first 32 KB, the rest 0), an IF-A slave
//    that is always ready in cycle 2 (a D-cache hit's timing, interfaces.md section 1 rule 3).
//  * MMIO stub at 0x2000_0000: CORE_ID 0, NCORES 1, CONFIG and SWITCHES = the TB's config word,
//    BARRIER returns 0 at once, LOCK reads 0 (acquired), CYCLES counts from RUN_START to
//    RUN_STOP, BUTTONS 0, core-0 INSTRET counter; writes to other registers are accepted.
//    Any other address reads 0 and is reported as a decode error.
//  * The config word is read from cfg.mem in the run directory (xsim on Windows takes no
//    plusargs). The commit trace is written by the core (SIM) to trace_rtl0.txt.
//  * The run ends at the CHECKSUM write: prints "CHECKSUM <hex> cycles <n> instret <n>", then
//    PASS. FAIL if 100,000 cycles pass with no retired instruction (watchdog), on a decode
//    error, or at the cycle cap from maxcyc.mem (run.py: 4 x rv32sim's cycles + 100,000; a core
//    that loops while retiring would otherwise write an unbounded trace). Default 10 M.

module tb_core;

    reg         clk = 1'b0, rst = 1'b1;
    always #10 clk = ~clk;

    reg  [15:0] cfg_mem [0:0];
    reg  [15:0] cfg = 16'h0093;
    reg  [31:0] maxcyc_mem [0:0];
    integer     max_cycles = 10000000;

    wire        d_req, d_we;
    wire [31:0] d_addr, d_wdata;
    wire [3:0]  d_be;
    reg  [31:0] d_rdata = 32'd0;
    reg         d_ready = 1'b0;
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
    reg [31:0] dmem [0:32767];
    integer i;
    initial begin
        for (i = 0; i < 32768; i = i + 1) dmem[i] = 32'd0;
        $readmemh("imem.hex", imem);
        $readmemh("dmem.hex", dmem, 0, 8191);
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

    // ---------------------------------------------------------------- IF-A slave
    wire        is_dmem = (d_addr[31:17] == 15'h0800);          // 0x1000_0000-0x1001_FFFF
    wire        is_mmio = (d_addr[31:8] == 24'h200000);
    wire [14:0] widx    = d_addr[16:2];
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
            default: mmio_rd = 32'd0;                               // other counters
        endcase
    end

    integer n;
    always @(posedge clk) begin
        d_ready <= 1'b0;
        if (!rst && d_req && !d_ready) begin                        // cycle 1 seen: ready in cycle 2
            d_ready <= 1'b1;
            if (is_dmem) begin
                if (d_we) begin
                    for (n = 0; n < 4; n = n + 1)
                        if (d_be[n]) dmem[widx][8*n +: 8] <= d_wdata[8*n +: 8];
                end else d_rdata <= dmem[widx];
            end else if (is_mmio) begin
                if (d_we) begin
                    case (d_addr[7:0])
                        8'h14: begin counting <= 1'b1; run_cycles = 0; run_instret = 0; end
                        8'h18: counting <= 1'b0;
                        8'h20: begin checksum <= d_wdata; done <= 1'b1; end
                        default: ;
                    endcase
                end else d_rdata <= mmio_rd;
            end else begin
                d_rdata <= 32'd0;
                decode_err <= 1'b1;
                $display("decode error: %s %08h at cycle %0d", d_we ? "store" : "load", d_addr, cycles);
            end
        end
    end

    // ---------------------------------------------------------------- run control
    initial begin
        repeat (3) @(posedge clk);
        #1 rst = 1'b0;
        while (!done && idle < 100000 && cycles < max_cycles && !decode_err) @(posedge clk);
        repeat (4) @(posedge clk);                                  // let the CHECKSUM store retire
        if (done && !decode_err) begin
            $display("CHECKSUM %08h cycles %0d instret %0d (run %0d cycles, %0d instructions)",
                     checksum, cycles, instret, run_cycles, run_instret);
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
