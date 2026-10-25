`timescale 1ns / 1ps
`default_nettype none
// switch_cfg - switches to the IF-D config word (spec: docs/spec/switch_cfg.md, interfaces.md 4).
// Every switch: a 2-flop synchroniser, then a debounce with its own counter (a bit of sw_live
// changes only after the synchronised bit has differed from it for 2^DEB_BITS cycles in a row;
// 2^16 = 1.3 ms at 50 MHz). cfg_r follows sw_live in every reset cycle, so it holds the value of
// the cycle reset releases; cfg is 0 during reset and that value from the first cycle after,
// constant until the next reset. The synchronisers and debouncers run during reset too.

module switch_cfg #(
    parameter DEB_BITS = 16
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [15:0] sw,             // after the VIO override mux, asynchronous
    output wire [15:0] cfg,
    output reg  [15:0] sw_live
);

    (* ASYNC_REG = "TRUE" *) reg [15:0] s1, s2;
    reg [15:0] cfg_r;
    reg [DEB_BITS-1:0] cnt [0:15];

    integer i;
    initial begin
        s1 = 16'd0; s2 = 16'd0; sw_live = 16'd0; cfg_r = 16'd0;
        for (i = 0; i < 16; i = i + 1) cnt[i] = {DEB_BITS{1'b0}};
    end

    always @(posedge clk) begin
        s1 <= sw;
        s2 <= s1;
        for (i = 0; i < 16; i = i + 1) begin
            if (s2[i] == sw_live[i]) begin
                cnt[i] <= {DEB_BITS{1'b0}};
            end else if (cnt[i] == {DEB_BITS{1'b1}}) begin
                sw_live[i] <= s2[i];            // stable for 2^DEB_BITS cycles
                cnt[i] <= {DEB_BITS{1'b0}};
            end else begin
                cnt[i] <= cnt[i] + 1'b1;
            end
        end
        if (rst) cfg_r <= sw_live;
    end

    assign cfg = rst ? 16'd0 : cfg_r;

endmodule

`default_nettype wire
