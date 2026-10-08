// fk-soc: PLIC with NSRC level-triggered sources (ids 1..NSRC) and two
// contexts: 0 = hart0 M-mode, 1 = hart0 S-mode.
module fk_plic #(
  parameter int NSRC = 31
)(
  input  logic            clk,
  input  logic            rst_n,
  input  logic            req,
  input  logic            we,
  input  logic [25:0]     addr,
  input  logic [31:0]     wdata,
  output logic [31:0]     rdata,
  output logic            err,
  input  logic [NSRC:1]   src,
  output logic [1:0]      eip
);
  logic [2:0]      prio_q   [NSRC+1];
  logic [NSRC:1]   pending_q, inserv_q;
  logic [NSRC:1]   enable_q [2];
  logic [2:0]      thresh_q [2];

  // best pending+enabled source per context
  logic [5:0] best_id [2];
  always_comb begin
    for (int c = 0; c < 2; c++) begin
      logic [2:0] bp;
      bp = '0;
      best_id[c] = '0;
      for (int i = 1; i <= NSRC; i++) begin
        if (pending_q[i] && enable_q[c][i] && prio_q[i] > bp) begin
          bp = prio_q[i];
          best_id[c] = 6'(i);
        end
      end
      eip[c] = (best_id[c] != 0) && (bp > thresh_q[c]);
    end
  end

  logic [31:0] pend_word, en_word0, en_word1;
  assign pend_word = {pending_q, 1'b0};
  assign en_word0  = {enable_q[0], 1'b0};
  assign en_word1  = {enable_q[1], 1'b0};

  logic claim0, claim1;
  assign claim0 = req && !we && (addr == 26'h0200004);
  assign claim1 = req && !we && (addr == 26'h0201004);

  logic [5:0] claim_id0, claim_id1;
  assign claim_id0 = eip[0] ? best_id[0] : 6'd0;
  assign claim_id1 = eip[1] ? best_id[1] : 6'd0;

  always_comb begin
    rdata = '0;
    err   = 1'b0;
    if (addr < 26'h0001000) begin
      if (addr[11:2] >= 1 && addr[11:2] <= NSRC) rdata = {29'b0, prio_q[addr[11:2]]};
    end else if (addr == 26'h0001000) rdata = pend_word;
    else if (addr == 26'h0002000) rdata = en_word0;
    else if (addr == 26'h0002080) rdata = en_word1;
    else if (addr == 26'h0200000) rdata = {29'b0, thresh_q[0]};
    else if (addr == 26'h0200004) rdata = {26'b0, claim_id0};
    else if (addr == 26'h0201000) rdata = {29'b0, thresh_q[1]};
    else if (addr == 26'h0201004) rdata = {26'b0, claim_id1};
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i <= NSRC; i++) prio_q[i] <= '0;
      pending_q <= '0; inserv_q <= '0;
      enable_q[0] <= '0; enable_q[1] <= '0;
      thresh_q[0] <= '0; thresh_q[1] <= '0;
    end else begin
      // gateway: level sources latch pending when not in service
      for (int i = 1; i <= NSRC; i++)
        if (src[i] && !inserv_q[i]) pending_q[i] <= 1'b1;

      if (claim0 && claim_id0 != 0) begin
        pending_q[claim_id0] <= 1'b0; inserv_q[claim_id0] <= 1'b1;
      end
      if (claim1 && claim_id1 != 0) begin
        pending_q[claim_id1] <= 1'b0; inserv_q[claim_id1] <= 1'b1;
      end

      if (req && we) begin
        if (addr < 26'h0001000) begin
          if (addr[11:2] >= 1 && addr[11:2] <= NSRC) prio_q[addr[11:2]] <= wdata[2:0];
        end
        else if (addr == 26'h0002000) enable_q[0] <= wdata[NSRC:1];
        else if (addr == 26'h0002080) enable_q[1] <= wdata[NSRC:1];
        else if (addr == 26'h0200000) thresh_q[0] <= wdata[2:0];
        else if (addr == 26'h0201000) thresh_q[1] <= wdata[2:0];
        else if (addr == 26'h0200004 || addr == 26'h0201004) begin
          if (wdata[5:0] >= 1 && wdata[5:0] <= NSRC) inserv_q[wdata[5:0]] <= 1'b0;
        end
      end
    end
  end

endmodule
