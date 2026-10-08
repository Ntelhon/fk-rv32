// fk-core: shared types and constants
package fk_pkg;

  // Privilege levels
  localparam logic [1:0] PRV_U = 2'd0;
  localparam logic [1:0] PRV_S = 2'd1;
  localparam logic [1:0] PRV_M = 2'd3;

  // Exception causes
  localparam logic [4:0] EXC_IADDR_MISALIGN = 5'd0;
  localparam logic [4:0] EXC_IACCESS        = 5'd1;
  localparam logic [4:0] EXC_ILLEGAL        = 5'd2;
  localparam logic [4:0] EXC_BREAKPOINT     = 5'd3;
  localparam logic [4:0] EXC_LADDR_MISALIGN = 5'd4;
  localparam logic [4:0] EXC_LACCESS        = 5'd5;
  localparam logic [4:0] EXC_SADDR_MISALIGN = 5'd6;
  localparam logic [4:0] EXC_SACCESS        = 5'd7;
  localparam logic [4:0] EXC_ECALL_U        = 5'd8;
  localparam logic [4:0] EXC_ECALL_S        = 5'd9;
  localparam logic [4:0] EXC_ECALL_M        = 5'd11;
  localparam logic [4:0] EXC_IPAGE          = 5'd12;
  localparam logic [4:0] EXC_LPAGE          = 5'd13;
  localparam logic [4:0] EXC_SPAGE          = 5'd15;

  // Interrupt causes
  localparam logic [4:0] IRQ_S_SOFT  = 5'd1;
  localparam logic [4:0] IRQ_M_SOFT  = 5'd3;
  localparam logic [4:0] IRQ_S_TIMER = 5'd5;
  localparam logic [4:0] IRQ_M_TIMER = 5'd7;
  localparam logic [4:0] IRQ_S_EXT   = 5'd9;
  localparam logic [4:0] IRQ_M_EXT   = 5'd11;

  typedef enum logic [4:0] {
    ALU_ADD, ALU_SUB, ALU_SLL, ALU_SLT, ALU_SLTU, ALU_XOR, ALU_SRL, ALU_SRA,
    ALU_OR, ALU_AND, ALU_PASSB,
    ALU_MUL, ALU_MULH, ALU_MULHSU, ALU_MULHU,
    ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU
  } alu_op_t;

  typedef enum logic [2:0] {
    MEM_NONE, MEM_LOAD, MEM_STORE, MEM_AMO, MEM_LR, MEM_SC
  } mem_op_t;

  typedef enum logic [3:0] {
    AMO_SWAP, AMO_ADD, AMO_XOR, AMO_AND, AMO_OR,
    AMO_MIN, AMO_MAX, AMO_MINU, AMO_MAXU
  } amo_op_t;

  typedef enum logic [3:0] {
    SYS_NONE, SYS_CSR, SYS_ECALL, SYS_EBREAK, SYS_MRET, SYS_SRET,
    SYS_WFI, SYS_SFENCE, SYS_FENCEI
  } sys_op_t;

  typedef enum logic [3:0] {
    BR_NONE, BR_BEQ, BR_BNE, BR_BLT, BR_BGE, BR_BLTU, BR_BGEU, BR_JAL, BR_JALR
  } br_op_t;

  // D-cache request kinds
  typedef enum logic [1:0] {
    DC_LOAD, DC_STORE, DC_AMO
  } dc_op_t;

  // Access size
  localparam logic [1:0] SZ_B = 2'd0;
  localparam logic [1:0] SZ_H = 2'd1;
  localparam logic [1:0] SZ_W = 2'd2;

  // PTE flags as stored in the TLB
  typedef struct packed {
    logic d, a, g, u, x, w, r;
  } pte_flags_t;

  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] instr;
    logic        exc;
    logic [4:0]  exc_cause;
    logic [31:0] exc_tval;
  } if_id_t;

  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] instr;
    logic        exc;
    logic [4:0]  exc_cause;
    logic [31:0] exc_tval;
    logic [4:0]  rs1, rs2, rd;
    logic        rd_we;
    logic [31:0] rs1_val, rs2_val, imm;
    logic        op_a_pc;
    logic        op_b_imm;
    alu_op_t     alu_op;
    br_op_t      br_op;
    mem_op_t     mem_op;
    amo_op_t     amo_op;
    logic [1:0]  mem_size;
    logic        mem_unsigned;
    sys_op_t     sys_op;
    logic [1:0]  csr_op;   // 1=RW 2=RS 3=RC
    logic        csr_imm;
    logic        csr_wen;
  } id_ex_t;

  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] instr;
    logic        exc;
    logic [4:0]  exc_cause;
    logic [31:0] exc_tval;
    logic [4:0]  rd;
    logic        rd_we;
    logic [31:0] result;     // ALU result / memory address
    logic [31:0] store_data;
    mem_op_t     mem_op;
    amo_op_t     amo_op;
    logic [1:0]  mem_size;
    logic        mem_unsigned;
    sys_op_t     sys_op;
    logic [1:0]  csr_op;
    logic        csr_wen;
    logic [31:0] csr_operand;
  } ex_mem_t;

  typedef struct packed {
    logic        valid;
    logic [4:0]  rd;
    logic        rd_we;
    logic [31:0] data;
  } mem_wb_t;

endpackage
