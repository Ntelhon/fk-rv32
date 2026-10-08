// fk-core: CSR file, privilege state, trap/interrupt control (M/S/U, Sv32)
module fk_csr import fk_pkg::*; #(
  parameter logic [31:0] HART_ID = 32'd0
)(
  input  logic        clk,
  input  logic        rst_n,
  // CSR instruction in MEM
  input  logic        csr_valid,
  input  logic [11:0] csr_addr,
  input  logic [1:0]  csr_op,       // 1=RW 2=RS 3=RC
  input  logic        csr_wen,
  input  logic [31:0] csr_operand,
  input  logic        csr_commit,
  output logic [31:0] csr_rdata,
  output logic        csr_illegal,
  // trap entry
  input  logic        trap_valid,
  input  logic        trap_irq,
  input  logic [4:0]  trap_cause,
  input  logic [31:0] trap_tval,
  input  logic [31:0] trap_pc,
  output logic [31:0] trap_vector,
  // xRET
  input  logic        mret,
  input  logic        sret,
  output logic [31:0] mepc_o,
  output logic [31:0] sepc_o,
  input  logic        instret_inc,
  // interrupt sources
  input  logic        irq_mtip,
  input  logic        irq_msip,
  input  logic        irq_meip,
  input  logic        irq_seip,
  input  logic [63:0] mtime,
  output logic        irq_pending,
  output logic [4:0]  irq_cause,
  output logic        wfi_wake,
  // state
  output logic [1:0]  priv,
  output logic        mprv,
  output logic [1:0]  mpp,
  output logic        sum,
  output logic        mxr,
  output logic        tvm,
  output logic        tw,
  output logic        tsr,
  output logic        satp_mode,
  output logic [21:0] satp_ppn,
  output logic        satp_write
);

  localparam logic [31:0] MISA = 32'h4014_1101; // RV32 IMA S U

  // ---------------------------------------------------------------
  // State
  // ---------------------------------------------------------------
  logic [1:0]  priv_q;
  logic        mie_q, sie_q, mpie_q, spie_q, spp_q;
  logic [1:0]  mpp_q;
  logic        mprv_q, sum_q, mxr_q, tvm_q, tw_q, tsr_q;
  logic [15:0] medeleg_q;
  logic [11:0] mideleg_q;
  logic [11:0] mie_r_q;           // interrupt enable register
  logic        ssip_q, stip_q, seip_sw_q;
  logic [31:0] mtvec_q, stvec_q, mscratch_q, sscratch_q;
  logic [31:0] mepc_q, sepc_q, mcause_q, scause_q, mtval_q, stval_q;
  logic [31:0] mcounteren_q, scounteren_q;
  logic        satp_mode_q;
  logic [21:0] satp_ppn_q;
  logic [63:0] mcycle_q, minstret_q;

  assign priv      = priv_q;
  assign mprv      = mprv_q;
  assign mpp       = mpp_q;
  assign sum       = sum_q;
  assign mxr       = mxr_q;
  assign tvm       = tvm_q;
  assign tw        = tw_q;
  assign tsr       = tsr_q;
  assign satp_mode = satp_mode_q;
  assign satp_ppn  = satp_ppn_q;
  assign mepc_o    = mepc_q;
  assign sepc_o    = sepc_q;

  // ---------------------------------------------------------------
  // Derived views
  // ---------------------------------------------------------------
  logic [31:0] mstatus_v, sstatus_v, mip_v, mip_rmw_v, mie_v;
  always_comb begin
    mstatus_v = '0;
    mstatus_v[1]     = sie_q;
    mstatus_v[3]     = mie_q;
    mstatus_v[5]     = spie_q;
    mstatus_v[7]     = mpie_q;
    mstatus_v[8]     = spp_q;
    mstatus_v[12:11] = mpp_q;
    mstatus_v[17]    = mprv_q;
    mstatus_v[18]    = sum_q;
    mstatus_v[19]    = mxr_q;
    mstatus_v[20]    = tvm_q;
    mstatus_v[21]    = tw_q;
    mstatus_v[22]    = tsr_q;

    sstatus_v = '0;
    sstatus_v[1]  = sie_q;
    sstatus_v[5]  = spie_q;
    sstatus_v[8]  = spp_q;
    sstatus_v[18] = sum_q;
    sstatus_v[19] = mxr_q;

    mip_v = '0;
    mip_v[1]  = ssip_q;
    mip_v[3]  = irq_msip;
    mip_v[5]  = stip_q;
    mip_v[7]  = irq_mtip;
    mip_v[9]  = seip_sw_q | irq_seip;
    mip_v[11] = irq_meip;

    mip_rmw_v    = mip_v;
    mip_rmw_v[9] = seip_sw_q;

    mie_v = {20'b0, mie_r_q};
  end

  // ---------------------------------------------------------------
  // Interrupt selection
  // ---------------------------------------------------------------
  logic [11:0] pend, m_take, s_take, take;
  logic        m_en, s_en;
  always_comb begin
    pend   = mip_v[11:0] & mie_r_q;
    m_en   = (priv_q != PRV_M) || mie_q;
    s_en   = (priv_q == PRV_U) || (priv_q == PRV_S && sie_q);
    m_take = m_en ? (pend & ~mideleg_q) : '0;
    s_take = s_en ? (pend &  mideleg_q) : '0;
    take   = (m_take != '0) ? m_take : s_take;

    irq_pending = (take != '0);
    irq_cause   = 5'd0;
    if      (take[11]) irq_cause = IRQ_M_EXT;
    else if (take[3])  irq_cause = IRQ_M_SOFT;
    else if (take[7])  irq_cause = IRQ_M_TIMER;
    else if (take[9])  irq_cause = IRQ_S_EXT;
    else if (take[1])  irq_cause = IRQ_S_SOFT;
    else if (take[5])  irq_cause = IRQ_S_TIMER;

    wfi_wake = (pend != '0);
  end

  // ---------------------------------------------------------------
  // Trap target
  // ---------------------------------------------------------------
  logic trap_to_s;
  always_comb begin
    trap_to_s = (priv_q != PRV_M) &&
                (trap_irq ? mideleg_q[trap_cause[3:0]] : (trap_cause < 5'd16 && medeleg_q[trap_cause[3:0]]));
    if (trap_to_s)
      trap_vector = {stvec_q[31:2], 2'b00} + ((stvec_q[0] && trap_irq) ? {25'b0, trap_cause, 2'b00} : 32'd0);
    else
      trap_vector = {mtvec_q[31:2], 2'b00} + ((mtvec_q[0] && trap_irq) ? {25'b0, trap_cause, 2'b00} : 32'd0);
  end

  // ---------------------------------------------------------------
  // CSR read + legality
  // ---------------------------------------------------------------
  logic        exists;
  logic [31:0] rdata_rmw;   // value used for read-modify-write
  logic        counter_ok;

  // counter accessibility: index = addr[4:0] for 0xC00-0xC1F / 0xC80-0xC9F
  always_comb begin
    counter_ok = 1'b1;
    if (priv_q != PRV_M && !mcounteren_q[csr_addr[4:0]]) counter_ok = 1'b0;
    if (priv_q == PRV_U && !scounteren_q[csr_addr[4:0]]) counter_ok = 1'b0;
  end

  always_comb begin
    exists    = 1'b1;
    csr_rdata = '0;
    case (csr_addr)
      // ---- supervisor ----
      12'h100: csr_rdata = sstatus_v;
      12'h104: csr_rdata = mie_v & {20'b0, mideleg_q};
      12'h105: csr_rdata = stvec_q;
      12'h106: csr_rdata = scounteren_q;
      12'h10A: csr_rdata = '0;                 // senvcfg
      12'h140: csr_rdata = sscratch_q;
      12'h141: csr_rdata = sepc_q;
      12'h142: csr_rdata = scause_q;
      12'h143: csr_rdata = stval_q;
      12'h144: csr_rdata = mip_v & {20'b0, mideleg_q};
      12'h180: csr_rdata = {satp_mode_q, 9'b0, satp_ppn_q};
      // ---- machine ----
      12'h300: csr_rdata = mstatus_v;
      12'h301: csr_rdata = MISA;
      12'h302: csr_rdata = {16'b0, medeleg_q};
      12'h303: csr_rdata = {20'b0, mideleg_q};
      12'h304: csr_rdata = mie_v;
      12'h305: csr_rdata = mtvec_q;
      12'h306: csr_rdata = mcounteren_q;
      12'h30A: csr_rdata = '0;                 // menvcfg
      12'h310: csr_rdata = '0;                 // mstatush
      12'h31A: csr_rdata = '0;                 // menvcfgh
      12'h320: csr_rdata = '0;                 // mcountinhibit
      12'h340: csr_rdata = mscratch_q;
      12'h341: csr_rdata = mepc_q;
      12'h342: csr_rdata = mcause_q;
      12'h343: csr_rdata = mtval_q;
      12'h344: csr_rdata = mip_v;
      12'hB00: csr_rdata = mcycle_q[31:0];
      12'hB02: csr_rdata = minstret_q[31:0];
      12'hB80: csr_rdata = mcycle_q[63:32];
      12'hB82: csr_rdata = minstret_q[63:32];
      12'hC00: csr_rdata = mcycle_q[31:0];
      12'hC01: csr_rdata = mtime[31:0];
      12'hC02: csr_rdata = minstret_q[31:0];
      12'hC80: csr_rdata = mcycle_q[63:32];
      12'hC81: csr_rdata = mtime[63:32];
      12'hC82: csr_rdata = minstret_q[63:32];
      // Sdtrig with zero triggers: tselect/tdata* read 0, tinfo reports "no trigger"
      12'h7A0, 12'h7A1, 12'h7A2, 12'h7A3: csr_rdata = '0;
      12'h7A4: csr_rdata = 32'd1;
      12'hF11, 12'hF12, 12'hF13, 12'hF15: csr_rdata = '0;
      12'hF14: csr_rdata = HART_ID;
      default: begin
        // pmpcfg0-15, pmpaddr0-63: hardwired zero (no PMP)
        if (csr_addr >= 12'h3A0 && csr_addr <= 12'h3EF) csr_rdata = '0;
        // mhpmevent3-31
        else if (csr_addr >= 12'h323 && csr_addr <= 12'h33F) csr_rdata = '0;
        // mhpmcounter3-31(h)
        else if ((csr_addr >= 12'hB03 && csr_addr <= 12'hB1F) ||
                 (csr_addr >= 12'hB83 && csr_addr <= 12'hB9F)) csr_rdata = '0;
        // hpmcounter3-31(h)
        else if ((csr_addr >= 12'hC03 && csr_addr <= 12'hC1F) ||
                 (csr_addr >= 12'hC83 && csr_addr <= 12'hC9F)) csr_rdata = '0;
        else exists = 1'b0;
      end
    endcase

    rdata_rmw = csr_rdata;
    if (csr_addr == 12'h344) rdata_rmw = mip_rmw_v;
  end

  always_comb begin
    csr_illegal = 1'b0;
    if (csr_valid) begin
      if (!exists) csr_illegal = 1'b1;
      if (priv_q < csr_addr[9:8]) csr_illegal = 1'b1;
      if (csr_wen && csr_addr[11:10] == 2'b11) csr_illegal = 1'b1;
      if (csr_addr == 12'h180 && priv_q == PRV_S && tvm_q) csr_illegal = 1'b1;
      if ((csr_addr[11:5] == 7'b1100000 || csr_addr[11:5] == 7'b1100100) && !counter_ok)
        csr_illegal = 1'b1;
    end
  end

  logic [31:0] wval;
  always_comb begin
    case (csr_op)
      2'd1:    wval = csr_operand;
      2'd2:    wval = rdata_rmw | csr_operand;
      2'd3:    wval = rdata_rmw & ~csr_operand;
      default: wval = rdata_rmw;
    endcase
  end

  logic do_write;
  assign do_write   = csr_commit && csr_wen && !csr_illegal;
  assign satp_write = do_write && (csr_addr == 12'h180);

  // ---------------------------------------------------------------
  // Sequential update
  // ---------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      priv_q <= PRV_M;
      mie_q <= 1'b0; sie_q <= 1'b0; mpie_q <= 1'b0; spie_q <= 1'b0; spp_q <= 1'b0;
      mpp_q <= PRV_M; mprv_q <= 1'b0; sum_q <= 1'b0; mxr_q <= 1'b0;
      tvm_q <= 1'b0; tw_q <= 1'b0; tsr_q <= 1'b0;
      medeleg_q <= '0; mideleg_q <= '0; mie_r_q <= '0;
      ssip_q <= 1'b0; stip_q <= 1'b0; seip_sw_q <= 1'b0;
      mtvec_q <= '0; stvec_q <= '0; mscratch_q <= '0; sscratch_q <= '0;
      mepc_q <= '0; sepc_q <= '0; mcause_q <= '0; scause_q <= '0;
      mtval_q <= '0; stval_q <= '0;
      mcounteren_q <= '0; scounteren_q <= '0;
      satp_mode_q <= 1'b0; satp_ppn_q <= '0;
      mcycle_q <= '0; minstret_q <= '0;
    end else begin
      mcycle_q <= mcycle_q + 64'd1;
      // an instruction that writes minstret/minstreth suppresses its own increment
      if (instret_inc && !(do_write && (csr_addr == 12'hB02 || csr_addr == 12'hB82)))
        minstret_q <= minstret_q + 64'd1;

      if (trap_valid) begin
        if (trap_to_s) begin
          scause_q <= {trap_irq, 26'b0, trap_cause};
          sepc_q   <= trap_pc;
          stval_q  <= trap_tval;
          spie_q   <= sie_q;
          sie_q    <= 1'b0;
          spp_q    <= priv_q[0];
          priv_q   <= PRV_S;
        end else begin
          mcause_q <= {trap_irq, 26'b0, trap_cause};
          mepc_q   <= trap_pc;
          mtval_q  <= trap_tval;
          mpie_q   <= mie_q;
          mie_q    <= 1'b0;
          mpp_q    <= priv_q;
          priv_q   <= PRV_M;
        end
      end else if (mret) begin
        priv_q <= mpp_q;
        mie_q  <= mpie_q;
        mpie_q <= 1'b1;
        mpp_q  <= PRV_U;
        if (mpp_q != PRV_M) mprv_q <= 1'b0;
      end else if (sret) begin
        priv_q <= {1'b0, spp_q};
        sie_q  <= spie_q;
        spie_q <= 1'b1;
        spp_q  <= 1'b0;
        mprv_q <= 1'b0;
      end else if (do_write) begin
        case (csr_addr)
          12'h100: begin
            sie_q <= wval[1]; spie_q <= wval[5]; spp_q <= wval[8];
            sum_q <= wval[18]; mxr_q <= wval[19];
          end
          12'h104: mie_r_q <= (mie_r_q & ~mideleg_q) | (wval[11:0] & mideleg_q);
          12'h105: stvec_q <= {wval[31:2], 1'b0, wval[0]};
          12'h106: scounteren_q <= wval;
          12'h140: sscratch_q <= wval;
          12'h141: sepc_q <= {wval[31:2], 2'b00};
          12'h142: scause_q <= wval;
          12'h143: stval_q <= wval;
          12'h144: if (mideleg_q[1]) ssip_q <= wval[1];
          12'h180: begin satp_mode_q <= wval[31]; satp_ppn_q <= wval[21:0]; end
          12'h300: begin
            sie_q <= wval[1]; mie_q <= wval[3]; spie_q <= wval[5]; mpie_q <= wval[7];
            spp_q <= wval[8];
            if (wval[12:11] != 2'b10) mpp_q <= wval[12:11];
            mprv_q <= wval[17]; sum_q <= wval[18]; mxr_q <= wval[19];
            tvm_q <= wval[20]; tw_q <= wval[21]; tsr_q <= wval[22];
          end
          12'h302: medeleg_q <= wval[15:0] & 16'hB3FF;
          12'h303: mideleg_q <= wval[11:0] & 12'h222;
          12'h304: mie_r_q <= wval[11:0] & 12'hAAA;
          12'h305: mtvec_q <= {wval[31:2], 1'b0, wval[0]};
          12'h306: mcounteren_q <= wval;
          12'h340: mscratch_q <= wval;
          12'h341: mepc_q <= {wval[31:2], 2'b00};
          12'h342: mcause_q <= wval;
          12'h343: mtval_q <= wval;
          12'h344: begin ssip_q <= wval[1]; stip_q <= wval[5]; seip_sw_q <= wval[9]; end
          12'hB00: mcycle_q[31:0]    <= wval;
          12'hB80: mcycle_q[63:32]   <= wval;
          12'hB02: minstret_q[31:0]  <= wval;
          12'hB82: minstret_q[63:32] <= wval;
          default: ;
        endcase
      end
    end
  end

endmodule
