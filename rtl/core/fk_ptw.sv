// fk-core: Sv32 hardware page table walker with hardware A/D bit update.
// Shared by the ITLB (fetch) and DTLB (load/store). Accesses memory through
// the D-cache so PTE reads/updates are coherent with ordinary loads/stores.
module fk_ptw import fk_pkg::*; #(
  parameter logic [31:0] RAM_BASE = 32'h8000_0000,
  parameter logic [31:0] RAM_SIZE = 32'h0800_0000
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic [21:0] satp_ppn,
  input  logic        flush,          // sfence.vma / satp write: drop in-flight fill
  // I-side request (fetch)
  input  logic        i_req_valid,
  output logic        i_req_ready,
  input  logic [31:0] i_req_vaddr,
  input  logic [1:0]  i_req_priv,
  output logic        i_resp_valid,
  // D-side request (load/store)
  input  logic        d_req_valid,
  output logic        d_req_ready,
  input  logic [31:0] d_req_vaddr,
  input  logic        d_req_store,
  input  logic [1:0]  d_req_priv,
  input  logic        d_req_sum,
  input  logic        d_req_mxr,
  output logic        d_resp_valid,
  // shared response info
  output logic        resp_pf,        // page fault
  output logic        resp_af,        // access fault
  output logic [31:0] resp_vaddr,
  // TLB fill
  output logic        fill_i,
  output logic        fill_d,
  output logic [19:0] fill_vpn,
  output logic [21:0] fill_ppn,
  output logic        fill_mega,
  output pte_flags_t  fill_flags,
  // memory port (to D-cache arbiter)
  output logic        mreq_valid,
  output logic        mreq_store,
  output logic [33:0] mreq_addr,
  output logic [31:0] mreq_wdata,
  output logic        mreq_lock,
  input  logic        mreq_done,
  input  logic [31:0] mreq_rdata,
  input  logic        mreq_err
);
  typedef enum logic [2:0] { S_IDLE, S_READ, S_CHECK, S_WRITE, S_RESP } state_t;
  state_t state_q;

  logic        is_d_q;     // request came from D side
  logic [31:0] vaddr_q;
  logic        store_q, fetch_q, sum_q, mxr_q;
  logic [1:0]  priv_q;
  logic        lvl_q;      // 1 = root level, 0 = leaf level
  logic [21:0] base_q;     // current table PPN
  logic [31:0] pte_q;
  logic        pf_q, af_q, stale_q;

  function automatic logic is_ram(input logic [33:0] pa);
    return (pa[33:32] == 2'b00) && (pa[31:0] >= RAM_BASE) && ((pa[31:0] - RAM_BASE) < RAM_SIZE);
  endfunction

  logic [9:0]  vpn_part;
  logic [33:0] pte_addr;
  assign vpn_part = lvl_q ? vaddr_q[31:22] : vaddr_q[21:12];
  assign pte_addr = {base_q, vpn_part, 2'b00};

  // PTE fields
  logic pv, pr, pw, px, pu, pa, pd;
  assign pv = pte_q[0];
  assign pr = pte_q[1];
  assign pw = pte_q[2];
  assign px = pte_q[3];
  assign pu = pte_q[4];
  assign pa = pte_q[6];
  assign pd = pte_q[7];

  logic perm_ok, need_update, leaf, bad;
  always_comb begin
    bad  = !pv || (!pr && pw);
    leaf = pr || px;
    // privilege check
    if (fetch_q)
      perm_ok = px && ((priv_q == PRV_U) ? pu : !pu);
    else begin
      perm_ok = (store_q ? pw : (pr || (mxr_q && px))) &&
                ((priv_q == PRV_U) ? pu : (!pu || sum_q));
    end
    need_update = !pa || (store_q && !pd);
  end

  assign i_req_ready = (state_q == S_IDLE) && !d_req_valid;
  assign d_req_ready = (state_q == S_IDLE);

  assign mreq_valid = (state_q == S_READ  && is_ram(pte_addr)) || (state_q == S_WRITE);
  assign mreq_store = (state_q == S_WRITE);
  assign mreq_addr  = pte_addr;
  assign mreq_wdata = pte_q | 32'h40 | (store_q ? 32'h80 : 32'h0);
  assign mreq_lock  = (state_q != S_IDLE);

  assign resp_pf      = pf_q && !stale_q && !flush;
  assign resp_af      = af_q && !stale_q && !flush;
  assign resp_vaddr   = vaddr_q;
  assign i_resp_valid = (state_q == S_RESP) && !is_d_q;
  assign d_resp_valid = (state_q == S_RESP) &&  is_d_q;

  // Fill when the leaf is accepted (CHECK without update, or WRITE done)
  logic do_fill;
  always_comb begin
    do_fill = 1'b0;
    if (state_q == S_CHECK && !bad && leaf && !(lvl_q && pte_q[19:10] != 10'd0) && perm_ok && !need_update)
      do_fill = 1'b1;
    if (state_q == S_WRITE && mreq_done && !mreq_err)
      do_fill = 1'b1;
    if (stale_q || flush) do_fill = 1'b0;
  end

  assign fill_i     = do_fill && !is_d_q;
  assign fill_d     = do_fill &&  is_d_q;
  assign fill_vpn   = vaddr_q[31:12];
  assign fill_ppn   = pte_q[31:10];
  assign fill_mega  = lvl_q;
  assign fill_flags = '{d: (state_q == S_WRITE) ? (pd | store_q) : pd,
                        a: 1'b1, g: pte_q[5], u: pu, x: px, w: pw, r: pr};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= S_IDLE;
      is_d_q <= 1'b0; vaddr_q <= '0; store_q <= 1'b0; fetch_q <= 1'b0;
      sum_q <= 1'b0; mxr_q <= 1'b0; priv_q <= PRV_U;
      lvl_q <= 1'b1; base_q <= '0; pte_q <= '0;
      pf_q <= 1'b0; af_q <= 1'b0; stale_q <= 1'b0;
    end else begin
      if (flush && state_q != S_IDLE) stale_q <= 1'b1;
      case (state_q)
        S_IDLE: begin
          pf_q <= 1'b0; af_q <= 1'b0; stale_q <= flush;
          lvl_q <= 1'b1; base_q <= satp_ppn;
          if (d_req_valid) begin
            state_q <= S_READ; is_d_q <= 1'b1; vaddr_q <= d_req_vaddr;
            store_q <= d_req_store; fetch_q <= 1'b0; priv_q <= d_req_priv;
            sum_q <= d_req_sum; mxr_q <= d_req_mxr;
          end else if (i_req_valid) begin
            state_q <= S_READ; is_d_q <= 1'b0; vaddr_q <= i_req_vaddr;
            store_q <= 1'b0; fetch_q <= 1'b1; priv_q <= i_req_priv;
            sum_q <= 1'b0; mxr_q <= 1'b0;
          end
        end
        S_READ: begin
          if (!is_ram(pte_addr)) begin
            af_q <= 1'b1; state_q <= S_RESP;
          end else if (mreq_done) begin
            if (mreq_err) begin
              af_q <= 1'b1; state_q <= S_RESP;
            end else begin
              pte_q <= mreq_rdata; state_q <= S_CHECK;
            end
          end
        end
        S_CHECK: begin
          if (bad) begin
            pf_q <= 1'b1; state_q <= S_RESP;
          end else if (!leaf) begin
            if (!lvl_q) begin
              pf_q <= 1'b1; state_q <= S_RESP;
            end else begin
              lvl_q <= 1'b0; base_q <= pte_q[31:10]; state_q <= S_READ;
            end
          end else if (lvl_q && pte_q[19:10] != 10'd0) begin
            pf_q <= 1'b1; state_q <= S_RESP;        // misaligned superpage
          end else if (!perm_ok) begin
            pf_q <= 1'b1; state_q <= S_RESP;
          end else if (need_update) begin
            state_q <= S_WRITE;
          end else begin
            state_q <= S_RESP;
          end
        end
        S_WRITE: begin
          if (mreq_done) begin
            if (mreq_err) af_q <= 1'b1;
            state_q <= S_RESP;
          end
        end
        S_RESP: begin
          // A walk invalidated by sfence/satp write responds without fault
          // (see resp_pf/resp_af); the requester simply retries.
          state_q <= S_IDLE;
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule
