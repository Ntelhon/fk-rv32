// fk-core: instruction decoder (RV32IMA + Zicsr + Zifencei + privileged)
module fk_decode import fk_pkg::*; (
  input  logic [31:0] instr,
  output logic        illegal,
  output logic [4:0]  rs1, rs2, rd,
  output logic        rd_we,
  output logic [31:0] imm,
  output logic        op_a_pc,
  output logic        op_b_imm,
  output alu_op_t     alu_op,
  output br_op_t      br_op,
  output mem_op_t     mem_op,
  output amo_op_t     amo_op,
  output logic [1:0]  mem_size,
  output logic        mem_unsigned,
  output sys_op_t     sys_op,
  output logic [1:0]  csr_op,
  output logic        csr_imm,
  output logic        csr_wen
);
  logic [6:0] opcode, funct7;
  logic [2:0] funct3;
  logic [4:0] funct5;

  assign opcode = instr[6:0];
  assign funct3 = instr[14:12];
  assign funct7 = instr[31:25];
  assign funct5 = instr[31:27];

  logic [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;
  assign imm_i = {{20{instr[31]}}, instr[31:20]};
  assign imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
  assign imm_b = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
  assign imm_u = {instr[31:12], 12'b0};
  assign imm_j = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

  always_comb begin
    illegal      = 1'b0;
    rs1          = instr[19:15];
    rs2          = instr[24:20];
    rd           = instr[11:7];
    rd_we        = 1'b0;
    imm          = imm_i;
    op_a_pc      = 1'b0;
    op_b_imm     = 1'b0;
    alu_op       = ALU_ADD;
    br_op        = BR_NONE;
    mem_op       = MEM_NONE;
    amo_op       = AMO_SWAP;
    mem_size     = SZ_W;
    mem_unsigned = 1'b0;
    sys_op       = SYS_NONE;
    csr_op       = 2'd0;
    csr_imm      = 1'b0;
    csr_wen      = 1'b0;

    case (opcode)
      7'b0110111: begin // LUI
        rd_we = 1'b1; imm = imm_u; op_b_imm = 1'b1; alu_op = ALU_PASSB; rs1 = '0; rs2 = '0;
      end
      7'b0010111: begin // AUIPC
        rd_we = 1'b1; imm = imm_u; op_a_pc = 1'b1; op_b_imm = 1'b1; rs1 = '0; rs2 = '0;
      end
      7'b1101111: begin // JAL
        rd_we = 1'b1; imm = imm_j; br_op = BR_JAL; rs1 = '0; rs2 = '0;
      end
      7'b1100111: begin // JALR
        rd_we = 1'b1; imm = imm_i; br_op = BR_JALR; rs2 = '0;
        if (funct3 != 3'b000) illegal = 1'b1;
      end
      7'b1100011: begin // BRANCH
        imm = imm_b; rd = '0;
        case (funct3)
          3'b000: br_op = BR_BEQ;
          3'b001: br_op = BR_BNE;
          3'b100: br_op = BR_BLT;
          3'b101: br_op = BR_BGE;
          3'b110: br_op = BR_BLTU;
          3'b111: br_op = BR_BGEU;
          default: illegal = 1'b1;
        endcase
      end
      7'b0000011: begin // LOAD
        rd_we = 1'b1; imm = imm_i; op_b_imm = 1'b1; mem_op = MEM_LOAD; rs2 = '0;
        case (funct3)
          3'b000: mem_size = SZ_B;
          3'b001: mem_size = SZ_H;
          3'b010: mem_size = SZ_W;
          3'b100: begin mem_size = SZ_B; mem_unsigned = 1'b1; end
          3'b101: begin mem_size = SZ_H; mem_unsigned = 1'b1; end
          default: illegal = 1'b1;
        endcase
      end
      7'b0100011: begin // STORE
        imm = imm_s; op_b_imm = 1'b1; mem_op = MEM_STORE; rd = '0;
        case (funct3)
          3'b000: mem_size = SZ_B;
          3'b001: mem_size = SZ_H;
          3'b010: mem_size = SZ_W;
          default: illegal = 1'b1;
        endcase
      end
      7'b0010011: begin // OP-IMM
        rd_we = 1'b1; imm = imm_i; op_b_imm = 1'b1; rs2 = '0;
        case (funct3)
          3'b000: alu_op = ALU_ADD;
          3'b010: alu_op = ALU_SLT;
          3'b011: alu_op = ALU_SLTU;
          3'b100: alu_op = ALU_XOR;
          3'b110: alu_op = ALU_OR;
          3'b111: alu_op = ALU_AND;
          3'b001: begin
            alu_op = ALU_SLL;
            if (funct7 != 7'b0000000) illegal = 1'b1;
          end
          3'b101: begin
            if (funct7 == 7'b0000000)      alu_op = ALU_SRL;
            else if (funct7 == 7'b0100000) alu_op = ALU_SRA;
            else illegal = 1'b1;
          end
        endcase
      end
      7'b0110011: begin // OP
        rd_we = 1'b1;
        if (funct7 == 7'b0000000) begin
          case (funct3)
            3'b000: alu_op = ALU_ADD;
            3'b001: alu_op = ALU_SLL;
            3'b010: alu_op = ALU_SLT;
            3'b011: alu_op = ALU_SLTU;
            3'b100: alu_op = ALU_XOR;
            3'b101: alu_op = ALU_SRL;
            3'b110: alu_op = ALU_OR;
            3'b111: alu_op = ALU_AND;
          endcase
        end else if (funct7 == 7'b0100000) begin
          case (funct3)
            3'b000: alu_op = ALU_SUB;
            3'b101: alu_op = ALU_SRA;
            default: illegal = 1'b1;
          endcase
        end else if (funct7 == 7'b0000001) begin
          case (funct3)
            3'b000: alu_op = ALU_MUL;
            3'b001: alu_op = ALU_MULH;
            3'b010: alu_op = ALU_MULHSU;
            3'b011: alu_op = ALU_MULHU;
            3'b100: alu_op = ALU_DIV;
            3'b101: alu_op = ALU_DIVU;
            3'b110: alu_op = ALU_REM;
            3'b111: alu_op = ALU_REMU;
          endcase
        end else begin
          illegal = 1'b1;
        end
      end
      7'b0001111: begin // MISC-MEM
        rd = '0; rs1 = '0; rs2 = '0;
        case (funct3)
          3'b000: ;                    // FENCE: no-op (blocking, write-through memory system)
          3'b001: sys_op = SYS_FENCEI; // FENCE.I
          default: illegal = 1'b1;
        endcase
      end
      7'b0101111: begin // AMO
        rd_we = 1'b1; imm = '0; op_b_imm = 1'b1; mem_size = SZ_W;
        if (funct3 != 3'b010) illegal = 1'b1;
        case (funct5)
          5'b00010: begin mem_op = MEM_LR; if (rs2 != 5'd0) illegal = 1'b1; end
          5'b00011: mem_op = MEM_SC;
          5'b00001: begin mem_op = MEM_AMO; amo_op = AMO_SWAP; end
          5'b00000: begin mem_op = MEM_AMO; amo_op = AMO_ADD;  end
          5'b00100: begin mem_op = MEM_AMO; amo_op = AMO_XOR;  end
          5'b01100: begin mem_op = MEM_AMO; amo_op = AMO_AND;  end
          5'b01000: begin mem_op = MEM_AMO; amo_op = AMO_OR;   end
          5'b10000: begin mem_op = MEM_AMO; amo_op = AMO_MIN;  end
          5'b10100: begin mem_op = MEM_AMO; amo_op = AMO_MAX;  end
          5'b11000: begin mem_op = MEM_AMO; amo_op = AMO_MINU; end
          5'b11100: begin mem_op = MEM_AMO; amo_op = AMO_MAXU; end
          default: illegal = 1'b1;
        endcase
      end
      7'b1110011: begin // SYSTEM
        rs2 = '0;
        if (funct3 == 3'b000) begin
          rd = '0;
          if (instr == 32'h00000073)      sys_op = SYS_ECALL;
          else if (instr == 32'h00100073) sys_op = SYS_EBREAK;
          else if (instr == 32'h30200073) sys_op = SYS_MRET;
          else if (instr == 32'h10200073) sys_op = SYS_SRET;
          else if (instr == 32'h10500073) sys_op = SYS_WFI;
          else if (funct7 == 7'b0001001 && instr[11:7] == 5'd0) begin
            sys_op = SYS_SFENCE; rs2 = instr[24:20];
          end else illegal = 1'b1;
          if (sys_op != SYS_SFENCE) rs1 = '0;
        end else if (funct3 == 3'b100) begin
          illegal = 1'b1;
        end else begin
          sys_op  = SYS_CSR;
          rd_we   = 1'b1;
          csr_op  = funct3[1:0];
          csr_imm = funct3[2];
          csr_wen = (funct3[1:0] == 2'b01) || (instr[19:15] != 5'd0);
          if (csr_imm) rs1 = '0;
        end
      end
      default: illegal = 1'b1;
    endcase

    if (illegal) begin
      rd_we  = 1'b0;
      mem_op = MEM_NONE;
      br_op  = BR_NONE;
      sys_op = SYS_NONE;
    end
  end

endmodule
