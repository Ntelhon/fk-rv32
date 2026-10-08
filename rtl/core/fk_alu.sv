// fk-core: integer ALU with single-cycle multiplier
module fk_alu import fk_pkg::*; (
  input  alu_op_t     op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] y
);
  logic signed [32:0] ma, mb;
  logic signed [65:0] prod;

  always_comb begin
    ma = {(op == ALU_MULH || op == ALU_MULHSU) & a[31], a};
    mb = {(op == ALU_MULH) & b[31], b};
    prod = ma * mb;
  end

  always_comb begin
    case (op)
      ALU_ADD:    y = a + b;
      ALU_SUB:    y = a - b;
      ALU_SLL:    y = a << b[4:0];
      ALU_SLT:    y = {31'b0, $signed(a) < $signed(b)};
      ALU_SLTU:   y = {31'b0, a < b};
      ALU_XOR:    y = a ^ b;
      ALU_SRL:    y = a >> b[4:0];
      ALU_SRA:    y = $unsigned($signed(a) >>> b[4:0]);
      ALU_OR:     y = a | b;
      ALU_AND:    y = a & b;
      ALU_PASSB:  y = b;
      ALU_MUL:    y = prod[31:0];
      ALU_MULH, ALU_MULHSU, ALU_MULHU: y = prod[63:32];
      default:    y = a + b;
    endcase
  end

endmodule
