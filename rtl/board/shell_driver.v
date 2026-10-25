`timescale 1ns / 1ps
`default_nettype none
// shell_driver - stands in for core 0 in the board shell (no cores): an IF-A
// master (interfaces.md section 1) that writes RUN_START once after reset (so the streamer sends a
// BEGIN packet), then loops: read SWITCHES, write the value to SEG7 and to LEDS. Every request is
// held until ready, one at a time, exactly as a core's data port.

module shell_driver (
    input  wire        clk,
    input  wire        rst,
    output reg         req,
    output reg         we,
    output reg  [31:0] addr,
    output reg  [31:0] wdata,
    output wire [3:0]  be,
    input  wire [31:0] rdata,
    input  wire        ready
);

    localparam S_START = 2'd0, S_READ = 2'd1, S_SEG = 2'd2, S_LED = 2'd3;
    reg [1:0]  s;
    reg [31:0] sw;

    assign be = 4'hF;

    always @(posedge clk) begin
        if (rst) begin
            s <= S_START; req <= 1'b0;
        end else if (!req) begin                      // present the next request
            req <= 1'b1;
            case (s)
                S_START: begin we <= 1'b1; addr <= 32'h20000014; wdata <= 32'd0; end   // RUN_START
                S_READ:  begin we <= 1'b0; addr <= 32'h20000038; end                  // SWITCHES
                S_SEG:   begin we <= 1'b1; addr <= 32'h20000028; wdata <= sw; end     // SEG7
                default: begin we <= 1'b1; addr <= 32'h20000024; wdata <= sw; end     // LEDS
            endcase
        end else if (ready) begin                     // done: next state, one idle cycle
            req <= 1'b0;
            if (s == S_READ) sw <= {16'd0, rdata[15:0]};
            s <= (s == S_LED) ? S_READ : s + 2'd1;
        end
    end

endmodule

`default_nettype wire
