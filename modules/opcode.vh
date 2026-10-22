`ifndef OPCODE_VH
`define OPCODE_VH

// Bit field positions (Preprocessor Macros)
`define OPCODE      6:0
`define FUNC3       14:12
`define FUNC7       31:25
`define SUBTYPE     30
`define RD          11:7
`define RS1         19:15
`define RS2         24:20

`endif // OPCODE_VH

// Instructions & NOP
localparam [31:0] NOP         = 32'h0000_0013;

// Base RV32I Opcode constants (INST[6:0])
localparam [6:0]  LUI         = 7'b0110111,
                  JAL         = 7'b1101111,
                  JALR        = 7'b1100111,
                  BRANCH      = 7'b1100011,
                  LOAD        = 7'b0000011,
                  STORE       = 7'b0100011,
                  ARITHI      = 7'b0010011,
                  ARITHR      = 7'b0110011;

// Funct7 constants (INST[31:25])
localparam [6:0]  FUNCT7_BASE = 7'b0000000,
                  FUNCT7_ALT  = 7'b0100000,
                  FUNCT7_M    = 7'b0000001;

// Branch funct3 constants
localparam [2:0]  BEQ         = 3'b000,
                  BNE         = 3'b001,
                  BLT         = 3'b100,
                  BGE         = 3'b101,
                  BLTU        = 3'b110,
                  BGEU        = 3'b111;

// Load funct3 constants
localparam [2:0]  LB          = 3'b000,
                  LH          = 3'b001,
                  LW          = 3'b010,
                  LBU         = 3'b100,
                  LHU         = 3'b101;

// Store funct3 constants
localparam [2:0]  SB          = 3'b000,
                  SH          = 3'b001,
                  SW          = 3'b010;

// Base ALU funct3 constants
localparam [2:0]  ADD         = 3'b000,
                  SLL         = 3'b001,
                  SLT         = 3'b010,
                  SLTU        = 3'b011,
                  XOR         = 3'b100,
                  SR          = 3'b101,
                  OR          = 3'b110,
                  AND         = 3'b111;

// RV32M funct3 constants
localparam [2:0]  MUL         = 3'b000,
                  MULH        = 3'b001,
                  MULHSU      = 3'b010,
                  MULHU       = 3'b011,
                  DIV         = 3'b100,
                  DIVU        = 3'b101,
                  REM         = 3'b110,
                  REMU        = 3'b111;