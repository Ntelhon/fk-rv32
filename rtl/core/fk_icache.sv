// fk-core: blocking direct-mapped instruction cache with AXI4 read master.
// Lookup is combinational (same-cycle hit). 32-byte lines, 8-beat INCR refill.
module fk_icache #(
  parameter int SETS = 256          // 256 x 32 B = 8 KiB
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        flush,        // fence.i
  // lookup
  input  logic        req,          // request a refill on miss
  input  logic [31:0] addr,         // physical address
  output logic        hit,
  output logic [31:0] rdata,
  output logic        err,          // refill of this line failed (bus error)
  // AXI4 read master
  output logic        m_arvalid,
  input  logic        m_arready,
  output logic [31:0] m_araddr,
  output logic [7:0]  m_arlen,
  output logic [2:0]  m_arsize,
  output logic [1:0]  m_arburst,
  input  logic        m_rvalid,
  output logic        m_rready,
  input  logic [31:0] m_rdata,
  input  logic [1:0]  m_rresp,
  input  logic        m_rlast
);
  localparam int IW = $clog2(SETS);
  localparam int TW = 32 - 5 - IW;

  logic [SETS-1:0] valid_q;
  logic [TW-1:0]   tag_q  [SETS];
  logic [31:0]     data_q [SETS][8];

  logic [IW-1:0] idx;
  logic [TW-1:0] tag;
  assign idx = addr[5+IW-1:5];
  assign tag = addr[31:5+IW];

  assign hit   = valid_q[idx] && (tag_q[idx] == tag);
  assign rdata = data_q[idx][addr[4:2]];

  typedef enum logic [1:0] { S_IDLE, S_AR, S_R } state_t;
  state_t state_q;
  logic [31:0] line_q;
  logic [2:0]  beat_q;
  logic        drop_q;      // fence.i during refill: do not validate the line
  logic        rerr_q;
  logic        err_valid_q;
  logic [31:0] err_line_q;

  assign err = err_valid_q && (err_line_q[31:5] == addr[31:5]);

  assign m_arvalid = (state_q == S_AR);
  assign m_araddr  = line_q;
  assign m_arlen   = 8'd7;
  assign m_arsize  = 3'd2;
  assign m_arburst = 2'b01;
  assign m_rready  = (state_q == S_R);

  logic [IW-1:0] fidx;
  assign fidx = line_q[5+IW-1:5];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= S_IDLE;
      valid_q <= '0;
      line_q <= '0; beat_q <= '0; drop_q <= 1'b0; rerr_q <= 1'b0;
      err_valid_q <= 1'b0; err_line_q <= '0;
    end else begin
      if (flush) begin
        valid_q     <= '0;
        err_valid_q <= 1'b0;
        if (state_q != S_IDLE) drop_q <= 1'b1;
      end
      case (state_q)
        S_IDLE: begin
          if (req && !hit && !err && !flush) begin
            state_q <= S_AR;
            line_q  <= {addr[31:5], 5'b0};
            valid_q[idx] <= 1'b0;   // line is overwritten during refill
            beat_q  <= '0;
            drop_q  <= 1'b0;
            rerr_q  <= 1'b0;
            err_valid_q <= 1'b0;
          end
        end
        S_AR: if (m_arready) state_q <= S_R;
        S_R: begin
          if (m_rvalid) begin
            beat_q <= beat_q + 3'd1;
            if (m_rresp[1]) rerr_q <= 1'b1;
            if (m_rlast) begin
              state_q <= S_IDLE;
              if (m_rresp[1] || rerr_q) begin
                err_valid_q <= !(drop_q || flush);
                err_line_q  <= line_q;
                valid_q[fidx] <= 1'b0;
              end else if (!(drop_q || flush)) begin
                valid_q[fidx] <= 1'b1;
              end
            end
          end
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end

  always_ff @(posedge clk) begin
    if (state_q == S_R && m_rvalid) begin
      data_q[fidx][beat_q] <= m_rdata;
      if (beat_q == 3'd0) tag_q[fidx] <= line_q[31:5+IW];
    end
  end

endmodule
