// fk-core: 5-stage in-order RV32IMA_Zicsr_Zifencei core with Sv32 MMU and M/S/U modes.
//
//   IF  : PC, ITLB lookup, I-cache lookup (combinational hit)
//   ID  : decode, register read (WB bypass)
//   EX  : ALU / single-cycle multiplier / iterative divider, branch resolve (static not-taken)
//   MEM : DTLB + D-cache access, CSRs, traps/interrupts, xRET, fences  (commit point)
//   WB  : register write
//
// Full forwarding from MEM and WB into EX (including load data), so there is
// no load-use stall. Every instruction that changes architectural state used
// by younger instructions (CSR writes, xRET, sfence.vma, fence.i) flushes the
// pipeline and refetches.
module fk_core import fk_pkg::*; #(
  parameter logic [31:0] RESET_PC     = 32'h0000_1000,
  parameter logic [31:0] RAM_BASE     = 32'h8000_0000,
  parameter logic [31:0] RAM_SIZE     = 32'h0800_0000,
  parameter logic [31:0] ROM_BASE     = 32'h0000_1000,
  parameter logic [31:0] ROM_SIZE     = 32'h0000_F000,
  parameter int          ICACHE_SETS  = 256,
  parameter int          DCACHE_SETS  = 256,
  parameter int          ITLB_ENTRIES = 16,
  parameter int          DTLB_ENTRIES = 16,
  parameter logic [31:0] HART_ID      = 32'd0
)(
  input  logic        clk,
  input  logic        rst_n,
  // interrupts
  input  logic        irq_mtip,
  input  logic        irq_msip,
  input  logic        irq_meip,
  input  logic        irq_seip,
  input  logic [63:0] mtime,
  // AXI4 master
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

  // Physical memory attributes
  function automatic logic is_ram(input logic [33:0] pa);
    return (pa[33:32] == 2'b00) && (pa[31:0] >= RAM_BASE) && ((pa[31:0] - RAM_BASE) < RAM_SIZE);
  endfunction
  function automatic logic is_rom(input logic [33:0] pa);
    return (pa[33:32] == 2'b00) && (pa[31:0] >= ROM_BASE) && ((pa[31:0] - ROM_BASE) < ROM_SIZE);
  endfunction
  function automatic logic is_cacheable(input logic [33:0] pa);
    return is_ram(pa) || is_rom(pa);
  endfunction

  // ===================================================================
  // CSR / privilege state
  // ===================================================================
  logic [1:0]  priv, mpp;
  logic        mprv, sum, mxr, tvm, tw, tsr, satp_mode, satp_write;
  logic [21:0] satp_ppn;
  logic [31:0] csr_rdata, trap_vector, mepc, sepc;
  logic        csr_illegal, irq_pending, wfi_wake;
  logic [4:0]  irq_cause;

  // ===================================================================
  // Pipeline registers and global control
  // ===================================================================
  if_id_t  if_id_q;
  id_ex_t  id_ex_q;
  ex_mem_t ex_mem_q;
  mem_wb_t mem_wb_q;

  logic        mem_stall, ex_stall, stall_ex;
  logic        mem_redirect, ex_redirect;
  logic [31:0] mem_redirect_pc, ex_redirect_pc;
  logic [31:0] mem_result;
  logic        tlb_flush, icache_flush;

  assign stall_ex = mem_stall || ex_stall;

  // ===================================================================
  // Shared page table walker + D-cache arbitration
  // ===================================================================
  logic        ptw_i_req, ptw_i_ready, ptw_i_resp;
  logic        ptw_d_req, ptw_d_ready, ptw_d_resp;
  logic        ptw_resp_pf, ptw_resp_af;
  logic [31:0] ptw_resp_vaddr;
  logic        ptw_fill_i, ptw_fill_d, ptw_fill_mega;
  logic [19:0] ptw_fill_vpn;
  logic [21:0] ptw_fill_ppn;
  pte_flags_t  ptw_fill_flags;
  logic        ptw_mreq_valid, ptw_mreq_store, ptw_mreq_lock;
  logic [33:0] ptw_mreq_addr;
  logic [31:0] ptw_mreq_wdata;

  logic        d_ptw_store;
  logic [1:0]  eff_priv;
  logic [31:0] mem_va;

  fk_ptw #(.RAM_BASE(RAM_BASE), .RAM_SIZE(RAM_SIZE)) u_ptw (
    .clk, .rst_n,
    .satp_ppn     (satp_ppn),
    .flush        (tlb_flush),
    .i_req_valid  (ptw_i_req),
    .i_req_ready  (ptw_i_ready),
    .i_req_vaddr  (pc_q),
    .i_req_priv   (priv),
    .i_resp_valid (ptw_i_resp),
    .d_req_valid  (ptw_d_req),
    .d_req_ready  (ptw_d_ready),
    .d_req_vaddr  (mem_va),
    .d_req_store  (d_ptw_store),
    .d_req_priv   (eff_priv),
    .d_req_sum    (sum),
    .d_req_mxr    (mxr),
    .d_resp_valid (ptw_d_resp),
    .resp_pf      (ptw_resp_pf),
    .resp_af      (ptw_resp_af),
    .resp_vaddr   (ptw_resp_vaddr),
    .fill_i       (ptw_fill_i),
    .fill_d       (ptw_fill_d),
    .fill_vpn     (ptw_fill_vpn),
    .fill_ppn     (ptw_fill_ppn),
    .fill_mega    (ptw_fill_mega),
    .fill_flags   (ptw_fill_flags),
    .mreq_valid   (ptw_mreq_valid),
    .mreq_store   (ptw_mreq_store),
    .mreq_addr    (ptw_mreq_addr),
    .mreq_wdata   (ptw_mreq_wdata),
    .mreq_lock    (ptw_mreq_lock),
    .mreq_done    (dc_done && grant_ptw),
    .mreq_rdata   (dc_rdata),
    .mreq_err     (dc_err)
  );

  // D-cache request sources: MEM stage (core) and PTW
  logic        core_dreq;
  dc_op_t      core_dop;
  logic [33:0] core_pa;
  logic [1:0]  core_dsize;
  logic [31:0] core_dwdata;
  logic [3:0]  core_dwstrb;
  logic        core_owned_q, grant_ptw, grant_core;

  logic        dc_req_valid, dc_done, dc_err;
  dc_op_t      dc_op;
  logic [31:0] dc_addr, dc_wdata, dc_rdata;
  logic [1:0]  dc_size;
  logic [3:0]  dc_wstrb;
  logic        dc_uncached;

  assign grant_ptw  = !core_owned_q && ptw_mreq_valid;
  assign grant_core = core_owned_q || (!ptw_mreq_lock && !ptw_mreq_valid && core_dreq);

  always_comb begin
    if (grant_ptw) begin
      dc_req_valid = 1'b1;
      dc_op        = ptw_mreq_store ? DC_STORE : DC_LOAD;
      dc_addr      = ptw_mreq_addr[31:0];
      dc_size      = SZ_W;
      dc_wdata     = ptw_mreq_wdata;
      dc_wstrb     = 4'hF;
      dc_uncached  = 1'b0;
    end else begin
      dc_req_valid = grant_core && core_dreq;
      dc_op        = core_dop;
      dc_addr      = core_pa[31:0];
      dc_size      = core_dsize;
      dc_wdata     = core_dwdata;
      dc_wstrb     = core_dwstrb;
      dc_uncached  = !is_cacheable(core_pa);
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) core_owned_q <= 1'b0;
    else        core_owned_q <= grant_core && core_dreq && !dc_done;
  end

  // ===================================================================
  // AXI: I-cache + D-cache behind a serializing arbiter
  // ===================================================================
  logic        ic_arvalid, ic_arready, ic_rvalid, ic_rready, ic_rlast;
  logic [31:0] ic_araddr, ic_rdata_bus;
  logic [7:0]  ic_arlen;
  logic [2:0]  ic_arsize;
  logic [1:0]  ic_arburst, ic_rresp;

  logic        dc_awvalid, dc_awready, dc_wvalid, dc_wready, dc_wlast, dc_bvalid, dc_bready;
  logic        dc_arvalid, dc_arready, dc_rvalid, dc_rready, dc_rlast;
  logic [31:0] dc_awaddr, dc_wdata_bus, dc_araddr, dc_rdata_bus;
  logic [7:0]  dc_awlen, dc_arlen;
  logic [2:0]  dc_awsize, dc_arsize;
  logic [1:0]  dc_awburst, dc_arburst, dc_bresp, dc_rresp;
  logic [3:0]  dc_wstrb_bus;

  fk_axi_arb u_arb (
    .clk, .rst_n,
    .s0_arvalid(ic_arvalid), .s0_arready(ic_arready), .s0_araddr(ic_araddr), .s0_arlen(ic_arlen),
    .s0_arsize(ic_arsize), .s0_arburst(ic_arburst),
    .s0_rvalid(ic_rvalid), .s0_rready(ic_rready), .s0_rdata(ic_rdata_bus), .s0_rresp(ic_rresp), .s0_rlast(ic_rlast),
    .s1_awvalid(dc_awvalid), .s1_awready(dc_awready), .s1_awaddr(dc_awaddr), .s1_awlen(dc_awlen),
    .s1_awsize(dc_awsize), .s1_awburst(dc_awburst),
    .s1_wvalid(dc_wvalid), .s1_wready(dc_wready), .s1_wdata(dc_wdata_bus), .s1_wstrb(dc_wstrb_bus), .s1_wlast(dc_wlast),
    .s1_bvalid(dc_bvalid), .s1_bready(dc_bready), .s1_bresp(dc_bresp),
    .s1_arvalid(dc_arvalid), .s1_arready(dc_arready), .s1_araddr(dc_araddr), .s1_arlen(dc_arlen),
    .s1_arsize(dc_arsize), .s1_arburst(dc_arburst),
    .s1_rvalid(dc_rvalid), .s1_rready(dc_rready), .s1_rdata(dc_rdata_bus), .s1_rresp(dc_rresp), .s1_rlast(dc_rlast),
    .m_awvalid, .m_awready, .m_awid, .m_awaddr, .m_awlen, .m_awsize, .m_awburst,
    .m_wvalid, .m_wready, .m_wdata, .m_wstrb, .m_wlast,
    .m_bvalid, .m_bready, .m_bid, .m_bresp,
    .m_arvalid, .m_arready, .m_arid, .m_araddr, .m_arlen, .m_arsize, .m_arburst,
    .m_rvalid, .m_rready, .m_rid, .m_rdata, .m_rresp, .m_rlast
  );

  fk_dcache #(.SETS(DCACHE_SETS)) u_dcache (
    .clk, .rst_n,
    .req_valid(dc_req_valid), .req_op(dc_op), .req_amo(ex_mem_q.amo_op), .req_addr(dc_addr),
    .req_size(dc_size), .req_wdata(dc_wdata), .req_wstrb(dc_wstrb), .req_uncached(dc_uncached),
    .done(dc_done), .rdata(dc_rdata), .err(dc_err),
    .m_awvalid(dc_awvalid), .m_awready(dc_awready), .m_awaddr(dc_awaddr), .m_awlen(dc_awlen),
    .m_awsize(dc_awsize), .m_awburst(dc_awburst),
    .m_wvalid(dc_wvalid), .m_wready(dc_wready), .m_wdata(dc_wdata_bus), .m_wstrb(dc_wstrb_bus), .m_wlast(dc_wlast),
    .m_bvalid(dc_bvalid), .m_bready(dc_bready), .m_bresp(dc_bresp),
    .m_arvalid(dc_arvalid), .m_arready(dc_arready), .m_araddr(dc_araddr), .m_arlen(dc_arlen),
    .m_arsize(dc_arsize), .m_arburst(dc_arburst),
    .m_rvalid(dc_rvalid), .m_rready(dc_rready), .m_rdata(dc_rdata_bus), .m_rresp(dc_rresp), .m_rlast(dc_rlast)
  );

  // ===================================================================
  // IF stage
  // ===================================================================
  logic [31:0] pc_q;
  logic        if_halt_q;
  logic        i_ptw_pending_q, i_fault_q;
  logic [4:0]  i_fault_cause_q;

  logic        i_translate, itlb_hit, i_perm_ok;
  logic [21:0] itlb_ppn;
  pte_flags_t  itlb_flags;
  logic [33:0] i_pa;

  logic        ic_req, ic_hit, ic_err;
  logic [31:0] ic_rdata;

  logic        if_valid, if_exc;
  logic [4:0]  if_cause;
  logic        if_out, pc_change;

  assign i_translate = satp_mode && (priv != PRV_M);
  assign i_perm_ok   = itlb_flags.x && ((priv == PRV_U) ? itlb_flags.u : !itlb_flags.u);
  assign i_pa        = i_translate ? {itlb_ppn, pc_q[11:0]} : {2'b00, pc_q};

  fk_tlb #(.ENTRIES(ITLB_ENTRIES)) u_itlb (
    .clk, .rst_n, .flush(tlb_flush),
    .vpn(pc_q[31:12]), .hit(itlb_hit), .ppn(itlb_ppn), .flags(itlb_flags),
    .fill(ptw_fill_i), .fill_vpn(ptw_fill_vpn), .fill_ppn(ptw_fill_ppn),
    .fill_mega(ptw_fill_mega), .fill_flags(ptw_fill_flags)
  );

  fk_icache #(.SETS(ICACHE_SETS)) u_icache (
    .clk, .rst_n, .flush(icache_flush),
    .req(ic_req), .addr(i_pa[31:0]), .hit(ic_hit), .rdata(ic_rdata), .err(ic_err),
    .m_arvalid(ic_arvalid), .m_arready(ic_arready), .m_araddr(ic_araddr), .m_arlen(ic_arlen),
    .m_arsize(ic_arsize), .m_arburst(ic_arburst),
    .m_rvalid(ic_rvalid), .m_rready(ic_rready), .m_rdata(ic_rdata_bus), .m_rresp(ic_rresp), .m_rlast(ic_rlast)
  );

  always_comb begin
    if_valid  = 1'b0;
    if_exc    = 1'b0;
    if_cause  = EXC_IACCESS;
    ic_req    = 1'b0;
    ptw_i_req = 1'b0;
    if (!if_halt_q) begin
      if (i_translate && !itlb_hit) begin
        if (i_fault_q) begin
          if_exc = 1'b1; if_cause = i_fault_cause_q;
        end else begin
          ptw_i_req = !i_ptw_pending_q;
        end
      end else if (i_translate && !i_perm_ok) begin
        if_exc = 1'b1; if_cause = EXC_IPAGE;
      end else if (!is_cacheable(i_pa)) begin
        if_exc = 1'b1; if_cause = EXC_IACCESS;
      end else begin
        ic_req = 1'b1;
        if (ic_hit)      if_valid = 1'b1;
        else if (ic_err) begin if_exc = 1'b1; if_cause = EXC_IACCESS; end
      end
    end
  end

  assign if_out    = if_valid || if_exc;
  assign pc_change = mem_redirect || ex_redirect || (if_out && !stall_ex);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc_q            <= RESET_PC;
      if_halt_q       <= 1'b0;
      i_ptw_pending_q <= 1'b0;
      i_fault_q       <= 1'b0;
      i_fault_cause_q <= EXC_IPAGE;
    end else begin
      if (mem_redirect) begin
        pc_q <= mem_redirect_pc; if_halt_q <= 1'b0;
      end else if (ex_redirect) begin
        pc_q <= ex_redirect_pc;  if_halt_q <= 1'b0;
      end else if (if_out && !stall_ex) begin
        pc_q <= pc_q + 32'd4;
        if (if_exc) if_halt_q <= 1'b1;
      end

      if (ptw_i_req && ptw_i_ready) i_ptw_pending_q <= 1'b1;
      if (ptw_i_resp)               i_ptw_pending_q <= 1'b0;

      if (pc_change) begin
        i_fault_q <= 1'b0;
      end else if (ptw_i_resp && (ptw_resp_pf || ptw_resp_af) &&
                   ptw_resp_vaddr[31:12] == pc_q[31:12]) begin
        i_fault_q       <= 1'b1;
        i_fault_cause_q <= ptw_resp_pf ? EXC_IPAGE : EXC_IACCESS;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      if_id_q <= '0;
    end else if (mem_redirect || ex_redirect) begin
      if_id_q.valid <= 1'b0;
    end else if (!stall_ex) begin
      if_id_q.valid     <= if_out;
      if_id_q.pc        <= pc_q;
      if_id_q.instr     <= ic_rdata;
      if_id_q.exc       <= if_exc;
      if_id_q.exc_cause <= if_cause;
      if_id_q.exc_tval  <= pc_q;
    end
  end

  // ===================================================================
  // ID stage
  // ===================================================================
  logic [31:0] regs [32];

  logic        dec_illegal, dec_rd_we, dec_op_a_pc, dec_op_b_imm, dec_mem_unsigned;
  logic        dec_csr_imm, dec_csr_wen;
  logic [4:0]  dec_rs1, dec_rs2, dec_rd;
  logic [31:0] dec_imm;
  alu_op_t     dec_alu_op;
  br_op_t      dec_br_op;
  mem_op_t     dec_mem_op;
  amo_op_t     dec_amo_op;
  logic [1:0]  dec_mem_size, dec_csr_op;
  sys_op_t     dec_sys_op;

  fk_decode u_decode (
    .instr(if_id_q.instr), .illegal(dec_illegal),
    .rs1(dec_rs1), .rs2(dec_rs2), .rd(dec_rd), .rd_we(dec_rd_we), .imm(dec_imm),
    .op_a_pc(dec_op_a_pc), .op_b_imm(dec_op_b_imm), .alu_op(dec_alu_op), .br_op(dec_br_op),
    .mem_op(dec_mem_op), .amo_op(dec_amo_op), .mem_size(dec_mem_size), .mem_unsigned(dec_mem_unsigned),
    .sys_op(dec_sys_op), .csr_op(dec_csr_op), .csr_imm(dec_csr_imm), .csr_wen(dec_csr_wen)
  );

  function automatic logic [31:0] rf_read(input logic [4:0] r);
    if (r == 5'd0) return 32'd0;
    if (mem_wb_q.valid && mem_wb_q.rd_we && mem_wb_q.rd == r) return mem_wb_q.data;
    return regs[r];
  endfunction

  id_ex_t id_ex_d;
  always_comb begin
    id_ex_d              = '0;
    id_ex_d.valid        = if_id_q.valid;
    id_ex_d.pc           = if_id_q.pc;
    id_ex_d.instr        = if_id_q.instr;
    id_ex_d.rs1          = dec_rs1;
    id_ex_d.rs2          = dec_rs2;
    id_ex_d.rd           = dec_rd;
    id_ex_d.rd_we        = dec_rd_we && (dec_rd != 5'd0);
    id_ex_d.rs1_val      = rf_read(dec_rs1);
    id_ex_d.rs2_val      = rf_read(dec_rs2);
    id_ex_d.imm          = dec_imm;
    id_ex_d.op_a_pc      = dec_op_a_pc;
    id_ex_d.op_b_imm     = dec_op_b_imm;
    id_ex_d.alu_op       = dec_alu_op;
    id_ex_d.br_op        = dec_br_op;
    id_ex_d.mem_op       = dec_mem_op;
    id_ex_d.amo_op       = dec_amo_op;
    id_ex_d.mem_size     = dec_mem_size;
    id_ex_d.mem_unsigned = dec_mem_unsigned;
    id_ex_d.sys_op       = dec_sys_op;
    id_ex_d.csr_op       = dec_csr_op;
    id_ex_d.csr_imm      = dec_csr_imm;
    id_ex_d.csr_wen      = dec_csr_wen;
    if (if_id_q.exc) begin
      id_ex_d.exc       = 1'b1;
      id_ex_d.exc_cause = if_id_q.exc_cause;
      id_ex_d.exc_tval  = if_id_q.exc_tval;
    end else if (dec_illegal) begin
      id_ex_d.exc       = 1'b1;
      id_ex_d.exc_cause = EXC_ILLEGAL;
      id_ex_d.exc_tval  = if_id_q.instr;
    end
    if (id_ex_d.exc) begin
      id_ex_d.rd_we  = 1'b0;
      id_ex_d.br_op  = BR_NONE;
      id_ex_d.mem_op = MEM_NONE;
      id_ex_d.sys_op = SYS_NONE;
      id_ex_d.alu_op = ALU_ADD;
    end
  end

  // ===================================================================
  // EX stage
  // ===================================================================
  function automatic logic [31:0] fwd(input logic [4:0] r, input logic [31:0] v);
    if (r == 5'd0) return 32'd0;
    if (ex_mem_q.valid && ex_mem_q.rd_we && ex_mem_q.rd == r) return mem_result;
    if (mem_wb_q.valid && mem_wb_q.rd_we && mem_wb_q.rd == r) return mem_wb_q.data;
    return v;
  endfunction

  logic [31:0] ex_rs1, ex_rs2, ex_op_a, ex_op_b, ex_alu_y, ex_target, ex_result, div_result;
  logic        ex_taken, ex_is_div, div_busy, div_done, div_start;
  logic        ex_live;

  assign ex_rs1  = fwd(id_ex_q.rs1, id_ex_q.rs1_val);
  assign ex_rs2  = fwd(id_ex_q.rs2, id_ex_q.rs2_val);
  assign ex_op_a = id_ex_q.op_a_pc  ? id_ex_q.pc  : ex_rs1;
  assign ex_op_b = id_ex_q.op_b_imm ? id_ex_q.imm : ex_rs2;
  assign ex_live = id_ex_q.valid && !id_ex_q.exc;

  fk_alu u_alu (.op(id_ex_q.alu_op), .a(ex_op_a), .b(ex_op_b), .y(ex_alu_y));

  assign ex_is_div = (id_ex_q.alu_op == ALU_DIV)  || (id_ex_q.alu_op == ALU_DIVU) ||
                     (id_ex_q.alu_op == ALU_REM)  || (id_ex_q.alu_op == ALU_REMU);
  assign ex_stall  = ex_live && ex_is_div && !div_done;
  assign div_start = ex_live && ex_is_div && !div_busy && !div_done && !mem_stall && !mem_redirect;

  fk_div u_div (
    .clk, .rst_n,
    .start(div_start), .kill(mem_redirect), .ack(!stall_ex),
    .op(id_ex_q.alu_op), .a(ex_rs1), .b(ex_rs2),
    .busy(div_busy), .done(div_done), .result(div_result)
  );

  always_comb begin
    case (id_ex_q.br_op)
      BR_BEQ:  ex_taken = (ex_rs1 == ex_rs2);
      BR_BNE:  ex_taken = (ex_rs1 != ex_rs2);
      BR_BLT:  ex_taken = ($signed(ex_rs1) <  $signed(ex_rs2));
      BR_BGE:  ex_taken = ($signed(ex_rs1) >= $signed(ex_rs2));
      BR_BLTU: ex_taken = (ex_rs1 <  ex_rs2);
      BR_BGEU: ex_taken = (ex_rs1 >= ex_rs2);
      BR_JAL, BR_JALR: ex_taken = 1'b1;
      default: ex_taken = 1'b0;
    endcase
    ex_target = (id_ex_q.br_op == BR_JALR) ? ((ex_rs1 + id_ex_q.imm) & ~32'd1)
                                           : (id_ex_q.pc + id_ex_q.imm);
    if (id_ex_q.br_op == BR_JAL || id_ex_q.br_op == BR_JALR) ex_result = id_ex_q.pc + 32'd4;
    else if (ex_is_div)                                        ex_result = div_result;
    else                                                       ex_result = ex_alu_y;
  end

  logic ex_misfetch;
  assign ex_misfetch    = ex_live && ex_taken && ex_target[1];
  assign ex_redirect    = ex_live && ex_taken && !ex_target[1] && !stall_ex && !mem_redirect;
  assign ex_redirect_pc = ex_target;

  ex_mem_t ex_mem_d;
  always_comb begin
    ex_mem_d              = '0;
    ex_mem_d.valid        = id_ex_q.valid;
    ex_mem_d.pc           = id_ex_q.pc;
    ex_mem_d.instr        = id_ex_q.instr;
    ex_mem_d.exc          = id_ex_q.exc;
    ex_mem_d.exc_cause    = id_ex_q.exc_cause;
    ex_mem_d.exc_tval     = id_ex_q.exc_tval;
    ex_mem_d.rd           = id_ex_q.rd;
    ex_mem_d.rd_we        = id_ex_q.rd_we;
    ex_mem_d.result       = ex_result;
    ex_mem_d.store_data   = ex_rs2;
    ex_mem_d.mem_op       = id_ex_q.mem_op;
    ex_mem_d.amo_op       = id_ex_q.amo_op;
    ex_mem_d.mem_size     = id_ex_q.mem_size;
    ex_mem_d.mem_unsigned = id_ex_q.mem_unsigned;
    ex_mem_d.sys_op       = id_ex_q.sys_op;
    ex_mem_d.csr_op       = id_ex_q.csr_op;
    ex_mem_d.csr_wen      = id_ex_q.csr_wen;
    ex_mem_d.csr_operand  = id_ex_q.csr_imm ? {27'b0, id_ex_q.instr[19:15]} : ex_rs1;
    if (ex_misfetch) begin
      ex_mem_d.exc       = 1'b1;
      ex_mem_d.exc_cause = EXC_IADDR_MISALIGN;
      ex_mem_d.exc_tval  = ex_target;
    end
    if (ex_mem_d.exc) begin
      ex_mem_d.rd_we  = 1'b0;
      ex_mem_d.mem_op = MEM_NONE;
      ex_mem_d.sys_op = SYS_NONE;
    end
  end

  // ID -> EX register
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      id_ex_q <= '0;
    end else if (mem_redirect || ex_redirect) begin
      id_ex_q.valid <= 1'b0;
    end else if (!stall_ex) begin
      id_ex_q <= id_ex_d;
    end else begin
      // keep operands fresh while stalled (producers may leave the bypass window)
      id_ex_q.rs1_val <= ex_rs1;
      id_ex_q.rs2_val <= ex_rs2;
    end
  end

  // EX -> MEM register
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ex_mem_q <= '0;
    end else if (mem_redirect) begin
      ex_mem_q.valid <= 1'b0;
    end else if (!mem_stall) begin
      if (ex_stall) ex_mem_q.valid <= 1'b0;
      else          ex_mem_q <= ex_mem_d;
    end
  end

  // ===================================================================
  // MEM stage
  // ===================================================================
  logic        mem_started_q;
  logic        d_ptw_pending_q, m_fault_q;
  logic [4:0]  m_fault_cause_q;
  logic        resv_valid_q;
  logic [29:0] resv_addr_q;

  logic        d_translate, dtlb_hit, d_perm_ok, d_need_walk;
  logic [21:0] dtlb_ppn;
  pte_flags_t  dtlb_flags;
  logic        is_mem, store_like, atomic, misaligned;

  assign mem_va      = ex_mem_q.result;
  assign eff_priv    = mprv ? mpp : priv;
  assign d_translate = satp_mode && (eff_priv != PRV_M);
  assign is_mem      = (ex_mem_q.mem_op != MEM_NONE);
  assign store_like  = (ex_mem_q.mem_op == MEM_STORE) || (ex_mem_q.mem_op == MEM_AMO) ||
                       (ex_mem_q.mem_op == MEM_SC);
  assign atomic      = (ex_mem_q.mem_op == MEM_AMO) || (ex_mem_q.mem_op == MEM_LR) ||
                       (ex_mem_q.mem_op == MEM_SC);
  assign misaligned  = (ex_mem_q.mem_size == SZ_H && mem_va[0]) ||
                       (ex_mem_q.mem_size == SZ_W && mem_va[1:0] != 2'b00);
  assign d_ptw_store = store_like;

  fk_tlb #(.ENTRIES(DTLB_ENTRIES)) u_dtlb (
    .clk, .rst_n, .flush(tlb_flush),
    .vpn(mem_va[31:12]), .hit(dtlb_hit), .ppn(dtlb_ppn), .flags(dtlb_flags),
    .fill(ptw_fill_d), .fill_vpn(ptw_fill_vpn), .fill_ppn(ptw_fill_ppn),
    .fill_mega(ptw_fill_mega), .fill_flags(ptw_fill_flags)
  );

  assign d_perm_ok   = (store_like ? dtlb_flags.w : (dtlb_flags.r || (mxr && dtlb_flags.x))) &&
                       ((eff_priv == PRV_U) ? dtlb_flags.u : (!dtlb_flags.u || sum));
  assign d_need_walk = !dtlb_hit || (store_like && !dtlb_flags.d);
  assign core_pa     = d_translate ? {dtlb_ppn, mem_va[11:0]} : {2'b00, mem_va};

  // store data / strobes / D$ op
  always_comb begin
    case (ex_mem_q.mem_size)
      SZ_B:    begin core_dwdata = {4{ex_mem_q.store_data[7:0]}};  core_dwstrb = 4'b0001 << mem_va[1:0]; end
      SZ_H:    begin core_dwdata = {2{ex_mem_q.store_data[15:0]}}; core_dwstrb = 4'b0011 << mem_va[1:0]; end
      default: begin core_dwdata = ex_mem_q.store_data;            core_dwstrb = 4'b1111; end
    endcase
    core_dsize = ex_mem_q.mem_size;
    case (ex_mem_q.mem_op)
      MEM_STORE, MEM_SC: core_dop = DC_STORE;
      MEM_AMO:           core_dop = DC_AMO;
      default:           core_dop = DC_LOAD;
    endcase
  end

  // load data extraction
  logic [31:0] ld_shift, ld_data;
  always_comb begin
    ld_shift = dc_rdata >> {mem_va[1:0], 3'b000};
    case (ex_mem_q.mem_size)
      SZ_B:    ld_data = ex_mem_q.mem_unsigned ? {24'b0, ld_shift[7:0]}  : {{24{ld_shift[7]}},  ld_shift[7:0]};
      SZ_H:    ld_data = ex_mem_q.mem_unsigned ? {16'b0, ld_shift[15:0]} : {{16{ld_shift[15]}}, ld_shift[15:0]};
      default: ld_data = dc_rdata;
    endcase
  end

  // trap / completion logic
  logic        irq_take, trap, trap_irq, m_done, sc_fail, commit, core_done;
  logic [4:0]  trap_cause;
  logic [31:0] trap_tval;
  logic [4:0]  pf_cause, af_cause, ma_cause;

  assign pf_cause  = store_like ? EXC_SPAGE : EXC_LPAGE;
  assign af_cause  = store_like ? EXC_SACCESS : EXC_LACCESS;
  assign ma_cause  = store_like ? EXC_SADDR_MISALIGN : EXC_LADDR_MISALIGN;
  assign core_done = grant_core && dc_done;
  assign irq_take  = ex_mem_q.valid && irq_pending && !mem_started_q && (ex_mem_q.sys_op != SYS_WFI);

  logic csr_valid;
  assign csr_valid = ex_mem_q.valid && !ex_mem_q.exc && (ex_mem_q.sys_op == SYS_CSR);

  always_comb begin
    trap       = 1'b0;
    trap_irq   = 1'b0;
    trap_cause = 5'd0;
    trap_tval  = 32'd0;
    m_done     = 1'b1;
    core_dreq  = 1'b0;
    ptw_d_req  = 1'b0;
    sc_fail    = 1'b0;

    if (ex_mem_q.valid) begin
      if (irq_take) begin
        trap = 1'b1; trap_irq = 1'b1; trap_cause = irq_cause;
      end else if (ex_mem_q.exc) begin
        trap = 1'b1; trap_cause = ex_mem_q.exc_cause; trap_tval = ex_mem_q.exc_tval;
      end else begin
        case (ex_mem_q.sys_op)
          SYS_CSR: begin
            if (csr_illegal) begin trap = 1'b1; trap_cause = EXC_ILLEGAL; trap_tval = ex_mem_q.instr; end
          end
          SYS_ECALL: begin
            trap = 1'b1;
            trap_cause = (priv == PRV_M) ? EXC_ECALL_M : (priv == PRV_S) ? EXC_ECALL_S : EXC_ECALL_U;
          end
          SYS_EBREAK: begin
            trap = 1'b1; trap_cause = EXC_BREAKPOINT; trap_tval = ex_mem_q.pc;
          end
          SYS_MRET: begin
            if (priv != PRV_M) begin trap = 1'b1; trap_cause = EXC_ILLEGAL; trap_tval = ex_mem_q.instr; end
          end
          SYS_SRET: begin
            if (priv == PRV_U || (priv == PRV_S && tsr)) begin
              trap = 1'b1; trap_cause = EXC_ILLEGAL; trap_tval = ex_mem_q.instr;
            end
          end
          SYS_WFI: begin
            if (priv == PRV_U || (priv == PRV_S && tw)) begin
              trap = 1'b1; trap_cause = EXC_ILLEGAL; trap_tval = ex_mem_q.instr;
            end else begin
              m_done = wfi_wake;
            end
          end
          SYS_SFENCE: begin
            if (priv == PRV_U || (priv == PRV_S && tvm)) begin
              trap = 1'b1; trap_cause = EXC_ILLEGAL; trap_tval = ex_mem_q.instr;
            end
          end
          default: begin
            if (is_mem) begin
              m_done = 1'b0;
              if (misaligned) begin
                trap = 1'b1; trap_cause = ma_cause; trap_tval = mem_va;
              end else if (m_fault_q) begin
                trap = 1'b1; trap_cause = m_fault_cause_q; trap_tval = mem_va;
              end else if (d_translate && d_need_walk) begin
                ptw_d_req = !d_ptw_pending_q;
              end else if (d_translate && !d_perm_ok) begin
                trap = 1'b1; trap_cause = pf_cause; trap_tval = mem_va;
              end else if (core_pa[33:32] != 2'b00 || (atomic && !is_ram(core_pa))) begin
                trap = 1'b1; trap_cause = af_cause; trap_tval = mem_va;
              end else if (ex_mem_q.mem_op == MEM_SC &&
                           !(resv_valid_q && resv_addr_q == core_pa[31:2])) begin
                m_done = 1'b1; sc_fail = 1'b1;
              end else begin
                core_dreq = 1'b1;
                if (core_done) begin
                  if (dc_err) begin trap = 1'b1; trap_cause = af_cause; trap_tval = mem_va; end
                  else m_done = 1'b1;
                end
              end
            end
          end
        endcase
      end
    end
  end

  assign mem_stall = ex_mem_q.valid && !trap && !m_done;
  assign commit    = ex_mem_q.valid && !trap && m_done;

  always_comb begin
    case (ex_mem_q.mem_op)
      MEM_LOAD, MEM_LR: mem_result = ld_data;
      MEM_AMO:          mem_result = dc_rdata;
      MEM_SC:           mem_result = {31'b0, sc_fail};
      default:          mem_result = (ex_mem_q.sys_op == SYS_CSR) ? csr_rdata : ex_mem_q.result;
    endcase
  end

  logic flush_after;
  assign flush_after = (ex_mem_q.sys_op == SYS_CSR)    || (ex_mem_q.sys_op == SYS_MRET) ||
                       (ex_mem_q.sys_op == SYS_SRET)   || (ex_mem_q.sys_op == SYS_SFENCE) ||
                       (ex_mem_q.sys_op == SYS_FENCEI);
  assign mem_redirect = trap || (commit && flush_after);
  always_comb begin
    if (trap)                                 mem_redirect_pc = trap_vector;
    else if (ex_mem_q.sys_op == SYS_MRET)     mem_redirect_pc = mepc;
    else if (ex_mem_q.sys_op == SYS_SRET)     mem_redirect_pc = sepc;
    else                                      mem_redirect_pc = ex_mem_q.pc + 32'd4;
  end

  assign tlb_flush    = (commit && ex_mem_q.sys_op == SYS_SFENCE) || satp_write;
  assign icache_flush = commit && (ex_mem_q.sys_op == SYS_FENCEI);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mem_started_q   <= 1'b0;
      d_ptw_pending_q <= 1'b0;
      m_fault_q       <= 1'b0;
      m_fault_cause_q <= EXC_LPAGE;
      resv_valid_q    <= 1'b0;
      resv_addr_q     <= '0;
    end else begin
      mem_started_q <= mem_stall;

      if (ptw_d_req && ptw_d_ready) d_ptw_pending_q <= 1'b1;
      if (ptw_d_resp) begin
        d_ptw_pending_q <= 1'b0;
        if (ptw_resp_pf || ptw_resp_af) begin
          m_fault_q       <= 1'b1;
          m_fault_cause_q <= ptw_resp_pf ? pf_cause : af_cause;
        end
      end
      if (!mem_stall) m_fault_q <= 1'b0;

      if (trap || (commit && (ex_mem_q.sys_op == SYS_MRET || ex_mem_q.sys_op == SYS_SRET)))
        resv_valid_q <= 1'b0;
      else if (commit && ex_mem_q.mem_op == MEM_LR) begin
        resv_valid_q <= 1'b1;
        resv_addr_q  <= core_pa[31:2];
      end else if (commit && ex_mem_q.mem_op == MEM_SC)
        resv_valid_q <= 1'b0;
    end
  end

  fk_csr #(.HART_ID(HART_ID)) u_csr (
    .clk, .rst_n,
    .csr_valid   (csr_valid),
    .csr_addr    (ex_mem_q.instr[31:20]),
    .csr_op      (ex_mem_q.csr_op),
    .csr_wen     (ex_mem_q.csr_wen),
    .csr_operand (ex_mem_q.csr_operand),
    .csr_commit  (commit && ex_mem_q.sys_op == SYS_CSR),
    .csr_rdata   (csr_rdata),
    .csr_illegal (csr_illegal),
    .trap_valid  (trap),
    .trap_irq    (trap_irq),
    .trap_cause  (trap_cause),
    .trap_tval   (trap_tval),
    .trap_pc     (ex_mem_q.pc),
    .trap_vector (trap_vector),
    .mret        (commit && ex_mem_q.sys_op == SYS_MRET),
    .sret        (commit && ex_mem_q.sys_op == SYS_SRET),
    .mepc_o      (mepc),
    .sepc_o      (sepc),
    .instret_inc (commit),
    .irq_mtip, .irq_msip, .irq_meip, .irq_seip, .mtime,
    .irq_pending (irq_pending),
    .irq_cause   (irq_cause),
    .wfi_wake    (wfi_wake),
    .priv, .mprv, .mpp, .sum, .mxr, .tvm, .tw, .tsr,
    .satp_mode, .satp_ppn, .satp_write
  );

  // MEM -> WB register
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mem_wb_q <= '0;
    end else begin
      mem_wb_q.valid <= commit;
      mem_wb_q.rd    <= ex_mem_q.rd;
      mem_wb_q.rd_we <= ex_mem_q.rd_we;
      mem_wb_q.data  <= mem_result;
    end
  end

  // ===================================================================
  // WB stage
  // ===================================================================
  always_ff @(posedge clk) begin
    if (mem_wb_q.valid && mem_wb_q.rd_we && mem_wb_q.rd != 5'd0)
      regs[mem_wb_q.rd] <= mem_wb_q.data;
  end

  // ===================================================================
  // Simulation-only commit trace (enable with +trace_commit)
  // ===================================================================
`ifndef SYNTHESIS
  bit trace_en;
  initial trace_en = $test$plusargs("trace_commit");
  always_ff @(posedge clk) begin
    if (trace_en && rst_n) begin
      if (commit)
        $display("[commit] pc=%08x instr=%08x priv=%0d %s x%0d=%08x", ex_mem_q.pc, ex_mem_q.instr, priv,
                 (ex_mem_q.rd_we ? "W" : "-"), ex_mem_q.rd, mem_result);
      if (trap)
        $display("[trap  ] pc=%08x cause=%s%0d tval=%08x -> %08x", ex_mem_q.pc, trap_irq ? "irq" : "exc",
                 trap_cause, trap_tval, trap_vector);
    end
  end

  final begin
    $display("[fk-core] cycles=%0d instret=%0d IPC=%0.3f", u_csr.mcycle_q, u_csr.minstret_q,
             real'(u_csr.minstret_q) / real'(u_csr.mcycle_q));
  end
`endif

endmodule
