// fk-soc: minimal NS16550A-compatible UART (reg-shift 0, byte registers).
// TX is instantaneous (characters go to the simulator via DPI); RX polls the
// simulator for stdin characters.
module fk_uart #(
  parameter int RX_POLL = 4096
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        req,
  input  logic        we,
  input  logic [2:0]  addr,      // byte offset
  input  logic [31:0] wdata,     // lane aligned
  output logic [31:0] rdata,     // register replicated on all lanes
  output logic        err,
  output logic        irq
);
`ifndef SYNTHESIS
  import "DPI-C" function void uart_tx(input byte unsigned c);
  import "DPI-C" function int  uart_rx();
`endif

  logic [7:0] ier_q, lcr_q, mcr_q, scr_q, dll_q, dlm_q, fcr_q;
  logic [7:0] rbr_q;
  logic       dr_q;           // receive data ready
  logic       thre_ip_q;      // THR-empty interrupt pending
  logic [31:0] poll_q;

  logic       dlab;
  logic [7:0] wbyte;
  assign dlab  = lcr_q[7];
  assign wbyte = wdata[8*addr[1:0] +: 8];

  logic [7:0] iir;
  always_comb begin
    if (ier_q[0] && dr_q)           iir = 8'h04;
    else if (ier_q[1] && thre_ip_q) iir = 8'h02;
    else                            iir = 8'h01;
    if (fcr_q[0]) iir = iir | 8'hC0;
  end

  assign irq = (ier_q[0] && dr_q) || (ier_q[1] && thre_ip_q);

  logic [7:0] rreg;
  always_comb begin
    case (addr)
      3'd0: rreg = dlab ? dll_q : rbr_q;
      3'd1: rreg = dlab ? dlm_q : ier_q;
      3'd2: rreg = iir;
      3'd3: rreg = lcr_q;
      3'd4: rreg = mcr_q;
      3'd5: rreg = {1'b0, 1'b1, 1'b1, 4'b0, dr_q};   // TEMT | THRE | DR
      3'd6: rreg = 8'hB0;                          // DCD | DSR | CTS
      default: rreg = scr_q;
    endcase
  end
  assign rdata = {4{rreg}};
  assign err   = 1'b0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ier_q <= '0; lcr_q <= '0; mcr_q <= '0; scr_q <= '0; dll_q <= '0; dlm_q <= '0; fcr_q <= '0;
      rbr_q <= '0; dr_q <= 1'b0; thre_ip_q <= 1'b0; poll_q <= '0;
    end else begin
`ifndef SYNTHESIS
      if (!dr_q) begin
        if (poll_q == RX_POLL) begin
          int c;
          poll_q <= '0;
          c = uart_rx();
          if (c >= 0) begin rbr_q <= c[7:0]; dr_q <= 1'b1; end
        end else begin
          poll_q <= poll_q + 32'd1;
        end
      end
`endif
      if (req && !we) begin
        if (addr == 3'd0 && !dlab) dr_q <= 1'b0;
        if (addr == 3'd2 && iir[3:0] == 4'h2) thre_ip_q <= 1'b0;
      end
      if (req && we) begin
        case (addr)
          3'd0: begin
            if (dlab) dll_q <= wbyte;
            else begin
`ifndef SYNTHESIS
              uart_tx(wbyte);
`endif
              thre_ip_q <= 1'b1;
            end
          end
          3'd1: begin
            if (dlab) dlm_q <= wbyte;
            else begin
              if (wbyte[1] && !ier_q[1]) thre_ip_q <= 1'b1;
              ier_q <= wbyte & 8'h0F;
            end
          end
          3'd2: fcr_q <= wbyte;
          3'd3: lcr_q <= wbyte;
          3'd4: mcr_q <= wbyte;
          3'd7: scr_q <= wbyte;
          default: ;
        endcase
      end
    end
  end

endmodule
