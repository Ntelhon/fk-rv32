// fk-soc: AXI4 slave -> simple register bus bridge (one transaction at a time,
// INCR/FIXED bursts). The simple bus has combinational read data; s_req is a
// one-cycle strobe per beat so devices can implement read side effects.
module fk_axi2simple (
  input  logic        clk,
  input  logic        rst_n,
  // AXI4 slave
  input  logic        s_awvalid,
  output logic        s_awready,
  input  logic [3:0]  s_awid,
  input  logic [31:0] s_awaddr,
  input  logic [7:0]  s_awlen,
  input  logic [2:0]  s_awsize,
  input  logic [1:0]  s_awburst,
  input  logic        s_wvalid,
  output logic        s_wready,
  input  logic [31:0] s_wdata,
  input  logic [3:0]  s_wstrb,
  input  logic        s_wlast,
  output logic        s_bvalid,
  input  logic        s_bready,
  output logic [3:0]  s_bid,
  output logic [1:0]  s_bresp,
  input  logic        s_arvalid,
  output logic        s_arready,
  input  logic [3:0]  s_arid,
  input  logic [31:0] s_araddr,
  input  logic [7:0]  s_arlen,
  input  logic [2:0]  s_arsize,
  input  logic [1:0]  s_arburst,
  output logic        s_rvalid,
  input  logic        s_rready,
  output logic [3:0]  s_rid,
  output logic [31:0] s_rdata,
  output logic [1:0]  s_rresp,
  output logic        s_rlast,
  // simple bus
  output logic        b_req,
  output logic        b_we,
  output logic [31:0] b_addr,
  output logic [2:0]  b_size,
  output logic [31:0] b_wdata,
  output logic [3:0]  b_wstrb,
  input  logic [31:0] b_rdata,
  input  logic        b_err
);
  typedef enum logic [1:0] { S_IDLE, S_RD, S_WR, S_B } state_t;
  state_t state_q;

  logic [31:0] addr_q;
  logic [7:0]  len_q, cnt_q;
  logic [2:0]  size_q;
  logic [1:0]  burst_q;
  logic [3:0]  id_q;
  logic        err_q;

  logic [31:0] next_addr;
  assign next_addr = (burst_q == 2'b00) ? addr_q : (addr_q + (32'd1 << size_q));

  assign s_awready = (state_q == S_IDLE) && !s_arvalid;
  assign s_arready = (state_q == S_IDLE);
  assign s_wready  = (state_q == S_WR);
  assign s_bvalid  = (state_q == S_B);
  assign s_bid     = id_q;
  assign s_bresp   = err_q ? 2'b10 : 2'b00;
  assign s_rvalid  = (state_q == S_RD);
  assign s_rid     = id_q;
  assign s_rdata   = b_rdata;
  assign s_rresp   = b_err ? 2'b10 : 2'b00;
  assign s_rlast   = (cnt_q == len_q);

  assign b_addr  = addr_q;
  assign b_size  = size_q;
  assign b_wdata = s_wdata;
  assign b_wstrb = s_wstrb;
  assign b_we    = (state_q == S_WR);
  assign b_req   = ((state_q == S_RD) && s_rready) || ((state_q == S_WR) && s_wvalid);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= S_IDLE;
      addr_q <= '0; len_q <= '0; cnt_q <= '0; size_q <= '0; burst_q <= '0; id_q <= '0; err_q <= 1'b0;
    end else begin
      case (state_q)
        S_IDLE: begin
          cnt_q <= '0;
          err_q <= 1'b0;
          if (s_arvalid) begin
            addr_q <= s_araddr; len_q <= s_arlen; size_q <= s_arsize; burst_q <= s_arburst; id_q <= s_arid;
            state_q <= S_RD;
          end else if (s_awvalid) begin
            addr_q <= s_awaddr; len_q <= s_awlen; size_q <= s_awsize; burst_q <= s_awburst; id_q <= s_awid;
            state_q <= S_WR;
          end
        end
        S_RD: begin
          if (s_rready) begin
            addr_q <= next_addr;
            cnt_q  <= cnt_q + 8'd1;
            if (cnt_q == len_q) state_q <= S_IDLE;
          end
        end
        S_WR: begin
          if (s_wvalid) begin
            addr_q <= next_addr;
            if (b_err) err_q <= 1'b1;
            if (s_wlast) state_q <= S_B;
          end
        end
        S_B: if (s_bready) state_q <= S_IDLE;
        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule
