`timescale 1ns / 1ps
`default_nettype none

////////////////////////////////////////////////////////////
// Data Memory (BRAM) Module
// 128 KB memory (32K x 32) with byte enables
// 1-cycle latency synchronous read (read-first policy)
////////////////////////////////////////////////////////////

module dmem_bram #(
    parameter INIT_FILE = "dmem.hex"
) (
    input  wire        clk,
    input  wire [14:0] addr,       // word address (byte address [16:2])
    input  wire        we,         // write enable flag
    input  wire [ 3:0] be,         // byte enables for sub-word writes
    input  wire [31:0] wdata,      // data to write
    output reg  [31:0] rdata       // data read from memory
);

    // Declaring the memory array
    // Forcing block RAM inference so it doesn't consume distributed LUT RAM
    (* ram_style = "block" *) reg [31:0] mem [0:32767];

    ////////////////////////////////////////////////////////////
    // Memory Initialization
    ////////////////////////////////////////////////////////////
    
    integer i;
    initial begin
        // clearing memory to 0 in one line
        for (i = 0; i < 32768; i = i + 1) mem[i] = 32'd0;
        
        // loading firmware/data hex file if specified
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    ////////////////////////////////////////////////////////////
    // Synchronous Read and Write Operations
    ////////////////////////////////////////////////////////////
    
    always @(posedge clk) begin
        
        // writing specific bytes based on byte enable flags
        if (we) begin
            if (be[0]) mem[addr][ 7: 0] <= wdata[ 7: 0];
            if (be[1]) mem[addr][15: 8] <= wdata[15: 8];
            if (be[2]) mem[addr][23:16] <= wdata[23:16];
            if (be[3]) mem[addr][31:24] <= wdata[31:24];
        end
        
        // reading data (returns old data if written in the same cycle)
        rdata <= mem[addr];
        
    end

endmodule

`default_nettype wire