// fk-core: blocking direct-mapped write-through / no-write-allocate data cache.
// - load hit completes combinationally in the request cycle
// - stores are written through to the bus and complete on the B response
// - AMOs are performed in the cache (refill on miss) and written through
// - uncached (MMIO) accesses bypass the arrays and use narrow AXI transfers
// The requester must hold the request stable until done.
module fk_dcache import fk_pkg::*; #(
  parameter int SETS = 256          // 256 x 32 B = 8 KiB
)(
  input  logic        clk,
  input  logic        rst_n,
  // request
  input  logic        req_valid,
  input  dc_op_t      req_op,
  input  amo_op_t     req_amo,
  input  logic [31:0] req_addr,
  input  logic [1:0]  req_size,
  input  logic [31:0] req_wdata,    // lane aligned
  input  logic [3:0]  req_wstrb,
  input  logic        req_uncached,
  output logic        done,
  output logic [31:0] rdata,        // lane aligned word
  output logic        err,
  // AXI4 master
  output logic        m_awvalid,
  input  logic        m_awready,
  output logic [31:0] m_awaddr,
  output logic [7:0]  m_awlen,
  output logic [2:0]  m_awsize,
  output logic [1:0]  m_awburst,
  output logic        m_wvalid,
  input  logic        m_wready,
  output logic [31:0] m_wdata,
  output logic [3:0]  m_wstrb,
  output logic        m_wlast,
  input  logic        m_bvalid,
  output logic        m_bready,
  input  logic [1:0]  m_bresp,
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
  logic [2:0]    word;
  logic          hit;
  logic [31:0]   line_word;
  assign idx       = req_addr[5+IW-1:5];
  assign tag       = req_addr[31:5+IW];
  assign word      = req_addr[4:2];
  assign hit       = valid_q[idx] && (tag_q[idx] == tag);
  assign line_word = data_q[idx][word];

  function automatic logic [31:0] amo_alu(input amo_op_t op, input logic [31:0] a, input logic [31:0] b);
    case (op)
      AMO_SWAP: return b;
      AMO_ADD:  return a + b;
      AMO_XOR:  return a ^ b;
      AMO_AND:  return a & b;
      AMO_OR:   return a | b;
      AMO_MIN:  return ($signed(a) < $signed(b)) ? a : b;
      AMO_MAX:  return ($signed(a) < $signed(b)) ? b : a;
      AMO_MINU: return (a < b) ? a : b;
      AMO_MAXU: return (a < b) ? b : a;
      default:  return b;
    endcase
  endfunction

  typedef enum logic [2:0] { S_IDLE, S_RF_AR, S_RF_R, S_UC_AR, S_UC_R, S_W } state_t;
  state_t state_q;

  logic [31:0] addr_q;
  logic [2:0]  size_q;
  logic [31:0] wdata_q, old_q;
  logic [3:0]  wstrb_q;
  logic        aw_done_q, w_done_q;
  logic [2:0]  beat_q;
  logic        rerr_q;

  logic [IW-1:0] ridx;
  assign ridx = addr_q[5+IW-1:5];

  // AXI outputs
  assign m_arvalid = (state_q == S_RF_AR) || (state_q == S_UC_AR);
  assign m_araddr  = addr_q;
  assign m_arlen   = (state_q == S_RF_AR) ? 8'd7 : 8'd0;
  assign m_arsize  = size_q;
  assign m_arburst = 2'b01;
  assign m_rready  = (state_q == S_RF_R) || (state_q == S_UC_R);

  assign m_awvalid = (state_q == S_W) && !aw_done_q;
  assign m_awaddr  = addr_q;
  assign m_awlen   = 8'd0;
  assign m_awsize  = size_q;
  assign m_awburst = 2'b01;
  assign m_wvalid  = (state_q == S_W) && !w_done_q;
  assign m_wdata   = wdata_q;
  assign m_wstrb   = wstrb_q;
  assign m_wlast   = 1'b1;
  assign m_bready  = (state_q == S_W);

  // Completion
  always_comb begin
    done  = 1'b0;
    err   = 1'b0;
    rdata = line_word;
    case (state_q)
      S_IDLE: begin
        if (req_valid && !req_uncached && req_op == DC_LOAD && hit) done = 1'b1;
      end
      S_RF_R: begin
        if (m_rvalid && m_rlast && (m_rresp[1] || rerr_q)) begin
          done = 1'b1; err = 1'b1;
        end
      end
      S_UC_R: begin
        if (m_rvalid) begin
          done = 1'b1; err = m_rresp[1]; rdata = m_rdata;
        end
      end
      S_W: begin
        if (m_bvalid) begin
          done = 1'b1; err = m_bresp[1]; rdata = old_q;
        end
      end
      default: ;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= S_IDLE;
      valid_q <= '0;
      addr_q <= '0; size_q <= '0; wdata_q <= '0; old_q <= '0; wstrb_q <= '0;
      aw_done_q <= 1'b0; w_done_q <= 1'b0; beat_q <= '0; rerr_q <= 1'b0;
    end else begin
      case (state_q)
        S_IDLE: begin
          aw_done_q <= 1'b0;
          w_done_q  <= 1'b0;
          beat_q    <= '0;
          rerr_q    <= 1'b0;
          if (req_valid) begin
            if (req_uncached) begin
              addr_q  <= req_addr;
              size_q  <= {1'b0, req_size};
              wdata_q <= req_wdata;
              wstrb_q <= req_wstrb;
              old_q   <= '0;
              state_q <= (req_op == DC_LOAD) ? S_UC_AR : S_W;
            end else if (req_op == DC_STORE) begin
              addr_q  <= req_addr;
              size_q  <= {1'b0, req_size};
              wdata_q <= req_wdata;
              wstrb_q <= req_wstrb;
              old_q   <= '0;
              state_q <= S_W;
            end else if (!hit) begin
              addr_q  <= {req_addr[31:5], 5'b0};
              size_q  <= 3'd2;
              valid_q[idx] <= 1'b0;
              state_q <= S_RF_AR;
            end else if (req_op == DC_AMO) begin
              addr_q  <= {req_addr[31:2], 2'b00};
              size_q  <= 3'd2;
              old_q   <= line_word;
              wdata_q <= amo_alu(req_amo, line_word, req_wdata);
              wstrb_q <= 4'hF;
              state_q <= S_W;
            end
          end
        end
        S_RF_AR: if (m_arready) state_q <= S_RF_R;
        S_RF_R: begin
          if (m_rvalid) begin
            beat_q <= beat_q + 3'd1;
            if (m_rresp[1]) rerr_q <= 1'b1;
            if (m_rlast) begin
              state_q <= S_IDLE;
              valid_q[ridx] <= !(m_rresp[1] || rerr_q);
            end
          end
        end
        S_UC_AR: if (m_arready) state_q <= S_UC_R;
        S_UC_R:  if (m_rvalid) state_q <= S_IDLE;
        S_W: begin
          if (m_awready) aw_done_q <= 1'b1;
          if (m_wready)  w_done_q  <= 1'b1;
          if (m_bvalid)  state_q   <= S_IDLE;
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end

  // Data/tag arrays
  always_ff @(posedge clk) begin
    if (state_q == S_RF_R && m_rvalid) begin
      data_q[ridx][beat_q] <= m_rdata;
      if (beat_q == 3'd0) tag_q[ridx] <= addr_q[31:5+IW];
    end
    // write-through update on store/AMO completion (cache hit only)
    if (state_q == S_W && m_bvalid && !m_bresp[1] && !req_uncached && hit) begin
      for (int b = 0; b < 4; b++)
        if (wstrb_q[b]) data_q[idx][word][8*b +: 8] <= wdata_q[8*b +: 8];
    end
  end

endmodule
