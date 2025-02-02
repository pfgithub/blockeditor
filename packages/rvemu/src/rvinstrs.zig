pub const RegBank = enum {
    sint,
    uint,
    float, // f0 - f32
    double,

    pub fn Type(self: RegBank) type {
        return switch (self) {
            .sint => i32,
            .uint => u32,
            .float => f32,
            .double => f64,
        };
    }
};

pub const InstrSpec = struct {
    name: @TypeOf(.enum_literal),
    format: enum { unknown, R, R4, RAtomic, I, IShift, IFence, S, B, U, J, None },

    opcode: u7,
    funct3: ?u3 = null,
    funct7: ?u7 = null,

    rd: ?u5 = null,
    rs1: ?u5 = null,
    imm_11_0: ?u11 = null,
    rs2: ?u5 = null,
    funct7_sub5: ?u5 = null,
    funct2: ?u2 = null,

    banks: ?struct {
        rd: ?RegBank = null,
        rs1: ?RegBank = null,
        rs2: ?RegBank = null,
        rs3: ?RegBank = null,
    } = null,
};
pub const InstrName = blk: {
    const std = @import("std");
    var names: [instrs.len]std.builtin.Type.EnumField = undefined;
    for (instrs, &names, 0..) |instr, *name, i| {
        name.* = .{ .name = @tagName(instr.name), .value = i };
    }
    const res: std.builtin.Type.Enum = .{
        .decls = &.{},
        .fields = &names,
        .is_exhaustive = true,
        .tag_type = std.math.IntFittingRange(0, names.len),
    };
    break :blk @Type(.{ .@"enum" = res });
};

pub const instrs: []const InstrSpec = &[_]InstrSpec{
    // Base
    .{ .name = .LUI, .format = .U, .opcode = 0b0110111, .banks = .{ .rd = .sint } },
    .{ .name = .AUIPC, .format = .U, .opcode = 0b0010111, .banks = .{ .rd = .sint } },
    .{ .name = .JAL, .format = .J, .opcode = 0b1101111, .banks = .{ .rd = .sint } },
    .{ .name = .JALR, .format = .I, .opcode = 0b1100111, .funct3 = 0b000, .banks = .{ .rs1 = .sint, .rd = .sint } },
    .{ .name = .BEQ, .format = .B, .opcode = 0b1100011, .funct3 = 0b000, .banks = .{ .rs1 = .sint, .rs2 = .sint } },
    .{ .name = .BNE, .format = .B, .opcode = 0b1100011, .funct3 = 0b001, .banks = .{ .rs1 = .sint, .rs2 = .sint } },
    .{ .name = .BLT, .format = .B, .opcode = 0b1100011, .funct3 = 0b100, .banks = .{ .rs1 = .sint, .rs2 = .sint } },
    .{ .name = .BGE, .format = .B, .opcode = 0b1100011, .funct3 = 0b101, .banks = .{ .rs1 = .sint, .rs2 = .sint } },
    .{ .name = .BLTU, .format = .B, .opcode = 0b1100011, .funct3 = 0b110, .banks = .{ .rs1 = .sint, .rs2 = .sint } },
    .{ .name = .BGEU, .format = .B, .opcode = 0b1100011, .funct3 = 0b111, .banks = .{ .rs1 = .sint, .rs2 = .sint } },
    .{ .name = .LB, .format = .I, .opcode = 0b0000011, .funct3 = 0b000, .banks = .{ .rs1 = .sint, .rd = .sint } },
    .{ .name = .LH, .format = .I, .opcode = 0b0000011, .funct3 = 0b001, .banks = .{ .rs1 = .sint, .rd = .sint } },
    .{ .name = .LW, .format = .I, .opcode = 0b0000011, .funct3 = 0b010, .banks = .{ .rs1 = .sint, .rd = .sint } },
    .{ .name = .LBU, .format = .I, .opcode = 0b0000011, .funct3 = 0b100, .banks = .{ .rs1 = .sint, .rd = .sint } },
    .{ .name = .LHU, .format = .I, .opcode = 0b0000011, .funct3 = 0b101, .banks = .{ .rs1 = .sint, .rd = .sint } },
    .{ .name = .SB, .format = .S, .opcode = 0b0100011, .funct3 = 0b000, .banks = .{ .rs1 = .sint, .rs2 = .sint } },
    .{ .name = .SH, .format = .S, .opcode = 0b0100011, .funct3 = 0b001, .banks = .{ .rs1 = .sint, .rs2 = .sint } },
    .{ .name = .SW, .format = .S, .opcode = 0b0100011, .funct3 = 0b010, .banks = .{ .rs1 = .sint, .rs2 = .sint } },
    .{ .name = .ADDI, .format = .I, .opcode = 0b0010011, .funct3 = 0b000, .banks = .{ .rs1 = .sint, .rd = .sint } },
    .{ .name = .SLTI, .format = .I, .opcode = 0b0010011, .funct3 = 0b010, .banks = .{ .rs1 = .sint, .rd = .sint } },
    .{ .name = .SLTIU, .format = .I, .opcode = 0b0010011, .funct3 = 0b011, .banks = .{ .rs1 = .sint, .rd = .sint } },
    .{ .name = .XORI, .format = .I, .opcode = 0b0010011, .funct3 = 0b100, .banks = .{ .rs1 = .sint, .rd = .sint } },
    .{ .name = .ORI, .format = .I, .opcode = 0b0010011, .funct3 = 0b110, .banks = .{ .rs1 = .sint, .rd = .sint } },
    .{ .name = .ANDI, .format = .I, .opcode = 0b0010011, .funct3 = 0b111, .banks = .{ .rs1 = .sint, .rd = .sint } },
    .{ .name = .SLLI, .format = .IShift, .opcode = 0b0010011, .funct3 = 0b001, .funct7 = 0b0000000, .banks = .{ .rs1 = .uint, .rd = .uint } },
    .{ .name = .SRLI, .format = .IShift, .opcode = 0b0010011, .funct3 = 0b101, .funct7 = 0b0000000, .banks = .{ .rs1 = .uint, .rd = .uint } },
    .{ .name = .SRAI, .format = .IShift, .opcode = 0b0010011, .funct3 = 0b101, .funct7 = 0b0100000, .banks = .{ .rs1 = .sint, .rd = .sint } },
    .{ .name = .ADD, .format = .R, .opcode = 0b0110011, .funct3 = 0b000, .funct7 = 0b0000000, .banks = .{ .rs1 = .sint, .rs2 = .sint, .rd = .sint } },
    .{ .name = .SUB, .format = .R, .opcode = 0b0110011, .funct3 = 0b000, .funct7 = 0b0100000, .banks = .{ .rs1 = .sint, .rs2 = .sint, .rd = .sint } },
    .{ .name = .SLL, .format = .R, .opcode = 0b0110011, .funct3 = 0b001, .funct7 = 0b0000000, .banks = .{ .rs1 = .sint, .rs2 = .sint, .rd = .sint } },
    .{ .name = .SLT, .format = .R, .opcode = 0b0110011, .funct3 = 0b010, .funct7 = 0b0000000, .banks = .{ .rs1 = .sint, .rs2 = .sint, .rd = .sint } },
    .{ .name = .SLTU, .format = .R, .opcode = 0b0110011, .funct3 = 0b011, .funct7 = 0b0000000, .banks = .{ .rs1 = .sint, .rs2 = .sint, .rd = .sint } },
    .{ .name = .XOR, .format = .R, .opcode = 0b0110011, .funct3 = 0b100, .funct7 = 0b0000000, .banks = .{ .rs1 = .sint, .rs2 = .sint, .rd = .sint } },
    .{ .name = .SRL, .format = .R, .opcode = 0b0110011, .funct3 = 0b101, .funct7 = 0b0000000, .banks = .{ .rs1 = .sint, .rs2 = .sint, .rd = .sint } },
    .{ .name = .SRA, .format = .R, .opcode = 0b0110011, .funct3 = 0b101, .funct7 = 0b0100000, .banks = .{ .rs1 = .sint, .rs2 = .sint, .rd = .sint } },
    .{ .name = .OR, .format = .R, .opcode = 0b0110011, .funct3 = 0b110, .funct7 = 0b0000000, .banks = .{ .rs1 = .sint, .rs2 = .sint, .rd = .sint } },
    .{ .name = .AND, .format = .R, .opcode = 0b0110011, .funct3 = 0b111, .funct7 = 0b0000000, .banks = .{ .rs1 = .sint, .rs2 = .sint, .rd = .sint } },
    .{ .name = .FENCE_OR_TSO_OR_PAUSE, .format = .IFence, .opcode = 0b0001111, .funct3 = 0b000 },
    .{ .name = .ECALL, .format = .None, .opcode = 0b1110011, .rd = 0b00000, .funct3 = 0b000, .rs1 = 0b00000, .imm_11_0 = 0b000000000000 },
    .{ .name = .EBREAK, .format = .None, .opcode = 0b1110011, .rd = 0b00000, .funct3 = 0b000, .rs1 = 0b00000, .imm_11_0 = 0b000000000001 },

    // M (Multiplication)
    .{ .name = .MUL, .format = .R, .opcode = 0b0110011, .funct3 = 0b000, .funct7 = 0b0000001, .banks = .{ .rs1 = .sint, .rs2 = .sint, .rd = .sint } },
    .{ .name = .MULH, .format = .R, .opcode = 0b0110011, .funct3 = 0b001, .funct7 = 0b0000001, .banks = .{ .rs1 = .sint, .rs2 = .sint, .rd = .sint } },
    .{ .name = .MULHSU, .format = .R, .opcode = 0b0110011, .funct3 = 0b010, .funct7 = 0b0000001, .banks = .{ .rs1 = .sint, .rs2 = .sint, .rd = .sint } },
    .{ .name = .MULHU, .format = .R, .opcode = 0b0110011, .funct3 = 0b011, .funct7 = 0b0000001, .banks = .{ .rs1 = .uint, .rs2 = .uint, .rd = .uint } },
    .{ .name = .DIV, .format = .R, .opcode = 0b0110011, .funct3 = 0b100, .funct7 = 0b0000001, .banks = .{ .rs1 = .sint, .rs2 = .sint, .rd = .sint } },
    .{ .name = .DIVU, .format = .R, .opcode = 0b0110011, .funct3 = 0b101, .funct7 = 0b0000001, .banks = .{ .rs1 = .uint, .rs2 = .uint, .rd = .uint } },
    .{ .name = .REM, .format = .R, .opcode = 0b0110011, .funct3 = 0b110, .funct7 = 0b0000001, .banks = .{ .rs1 = .sint, .rs2 = .sint, .rd = .sint } },
    .{ .name = .REMU, .format = .R, .opcode = 0b0110011, .funct3 = 0b111, .funct7 = 0b0000001, .banks = .{ .rs1 = .uint, .rs2 = .uint, .rd = .uint } },

    // A (Atomic)
    .{ .name = .LR_W, .format = .RAtomic, .opcode = 0b0101111, .funct3 = 0b010, .rs2 = 0b00000, .funct7_sub5 = 0b00010 },
    .{ .name = .SC_W, .format = .RAtomic, .opcode = 0b0101111, .funct3 = 0b010, .funct7_sub5 = 0b00011 },
    .{ .name = .AMOSWAP_W, .format = .RAtomic, .opcode = 0b0101111, .funct3 = 0b010, .funct7_sub5 = 0b00001 },
    .{ .name = .AMOADD_W, .format = .RAtomic, .opcode = 0b0101111, .funct3 = 0b010, .funct7_sub5 = 0b00000 },
    .{ .name = .AMOXOR_W, .format = .RAtomic, .opcode = 0b0101111, .funct3 = 0b010, .funct7_sub5 = 0b00100 },
    .{ .name = .AMOAND_W, .format = .RAtomic, .opcode = 0b0101111, .funct3 = 0b010, .funct7_sub5 = 0b01100 },
    .{ .name = .AMOOR_W, .format = .RAtomic, .opcode = 0b0101111, .funct3 = 0b010, .funct7_sub5 = 0b01000 },
    .{ .name = .AMOMIN_W, .format = .RAtomic, .opcode = 0b0101111, .funct3 = 0b010, .funct7_sub5 = 0b10000 },
    .{ .name = .AMOMAX_W, .format = .RAtomic, .opcode = 0b0101111, .funct3 = 0b010, .funct7_sub5 = 0b10100 },
    .{ .name = .AMOMINU_W, .format = .RAtomic, .opcode = 0b0101111, .funct3 = 0b010, .funct7_sub5 = 0b11000 },
    .{ .name = .AMOMAXU_W, .format = .RAtomic, .opcode = 0b0101111, .funct3 = 0b010, .funct7_sub5 = 0b11100 },

    // F (Float32)
    .{ .name = .FLW, .format = .I, .opcode = 0b0000111, .funct3 = 0b010 },
    .{ .name = .FSW, .format = .S, .opcode = 0b0100111, .funct3 = 0b010 },
    .{ .name = .FMADD_S, .format = .R4, .opcode = 0b1000011, .funct2 = 0b00 },
    .{ .name = .FMSUB_S, .format = .R4, .opcode = 0b1000111, .funct2 = 0b00 },
    .{ .name = .FNMSUB_S, .format = .R4, .opcode = 0b1001011, .funct2 = 0b00 },
    .{ .name = .FNMADD_S, .format = .R4, .opcode = 0b1001111, .funct2 = 0b00 },
    .{ .name = .FADD_S, .format = .R, .opcode = 0b1010011, .funct7 = 0b0000000 },
    .{ .name = .FSUB_S, .format = .R, .opcode = 0b1010011, .funct7 = 0b0000100 },
    .{ .name = .FMUL_S, .format = .R, .opcode = 0b1010011, .funct7 = 0b0001000 },
    .{ .name = .FDIV_S, .format = .R, .opcode = 0b1010011, .funct7 = 0b0001100 },
    .{ .name = .FSQRT_S, .format = .R, .opcode = 0b1010011, .funct7 = 0b0101100, .rs2 = 0b00000 },
    .{ .name = .FSGNJ_S, .format = .R, .opcode = 0b1010011, .funct7 = 0b0010000, .funct3 = 0b000 },
    .{ .name = .FSGNJN_S, .format = .R, .opcode = 0b1010011, .funct7 = 0b0010000, .funct3 = 0b001 },
    .{ .name = .FSGNJX_S, .format = .R, .opcode = 0b1010011, .funct7 = 0b0010000, .funct3 = 0b010 },
    .{ .name = .FMIN_S, .format = .R, .opcode = 0b1010011, .funct7 = 0b0010100, .funct3 = 0b000 },
    .{ .name = .FMAX_S, .format = .R, .opcode = 0b1010011, .funct7 = 0b0010100, .funct3 = 0b001 },
    .{ .name = .FCVT_W_S, .format = .R, .opcode = 0b1010011, .funct7 = 0b1100000, .rs2 = 0b00000 },
    .{ .name = .FCVT_WU_S, .format = .R, .opcode = 0b1010011, .funct7 = 0b1100000, .rs2 = 0b00001 },
    .{ .name = .FMV_X_W, .format = .R, .opcode = 0b1010011, .funct7 = 0b1110000, .rs2 = 0b00000, .funct3 = 0b000 },
    .{ .name = .FEQ_S, .format = .R, .opcode = 0b1010011, .funct7 = 0b1010000, .funct3 = 0b010 },
    .{ .name = .FLT_S, .format = .R, .opcode = 0b1010011, .funct7 = 0b1010000, .funct3 = 0b001 },
    .{ .name = .FLE_S, .format = .R, .opcode = 0b1010011, .funct7 = 0b1010000, .funct3 = 0b000 },
    .{ .name = .FCLASS_S, .format = .R, .opcode = 0b1010011, .funct7 = 0b1110000, .funct3 = 0b001, .rs2 = 0b00000 },
    .{ .name = .FCVT_S_W, .format = .R, .opcode = 0b1010011, .funct7 = 0b1101000, .rs2 = 0b00000 },
    .{ .name = .FCVT_S_WU, .format = .R, .opcode = 0b1010011, .funct7 = 0b1101000, .rs2 = 0b00001 },
    .{ .name = .FMV_W_X, .format = .R, .opcode = 0b1010011, .funct7 = 0b1111000, .rs2 = 0b00000, .funct3 = 0b000 },

    // D (Float64)
    .{ .name = .FLD, .format = .I, .opcode = 0b0000111, .funct3 = 0b011 },
    .{ .name = .FSD, .format = .S, .opcode = 0b0100111, .funct3 = 0b011 },
    .{ .name = .FMADD_D, .format = .R4, .opcode = 0b1000011, .funct2 = 0b01 },
    .{ .name = .FMSUB_D, .format = .R4, .opcode = 0b1000111, .funct2 = 0b01 },
    .{ .name = .FNMSUB_D, .format = .R4, .opcode = 0b1001011, .funct2 = 0b01 },
    .{ .name = .FNMADD_D, .format = .R4, .opcode = 0b1001111, .funct2 = 0b01 },
    .{ .name = .FADD_D, .format = .R, .opcode = 0b1010011, .funct7 = 0b0000001 },
    .{ .name = .FSUB_D, .format = .R, .opcode = 0b1010011, .funct7 = 0b0000101 },
    .{ .name = .FMUL_D, .format = .R, .opcode = 0b1010011, .funct7 = 0b0001001 },
    .{ .name = .FDIV_D, .format = .R, .opcode = 0b1010011, .funct7 = 0b0001101 },
    .{ .name = .FSQRT_D, .format = .R, .opcode = 0b1010011, .funct7 = 0b0101101, .rs2 = 0b00000 },
    .{ .name = .FSGNJ_D, .format = .R, .opcode = 0b1010011, .funct7 = 0b0010001, .funct3 = 0b000 },
    .{ .name = .FSGNJN_D, .format = .R, .opcode = 0b1010011, .funct7 = 0b0010001, .funct3 = 0b001 },
    .{ .name = .FSGNJX_D, .format = .R, .opcode = 0b1010011, .funct7 = 0b0010001, .funct3 = 0b010 },
    .{ .name = .FMIN_D, .format = .R, .opcode = 0b1010011, .funct7 = 0b0010101, .funct3 = 0b000 },
    .{ .name = .FMAX_D, .format = .R, .opcode = 0b1010011, .funct7 = 0b0010101, .funct3 = 0b001 },
    .{ .name = .FCVT_S_D, .format = .R, .opcode = 0b1010011, .funct7 = 0b0100000, .rs2 = 0b00001 },
    .{ .name = .FCVT_D_S, .format = .R, .opcode = 0b1010011, .funct7 = 0b0100001, .rs2 = 0b00000 },
    .{ .name = .FEQ_D, .format = .R, .opcode = 0b1010011, .funct7 = 0b1010001, .funct3 = 0b010 },
    .{ .name = .FLT_D, .format = .R, .opcode = 0b1010011, .funct7 = 0b1010001, .funct3 = 0b001 },
    .{ .name = .FLE_D, .format = .R, .opcode = 0b1010011, .funct7 = 0b1010001, .funct3 = 0b000 },
    .{ .name = .FCLASS_D, .format = .R, .opcode = 0b1010011, .funct7 = 0b1110001, .funct3 = 0b001, .rs2 = 0b00000 },
    .{ .name = .FCVT_W_D, .format = .R, .opcode = 0b1010011, .funct7 = 0b1100001, .rs2 = 0b00000 },
    .{ .name = .FCVT_WU_D, .format = .R, .opcode = 0b1010011, .funct7 = 0b1100001, .rs2 = 0b00001 },
    .{ .name = .FCVT_D_W, .format = .R, .opcode = 0b1010011, .funct7 = 0b1101001, .rs2 = 0b00000 },
    .{ .name = .FCVT_D_WU, .format = .R, .opcode = 0b1010011, .funct7 = 0b1101001, .rs2 = 0b00001 },
};

// we should be able to, when calling an instruction:
// - always pre-fetch args
// - return the result out to go into rd
// (based on type)
