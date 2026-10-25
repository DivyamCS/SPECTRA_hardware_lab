`timescale 1ns / 1ps
`default_nettype none
// soc_top - the SPECTRA SoC without pins, everything on the 50 MHz clock (spec:
// docs/spec/top_fpga.md). Wrapper only: two cores (core 1 = the same RTL with HART_ID 1, held in
// reset unless DUAL), core_ctrl, imem_bram (port A core 0, port B core 1), rr_arbiter (BARRIER
// reads parked there), addr_decode, dcache -> mem_delay -> dmem_bram, mmio_bus, lock_barrier,
// perf_counters, result_streamer (snooping every store on the shared data port), uart_top,
// seg7_bcd and switch_cfg. LED2 = decode_err, the other LEDs = the LEDS register.
// top_fpga adds clk_rst, vio_hook and the pins. DEB_BITS shortens the debouncers in simulation.
// HAS_CORES = 0 (the board shell): shell_driver on data port 0 instead of the cores.

module soc_top #(
    parameter HAS_CORES = 1,
    parameter HAS_CORE1 = 1,
    parameter HAS_MD     = 1,          // removal parameters, passed to both cores and the D-cache
    parameter HAS_FWD    = 1,          // (area builds)
    parameter HAS_ICACHE = 1,
    parameter HAS_DCACHE = 1,
    parameter DEB_BITS  = 16,
    parameter IMEM_FILE = "imem.hex",
    parameter DMEM_FILE = "dmem.hex"
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [15:0] sw,             // switches (asynchronous)
    input  wire [3:0]  btn,            // BTNL, BTNR, BTNU, BTND (asynchronous)
    output wire [15:0] led,
    output wire [7:0]  an,
    output wire [6:0]  seg,
    output wire        dp_n,
    output wire        uart_tx,
    // probes (VIO, testbenches)
    output wire [26:0] seg7_val,
    output wire [7:0]  seg7_dp,
    output wire [31:0] seg7_txt,
    output wire        uart_busy
);

    // ------------------------------------------------------------ configuration, resets
    wire [15:0] cfg, sw_live;
    wire        rst0, rst1;
    wire [1:0]  ncores;
    switch_cfg #(.DEB_BITS(DEB_BITS)) u_cfg (.clk(clk), .rst(rst), .sw(sw), .cfg(cfg), .sw_live(sw_live));
    core_ctrl  #(.HAS_CORE1(HAS_CORE1)) u_ctrl (.clk(clk), .rst(rst), .cfg_dual(cfg[2]),
                                                .rst_core0(rst0), .rst_core1(rst1), .ncores(ncores));

    // ------------------------------------------------------------ cores and IMEM
    wire        req0, we0, rdy0, req1, we1, rdy1;
    wire [31:0] addr0, wdata0, rdata0, addr1, wdata1, rdata1;
    wire [3:0]  be0, be1;
    wire [11:0] ia0, ia1;
    wire [31:0] ir0, ir1;
    wire [1:0]  ev_instret, ev_ihit, ev_imiss;

    generate
        if (HAS_CORES != 0) begin : g_core0
            core #(.HART_ID(0), .HAS_MD(HAS_MD), .HAS_FWD(HAS_FWD), .HAS_ICACHE(HAS_ICACHE)) u_core0 (.clk(clk), .rst(rst0), .cfg(cfg),
                .d_req(req0), .d_we(we0), .d_addr(addr0), .d_wdata(wdata0), .d_be(be0), .d_rdata(rdata0),
                .d_ready(rdy0), .imem_addr(ia0), .imem_rdata(ir0),
                .ev_instret(ev_instret[0]), .ev_ihit(ev_ihit[0]), .ev_imiss(ev_imiss[0]));
        end else begin : g_shell
            shell_driver u_drv (.clk(clk), .rst(rst0), .req(req0), .we(we0), .addr(addr0),
                .wdata(wdata0), .be(be0), .rdata(rdata0), .ready(rdy0));
            assign ia0 = 12'd0;
            assign ev_instret[0] = 1'b0; assign ev_ihit[0] = 1'b0; assign ev_imiss[0] = 1'b0;
        end
        if (HAS_CORES != 0 && HAS_CORE1 != 0) begin : g_core1
            core #(.HART_ID(1), .HAS_MD(HAS_MD), .HAS_FWD(HAS_FWD), .HAS_ICACHE(HAS_ICACHE)) u_core1 (.clk(clk), .rst(rst1), .cfg(cfg),
                .d_req(req1), .d_we(we1), .d_addr(addr1), .d_wdata(wdata1), .d_be(be1), .d_rdata(rdata1),
                .d_ready(rdy1), .imem_addr(ia1), .imem_rdata(ir1),
                .ev_instret(ev_instret[1]), .ev_ihit(ev_ihit[1]), .ev_imiss(ev_imiss[1]));
        end else begin : g_no_core1
            assign req1 = 1'b0; assign we1 = 1'b0; assign addr1 = 32'd0; assign wdata1 = 32'd0;
            assign be1 = 4'd0; assign ia1 = 12'd0;
            assign ev_instret[1] = 1'b0; assign ev_ihit[1] = 1'b0; assign ev_imiss[1] = 1'b0;
        end
    endgenerate

    imem_bram #(.INIT_FILE(IMEM_FILE)) u_imem (.clk(clk), .addr_a(ia0), .rdata_a(ir0), .addr_b(ia1), .rdata_b(ir1));

    // ------------------------------------------------------------ shared data port
    wire        m_req, m_we, m_owner, m_ready, ev_arb0, ev_arb1;
    wire [31:0] m_addr, m_wdata, m_rdata;
    wire [3:0]  m_be;
    wire [1:0]  bar_req, bar_release;
    rr_arbiter u_arb (.clk(clk), .rst(rst),
        .req0(req0), .we0(we0), .addr0(addr0), .wdata0(wdata0), .be0(be0), .rdata0(rdata0), .ready0(rdy0),
        .req1(req1), .we1(we1), .addr1(addr1), .wdata1(wdata1), .be1(be1), .rdata1(rdata1), .ready1(rdy1),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata), .m_be(m_be), .m_owner(m_owner),
        .m_rdata(m_rdata), .m_ready(m_ready), .bar_req(bar_req), .bar_release(bar_release),
        .ev_arbwait0(ev_arb0), .ev_arbwait1(ev_arb1));

    wire        dc_req, dc_we, dc_owner, dc_ready, io_sel, io_we, io_owner, io_ready, decode_err;
    wire [31:0] dc_addr, dc_wdata, dc_rdata, io_wdata, io_rdata;
    wire [3:0]  dc_be;
    wire [7:0]  io_off;
    addr_decode u_dec (.clk(clk), .rst(rst),
        .req(m_req), .we(m_we), .addr(m_addr), .wdata(m_wdata), .be(m_be), .owner(m_owner),
        .rdata(m_rdata), .ready(m_ready),
        .dc_req(dc_req), .dc_we(dc_we), .dc_addr(dc_addr), .dc_wdata(dc_wdata), .dc_be(dc_be),
        .dc_owner(dc_owner), .dc_rdata(dc_rdata), .dc_ready(dc_ready),
        .io_sel(io_sel), .io_we(io_we), .io_off(io_off), .io_wdata(io_wdata), .io_owner(io_owner),
        .io_rdata(io_rdata), .io_ready(io_ready), .decode_err(decode_err));

    // ------------------------------------------------------------ D-cache, memory
    wire        ms, mwe, mnw, mrv, mwr, mdn, bwe, ev_dhit, ev_dmiss, ev_downer;
    wire [29:0] ma, ba;
    wire [31:0] mwd, mrd, bwd, brd;
    wire [3:0]  mbe, bbe;
    dcache #(.HAS_DCACHE(HAS_DCACHE)) u_dc (.clk(clk), .rst(rst), .cfg_dc(cfg[1]),
        .req(dc_req), .we(dc_we), .addr(dc_addr), .wdata(dc_wdata), .be(dc_be), .owner(dc_owner),
        .rdata(dc_rdata), .ready(dc_ready),
        .m_start(ms), .m_we(mwe), .m_addr(ma), .m_nwords(mnw), .m_wdata(mwd), .m_be(mbe),
        .m_rvalid(mrv), .m_rdata(mrd), .m_wready(mwr), .m_done(mdn),
        .ev_hit(ev_dhit), .ev_miss(ev_dmiss), .ev_owner(ev_downer));
    mem_delay u_dmd (.clk(clk), .rst(rst), .lat(cfg[4:3]), .start(ms), .we(mwe), .addr(ma), .nwords(mnw),
        .wdata(mwd), .be(mbe), .rvalid(mrv), .rdata(mrd), .wready(mwr), .done(mdn),
        .m_addr(ba), .m_we(bwe), .m_be(bbe), .m_wdata(bwd), .m_rdata(brd));
    dmem_bram #(.INIT_FILE(DMEM_FILE)) u_dmem (.clk(clk), .addr(ba[14:0]), .we(bwe), .be(bbe), .wdata(bwd), .rdata(brd));

    // ------------------------------------------------------------ MMIO and its blocks
    wire        lock_rd, lock_wr0, lock_rdata, run_start, run_stop, ev_bar0, ev_bar1;
    wire [3:0]  rd_sel;
    wire [31:0] rd_data, st_data;
    wire [479:0] snap;
    wire [15:0] leds;
    wire        st_gen, st_chk, st_row, st_mrow, st_owner;
    mmio_bus #(.DEB_BITS(DEB_BITS)) u_mmio (.clk(clk), .rst(rst),
        .sel(io_sel), .we(io_we), .off(io_off), .wdata(io_wdata), .owner(io_owner), .rdata(io_rdata), .ready(io_ready),
        .cfg(cfg), .ncores(ncores), .sw_live(sw_live), .btn(btn),
        .lock_rd(lock_rd), .lock_wr0(lock_wr0), .lock_rdata(lock_rdata),
        .run_start(run_start), .run_stop(run_stop), .rd_sel(rd_sel), .rd_data(rd_data),
        .leds(leds), .seg7_val(seg7_val), .seg7_dp(seg7_dp), .seg7_txt(seg7_txt),
        .st_gen_done(st_gen), .st_checksum(st_chk), .st_row_done(st_row), .st_mrow_done(st_mrow),
        .st_data(st_data), .st_owner(st_owner));
    lock_barrier u_lb (.clk(clk), .rst(rst), .ncores(ncores), .lock_rd(lock_rd), .lock_wr0(lock_wr0),
        .owner(io_owner), .lock_rdata(lock_rdata), .bar_req(bar_req), .bar_release(bar_release),
        .ev_barwait0(ev_bar0), .ev_barwait1(ev_bar1));
    perf_counters u_pc (.clk(clk), .rst(rst), .run_start(run_start), .run_stop(run_stop),
        .ev_instret(ev_instret), .ev_ihit(ev_ihit), .ev_imiss(ev_imiss), .ev_arbwait({ev_arb1, ev_arb0}),
        .ev_barwait({ev_bar1, ev_bar0}), .ev_dhit(ev_dhit), .ev_dmiss(ev_dmiss), .ev_downer(ev_downer),
        .rd_sel(rd_sel), .rd_data(rd_data), .snap(snap));

    // ------------------------------------------------------------ streamer, UART, display
    wire        u_wr, u_full, u_busy;
    wire [7:0]  u_data;
    result_streamer u_st (.clk(clk), .rst(rst), .cfg(cfg), .ncores(ncores),
        .snoop_we(m_we), .snoop_addr(m_addr), .snoop_wdata(m_wdata), .snoop_be(m_be),
        .snoop_done(m_req && m_ready),
        .ev_run_start(run_start), .ev_gen_done(st_gen), .gen_word(st_data),
        .ev_row_done(st_row), .ev_mrow_done(st_mrow), .ev_owner(st_owner), .ev_row(st_data),
        .ev_checksum(st_chk), .checksum(st_data), .snap(snap),
        .wr(u_wr), .wr_data(u_data), .full(u_full), .tx_busy(u_busy), .uart_busy(uart_busy));
    uart_top u_uart (.clk(clk), .rst(rst), .wr(u_wr), .wr_data(u_data), .full(u_full), .busy(u_busy), .tx(uart_tx));
    seg7_bcd u_seg (.clk(clk), .rst(rst), .value(seg7_val), .dp(seg7_dp), .txt(seg7_txt), .an(an), .seg(seg), .dp_n(dp_n));

    assign led = {leds[15:3], decode_err, leds[1:0]};

endmodule

`default_nettype wire
