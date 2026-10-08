// fk-core: serializing AXI4 arbiter. Master 0 = I-cache (read only),
// master 1 = D-cache. One transaction in flight at a time; D side has priority.
module fk_axi_arb (
  input  logic        clk,
  input  logic        rst_n,
  // master 0 (I$): read only
  input  logic        s0_arvalid,
  output logic        s0_arready,
  input  logic [31:0] s0_araddr,
  input  logic [7:0]  s0_arlen,
  input  logic [2:0]  s0_arsize,
  input  logic [1:0]  s0_arburst,
  output logic        s0_rvalid,
  input  logic        s0_rready,
  output logic [31:0] s0_rdata,
  output logic [1:0]  s0_rresp,
  output logic        s0_rlast,
  // master 1 (D$)
  input  logic        s1_awvalid,
  output logic        s1_awready,
  input  logic [31:0] s1_awaddr,
  input  logic [7:0]  s1_awlen,
  input  logic [2:0]  s1_awsize,
  input  logic [1:0]  s1_awburst,
  input  logic        s1_wvalid,
  output logic        s1_wready,
  input  logic [31:0] s1_wdata,
  input  logic [3:0]  s1_wstrb,
  input  logic        s1_wlast,
  output logic        s1_bvalid,
  input  logic        s1_bready,
  output logic [1:0]  s1_bresp,
  input  logic        s1_arvalid,
  output logic        s1_arready,
  input  logic [31:0] s1_araddr,
  input  logic [7:0]  s1_arlen,
  input  logic [2:0]  s1_arsize,
  input  logic [1:0]  s1_arburst,
  output logic        s1_rvalid,
  input  logic        s1_rready,
  output logic [31:0] s1_rdata,
  output logic [1:0]  s1_rresp,
  output logic        s1_rlast,
  // downstream master
  output logic        m_awvalid,
  input  logic        m_awready,
  output logic [3:0]  m_awid,
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
  input  logic [3:0]  m_bid,
  input  logic [1:0]  m_bresp,
  output logic        m_arvalid,
  input  logic        m_arready,
  output logic [3:0]  m_arid,
  output logic [31:0] m_araddr,
  output logic [7:0]  m_arlen,
  output logic [2:0]  m_arsize,
  output logic [1:0]  m_arburst,
  input  logic        m_rvalid,
  output logic        m_rready,
  input  logic [3:0]  m_rid,
  input  logic [31:0] m_rdata,
  input  logic [1:0]  m_rresp,
  input  logic        m_rlast
);
  typedef enum logic [1:0] { G_NONE, G_IRD, G_DRD, G_DWR } grant_t;
  grant_t g_q, g;

  // Grant combinationally when idle, then hold until the transaction ends.
  always_comb begin
    g = g_q;
    if (g_q == G_NONE) begin
      if (s1_arvalid)      g = G_DRD;
      else if (s1_awvalid) g = G_DWR;
      else if (s0_arvalid) g = G_IRD;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) g_q <= G_NONE;
    else begin
      g_q <= g;
      if ((g == G_IRD || g == G_DRD) && m_rvalid && m_rready && m_rlast) g_q <= G_NONE;
      if (g == G_DWR && m_bvalid && m_bready) g_q <= G_NONE;
    end
  end

  // AR
  assign m_arvalid  = (g == G_IRD) ? s0_arvalid : (g == G_DRD) ? s1_arvalid : 1'b0;
  assign m_arid     = (g == G_IRD) ? 4'd0 : 4'd1;
  assign m_araddr   = (g == G_IRD) ? s0_araddr  : s1_araddr;
  assign m_arlen    = (g == G_IRD) ? s0_arlen   : s1_arlen;
  assign m_arsize   = (g == G_IRD) ? s0_arsize  : s1_arsize;
  assign m_arburst  = (g == G_IRD) ? s0_arburst : s1_arburst;
  assign s0_arready = (g == G_IRD) && m_arready;
  assign s1_arready = (g == G_DRD) && m_arready;

  // R
  assign m_rready  = (g == G_IRD) ? s0_rready : (g == G_DRD) ? s1_rready : 1'b0;
  assign s0_rvalid = (g == G_IRD) && m_rvalid;
  assign s1_rvalid = (g == G_DRD) && m_rvalid;
  assign s0_rdata  = m_rdata;
  assign s1_rdata  = m_rdata;
  assign s0_rresp  = m_rresp;
  assign s1_rresp  = m_rresp;
  assign s0_rlast  = m_rlast;
  assign s1_rlast  = m_rlast;

  // AW / W / B
  assign m_awvalid  = (g == G_DWR) && s1_awvalid;
  assign m_awid     = 4'd1;
  assign m_awaddr   = s1_awaddr;
  assign m_awlen    = s1_awlen;
  assign m_awsize   = s1_awsize;
  assign m_awburst  = s1_awburst;
  assign s1_awready = (g == G_DWR) && m_awready;
  assign m_wvalid   = (g == G_DWR) && s1_wvalid;
  assign m_wdata    = s1_wdata;
  assign m_wstrb    = s1_wstrb;
  assign m_wlast    = s1_wlast;
  assign s1_wready  = (g == G_DWR) && m_wready;
  assign s1_bvalid  = (g == G_DWR) && m_bvalid;
  assign s1_bresp   = m_bresp;
  assign m_bready   = (g == G_DWR) && s1_bready;

  logic unused;
  assign unused = ^{m_bid, m_rid};

endmodule
