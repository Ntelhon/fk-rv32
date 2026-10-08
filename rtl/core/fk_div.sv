// fk-core: iterative radix-2 divider (32 cycles)
// start: begin a division; done stays high until ack, start or kill.
module fk_div import fk_pkg::*; (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        start,
  input  logic        kill,
  input  logic        ack,
  input  alu_op_t     op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        busy,
  output logic        done,
  output logic [31:0] result
);
  logic [5:0]  cnt_q;
  logic [31:0] quot_q, rem_q, divisor_q;
  logic        neg_q_q, neg_r_q, want_rem_q, div0_q;
  logic [31:0] a_orig_q;

  logic is_signed;
  assign is_signed = (op == ALU_DIV) || (op == ALU_REM);

  logic [32:0] trial;
  assign trial = {rem_q, quot_q[31]} - {1'b0, divisor_q};

  logic [31:0] q_fix, r_fix;
  assign q_fix = neg_q_q ? -quot_q : quot_q;
  assign r_fix = neg_r_q ? -rem_q  : rem_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= 1'b0; done <= 1'b0; cnt_q <= '0;
      quot_q <= '0; rem_q <= '0; divisor_q <= '0;
      neg_q_q <= 1'b0; neg_r_q <= 1'b0; want_rem_q <= 1'b0; div0_q <= 1'b0;
      a_orig_q <= '0; result <= '0;
    end else if (kill) begin
      busy <= 1'b0; done <= 1'b0;
    end else if (start) begin
      busy       <= 1'b1;
      done       <= 1'b0;
      cnt_q      <= 6'd32;
      quot_q     <= (is_signed && a[31]) ? -a : a;
      divisor_q  <= (is_signed && b[31]) ? -b : b;
      rem_q      <= '0;
      neg_q_q    <= is_signed && (a[31] ^ b[31]);
      neg_r_q    <= is_signed && a[31];
      want_rem_q <= (op == ALU_REM) || (op == ALU_REMU);
      div0_q     <= (b == 32'd0);
      a_orig_q   <= a;
    end else if (busy) begin
      if (cnt_q == 6'd0) begin
        busy <= 1'b0;
        done <= 1'b1;
        if (div0_q) result <= want_rem_q ? a_orig_q : 32'hFFFF_FFFF;
        else        result <= want_rem_q ? r_fix : q_fix;
      end else begin
        cnt_q <= cnt_q - 6'd1;
        if (!trial[32]) begin
          rem_q  <= trial[31:0];
          quot_q <= {quot_q[30:0], 1'b1};
        end else begin
          rem_q  <= {rem_q[30:0], quot_q[31]};
          quot_q <= {quot_q[30:0], 1'b0};
        end
      end
    end else if (ack) begin
      done <= 1'b0;
    end
  end

endmodule
