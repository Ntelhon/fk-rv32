// fk-soc: CLINT (msip, mtimecmp, mtime) for a single hart
module fk_clint #(
  parameter int TICK_DIV = 1   // mtime increments every TICK_DIV cycles
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        req,
  input  logic        we,
  input  logic [15:0] addr,
  input  logic [31:0] wdata,
  input  logic [3:0]  wstrb,
  output logic [31:0] rdata,
  output logic        err,
  output logic        mtip,
  output logic        msip,
  output logic [63:0] mtime
);
  logic [63:0] mtimecmp_q, mtime_q;
  logic        msip_q;
  logic [31:0] div_q;

  assign mtip  = (mtime_q >= mtimecmp_q);
  assign msip  = msip_q;
  assign mtime = mtime_q;

  function automatic logic [31:0] merge(input logic [31:0] old, input logic [31:0] nw, input logic [3:0] s);
    logic [31:0] r;
    for (int b = 0; b < 4; b++) r[8*b +: 8] = s[b] ? nw[8*b +: 8] : old[8*b +: 8];
    return r;
  endfunction

  always_comb begin
    err = 1'b0;
    case ({addr[15:2], 2'b00})
      16'h0000: rdata = {31'b0, msip_q};
      16'h4000: rdata = mtimecmp_q[31:0];
      16'h4004: rdata = mtimecmp_q[63:32];
      16'hBFF8: rdata = mtime_q[31:0];
      16'hBFFC: rdata = mtime_q[63:32];
      default:  rdata = 32'd0;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mtimecmp_q <= '1;
      mtime_q    <= '0;
      msip_q     <= 1'b0;
      div_q      <= '0;
    end else begin
      if (div_q == TICK_DIV - 1) begin
        div_q   <= '0;
        mtime_q <= mtime_q + 64'd1;
      end else begin
        div_q <= div_q + 32'd1;
      end
      if (req && we) begin
        case ({addr[15:2], 2'b00})
          16'h0000: if (wstrb[0]) msip_q <= wdata[0];
          16'h4000: mtimecmp_q[31:0]  <= merge(mtimecmp_q[31:0],  wdata, wstrb);
          16'h4004: mtimecmp_q[63:32] <= merge(mtimecmp_q[63:32], wdata, wstrb);
          16'hBFF8: mtime_q[31:0]     <= merge(mtime_q[31:0],     wdata, wstrb);
          16'hBFFC: mtime_q[63:32]    <= merge(mtime_q[63:32],    wdata, wstrb);
          default: ;
        endcase
      end
    end
  end

endmodule
