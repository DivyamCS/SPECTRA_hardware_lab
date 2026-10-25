`timescale 1ns / 1ps
`default_nettype none

module mem_delay (
    input  wire        clk, 
    input  wire        rst, 
    input  wire [1:0]  lat,
    input  wire        start, 
    input  wire        we, 
    input  wire [29:0] addr, 
    input  wire        nwords,
    input  wire [31:0] wdata, 
    input  wire [3:0]  be,
    output wire        rvalid, 
    output wire [31:0] rdata, 
    output wire        wready, 
    output wire        done,
    output wire [29:0] m_addr, 
    output wire        m_we, 
    output wire [3:0]  m_be,
    output wire [31:0] m_wdata, 
    input  wire [31:0] m_rdata
);

    // L = 5, 6, 8, 10 cycles (PROTOCOL.md section 7); cnt starts the cycle after start, so the
    // first word comes when cnt = L - 1
    wire [4:0] L_in = (lat == 2'b00) ? 5'd4 : 
                      (lat == 2'b01) ? 5'd5 : 
                      (lat == 2'b10) ? 5'd7 : 5'd9;
                      
    reg  [4:0] L = 5'd4;            // latency latched at accept, so a lat change mid-burst has no effect
    
    reg        busy   = 1'b0; 
    reg  [4:0] cnt    = 5'd0; 
    reg        we_r   = 1'b0; 
    reg        nw_r   = 1'b0;
    reg [29:0] addr_r = 30'd0; 
    reg  [3:0] be_r   = 4'd0;

    wire [4:0] last   = nw_r ? (L + 5'd3) : L;
    wire       window = busy && (cnt >= L) && (cnt <= last);
    
    assign rvalid = window && !we_r;
    assign wready = window && we_r;
    assign done   = busy && (cnt == last);
    assign rdata  = m_rdata;
    
    wire [4:0] k_wr = cnt - L;
    wire [4:0] k_rd = cnt + 5'd1 - L;
    
    assign m_addr  = addr_r + {25'd0, (we_r ? k_wr : k_rd)};
    assign m_we    = wready;
    assign m_be    = nw_r ? 4'b1111 : be_r;
    assign m_wdata = wdata;
    
    wire accept = start && !busy;              // IF-B: a start in the done cycle is ignored; the next burst starts after done
    
    always @(posedge clk) begin
        if (rst) begin 
            busy   <= 0; 
            cnt    <= 0; 
            we_r   <= 0; 
            nw_r   <= 0; 
            addr_r <= 0; 
            be_r   <= 0; 
        end else if (accept) begin 
            L      <= L_in; 
            busy   <= 1; 
            cnt    <= 0; 
            we_r   <= we; 
            nw_r   <= nwords; 
            addr_r <= addr; 
            be_r   <= be; 
        end else if (busy) begin 
            if (done) begin 
                busy <= 0; 
                cnt  <= 0; 
            end else begin
                cnt  <= cnt + 1; 
            end
        end
    end
endmodule

`default_nettype wire