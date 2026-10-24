`timescale 1ns / 1ps
`default_nettype none

////////////////////////////////////////////////////////////
// Address Decoder Module
// Routes shared memory requests between D-Cache and MMIO bus
// - 0x1000_0000 to 0x1001_FFFF -> D-Cache (combinational pass-through)
// - 0x2000_0000 to 0x2000_00FF -> MMIO Bus (registered 2-cycle handshake)
// - Unmapped addresses         -> Drops write, returns 0, sets sticky decode_err
////////////////////////////////////////////////////////////

module addr_decode (
    input  wire        clk,
    input  wire        rst,

    // Arbiter / Core Interface (Slave)
    input  wire        req,         // incoming request flag
    input  wire        we,          // write enable flag
    input  wire [31:0] addr,        // target byte address
    input  wire [31:0] wdata,       // data to write
    input  wire [ 3:0] be,          // byte enables for sub-word writes
    input  wire        owner,       // core ID making the request
    output wire [31:0] rdata,       // read data returned to arbiter
    output wire        ready,       // transaction completion flag

    // D-Cache Interface (Master)
    output wire        dc_req,      // request to dcache
    output wire        dc_we,       // write enable to dcache
    output wire [31:0] dc_addr,     // address to dcache
    output wire [31:0] dc_wdata,    // write data to dcache
    output wire [ 3:0] dc_be,       // byte enables to dcache
    output wire        dc_owner,    // core owner passed to dcache
    input  wire [31:0] dc_rdata,    // data read from dcache
    input  wire        dc_ready,    // ready signal from dcache

    // MMIO Bus Interface (Master)
    output reg         io_sel,      // select flag for mmio slave
    output reg         io_we,       // write enable for mmio
    output reg  [ 7:0] io_off,      // register offset within mmio space
    output reg  [31:0] io_wdata,    // write data for mmio
    output reg         io_owner,    // core owner passed to mmio
    input  wire [31:0] io_rdata,    // data read from mmio
    input  wire        io_ready,    // ready signal from mmio

    // Error Status Output
    output reg         decode_err   // sticky flag for unmapped address access (LED2)
);

    ////////////////////////////////////////////////////////////
    // Address Range Decoding
    ////////////////////////////////////////////////////////////

    // checking if address falls in 128 KB data memory range (0x1000_0000 - 0x1001_FFFF)
    wire is_dmem = (addr[31:17] == 15'h0800);

    // checking if address falls in 256 B MMIO peripheral range (0x2000_0000 - 0x2000_00FF)
    wire is_mmio = (addr[31:8]  == 24'h200000);

    ////////////////////////////////////////////////////////////
    // D-Cache Routing (Same-Cycle Pass-Through)
    ////////////////////////////////////////////////////////////

    assign dc_req   = req && is_dmem;
    assign dc_we    = we;
    assign dc_addr  = addr;
    assign dc_wdata = wdata;
    assign dc_be    = be;
    assign dc_owner = owner;

    ////////////////////////////////////////////////////////////
    // MMIO & Unmapped Access Control
    ////////////////////////////////////////////////////////////

    reg  err_rdy;                           // cycle-2 ready response for unmapped access
    wire io_done = io_sel && io_ready;      // mmio transaction finished

    always @(posedge clk) begin
        if (rst) begin
            io_sel     <= 1'b0;
            io_we      <= 1'b0;
            io_off     <= 8'd0;
            io_wdata   <= 32'd0;
            io_owner   <= 1'b0;
            err_rdy    <= 1'b0;
            decode_err <= 1'b0;
        end else begin
            
            // handling MMIO request: raise sel one cycle after request, hold until io_ready
            if (io_sel) begin
                if (io_ready) io_sel <= 1'b0;
            end else if (req && is_mmio) begin
                io_sel   <= 1'b1;
                io_we    <= we;
                io_off   <= addr[7:0];
                io_wdata <= wdata;
                io_owner <= owner;
            end

            // handling unmapped addresses: acknowledge in next cycle and latch sticky error
            err_rdy <= req && !is_dmem && !is_mmio && !err_rdy;
            if (req && !is_dmem && !is_mmio && !err_rdy) begin
                decode_err <= 1'b1;
            end
            
        end
    end

    ////////////////////////////////////////////////////////////
    // Response Multiplexing
    ////////////////////////////////////////////////////////////

    assign ready = dc_ready || io_done || err_rdy;
    assign rdata = dc_ready ? dc_rdata : (io_done ? io_rdata : 32'd0);

endmodule

`default_nettype wire