`timescale 1ns / 1ps
`default_nettype none

//=============================================================================
// Module: mmio_bus
// Description:
//   MMIO registers at 0x2000_0000. IF-C slave protocol.
//   Handles routing to read-only inputs, debounced buttons, a free-running
//   timer, performance counters, output LEDs, 7-segment displays, and streamer 
//   events. All writes to event triggers emit a 1-cycle pulse.
//=============================================================================

module mmio_bus #(
    parameter integer DEB_BITS = 16
) (
    input  wire        clk,
    input  wire        rst,

    //-------------------------------------------------------------------------
    // IF-C Slave Interface
    //-------------------------------------------------------------------------
    input  wire        sel,
    input  wire        we,
    input  wire [7:0]  off,
    input  wire [31:0] wdata,
    input  wire        owner,
    output reg  [31:0] rdata,
    output wire        ready,

    //-------------------------------------------------------------------------
    // Configuration and Inputs
    //-------------------------------------------------------------------------
    input  wire [15:0] cfg,
    input  wire [1:0]  ncores,
    input  wire [15:0] sw_live,
    input  wire [3:0]  btn,            // BTNL, BTNR, BTNU, BTND (raw)

    //-------------------------------------------------------------------------
    // Lock & Barrier Interface
    //-------------------------------------------------------------------------
    output wire        lock_rd,
    output wire        lock_wr0,
    input  wire        lock_rdata,

    //-------------------------------------------------------------------------
    // Performance Counters Interface
    //-------------------------------------------------------------------------
    output wire        run_start,
    output wire        run_stop,
    output reg  [3:0]  rd_sel,
    input  wire [31:0] rd_data,

    //-------------------------------------------------------------------------
    // Output Registers
    //-------------------------------------------------------------------------
    output reg  [15:0] leds,
    output reg  [26:0] seg7_val,
    output reg  [7:0]  seg7_dp,
    output reg  [31:0] seg7_txt,

    //-------------------------------------------------------------------------
    // Streamer Events (1-cycle pulses with their data)
    //-------------------------------------------------------------------------
    output wire        st_gen_done,
    output wire        st_checksum,
    output wire        st_row_done,
    output wire        st_mrow_done,
    output wire [31:0] st_data,
    output wire        st_owner
);

    // Decoding shortcuts
    wire is_read  = sel && !we;
    wire is_write = sel && we;
    
    assign ready = sel;

    // Sub-module routing and triggers
    assign lock_rd      = is_read  && (off == 8'h10);
    assign lock_wr0     = is_write && (off == 8'h10) && (wdata == 32'd0);
    assign run_start    = is_write && (off == 8'h14);
    assign run_stop     = is_write && (off == 8'h18);
    assign st_gen_done  = is_write && (off == 8'h1C);
    assign st_checksum  = is_write && (off == 8'h20);
    assign st_row_done  = is_write && (off == 8'h2C);
    assign st_mrow_done = is_write && (off == 8'h30);
    assign st_data      = wdata;
    assign st_owner     = owner;

    //-------------------------------------------------------------------------
    // Buttons: Synchronize and Debounce
    //-------------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg [3:0] btn_sync1_q;
    (* ASYNC_REG = "TRUE" *) reg [3:0] btn_sync2_q;
    reg [3:0]            btn_live_q;
    reg [DEB_BITS-1:0]   btn_cnt_q [0:3];
    integer i;

    initial begin
        btn_sync1_q = 4'd0; 
        btn_sync2_q = 4'd0; 
        btn_live_q  = 4'd0;
        for (i = 0; i < 4; i = i + 1) begin
            btn_cnt_q[i] = {DEB_BITS{1'b0}};
        end
    end

    always @(posedge clk) begin
        btn_sync1_q <= btn; 
        btn_sync2_q <= btn_sync1_q;
        
        for (i = 0; i < 4; i = i + 1) begin
            if (btn_sync2_q[i] == btn_live_q[i]) begin
                btn_cnt_q[i] <= {DEB_BITS{1'b0}};
            end else if (btn_cnt_q[i] == {DEB_BITS{1'b1}}) begin 
                btn_live_q[i] <= btn_sync2_q[i]; 
                btn_cnt_q[i]  <= {DEB_BITS{1'b0}}; 
            end else begin
                btn_cnt_q[i] <= btn_cnt_q[i] + 1'b1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // Timer (Free-running)
    //-------------------------------------------------------------------------
    reg [31:0] timer_q = 32'd0;
    
    always @(posedge clk) begin
        timer_q <= rst ? 32'd0 : timer_q + 32'd1;
    end

    //-------------------------------------------------------------------------
    // Performance Counters Decode
    // 0x34 = CYCLES; 0x50 + 0x20k + 4j -> index 1 + 8k + j
    //-------------------------------------------------------------------------
    always @(*) begin
        rd_sel = 4'd8; // Default: 8 reads 0
        if (off == 8'h34) begin
            rd_sel = 4'd0;
        end else if (off >= 8'h50 && off <= 8'h68) begin
            rd_sel = 4'd1 + ((off - 8'h50) >> 2);
        end else if (off >= 8'h70 && off <= 8'h88) begin
            rd_sel = 4'd9 + ((off - 8'h70) >> 2);
        end
    end
    
    wire is_counter = (off == 8'h34) || (off >= 8'h50 && off <= 8'h68) || (off >= 8'h70 && off <= 8'h88);

    //-------------------------------------------------------------------------
    // Read Data Multiplexer
    //-------------------------------------------------------------------------
    always @(*) begin
        rdata = 32'd0;
        if (is_read) begin
            case (off)
                8'h00:   rdata = {31'd0, owner};         // CORE_ID
                8'h04:   rdata = {30'd0, ncores};        // NCORES
                8'h08:   rdata = {16'd0, cfg};           // CONFIG
                8'h0C:   rdata = 32'd0;                  // BARRIER (normally parked in rr_arbiter)
                8'h10:   rdata = {31'd0, lock_rdata};    // LOCK: test-and-set
                8'h38:   rdata = {16'd0, sw_live};       // SWITCHES
                8'h3C:   rdata = {28'd0, btn_live_q};    // BUTTONS
                8'h44:   rdata = timer_q;                // TIMER
                default: rdata = is_counter ? rd_data : 32'd0;
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // Write Registers
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            leds     <= 16'd0; 
            seg7_val <= 27'd0; 
            seg7_dp  <= 8'd0; 
            seg7_txt <= 32'd0;
        end else if (is_write) begin
            case (off)
                8'h24:   leds     <= wdata[15:0];
                8'h28:   seg7_val <= wdata[26:0];
                8'h40:   seg7_dp  <= wdata[7:0];
                8'h48:   seg7_txt <= wdata;
                default: ; // Ignore other writes
            endcase
        end
    end

endmodule

`default_nettype wire