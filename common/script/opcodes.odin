package script

// Instructions: 32 bits in Lua 5.4's layout. iABC: op(7) A(8) k(1) B(8) C(8); iABx:
// op(7) A(8) Bx(17); iAsBx: sBx = Bx - 65535; iAx: op(7) Ax(25); isJ: op(7) sJ(25).

Op :: enum u8 {
	MOVE,
	LOADI,
	LOADF,
	LOADK,
	LOADKX,
	LOADFALSE,
	LFALSESKIP,
	LOADTRUE,
	LOADNIL,
	GETUPVAL,
	SETUPVAL,
	GETGLOBAL,
	SETGLOBAL,
	GETTABLE,
	GETI,
	GETFIELD,
	SETTABLE,
	SETI,
	SETFIELD,
	NEWTABLE,
	SELF,
	ADDI,
	ADDK,
	SUBK,
	MULK,
	MODK,
	POWK,
	DIVK,
	IDIVK,
	BANDK,
	BORK,
	BXORK,
	SHRI,
	SHLI,
	ADD,
	SUB,
	MUL,
	MOD,
	POW,
	DIV,
	IDIV,
	BAND,
	BOR,
	BXOR,
	SHL,
	SHR,
	UNM,
	BNOT,
	NOT,
	LEN,
	CONCAT,
	CLOSE,
	JMP,
	EQ,
	LT,
	LE,
	EQK,
	EQI,
	LTI,
	LEI,
	GTI,
	GEI,
	TEST,
	TESTSET,
	CALL,
	TAILCALL,
	RETURN,
	RETURN0,
	RETURN1,
	FORLOOP,
	FORPREP,
	TFORPREP,
	TFORCALL,
	TFORLOOP,
	SETLIST,
	CLOSURE,
	VARARG,
	VARARGPREP,
	EXTRAARG,
}

Op_Format :: enum u8 {
	ABC,
	ABx,
	AsBx,
	Ax,
	sJ,
}

// Operand: what an operand names (the disassembler and the verifier read this).
Operand :: enum u8 {
	None,
	Reg, // a register
	Const, // a constant
	Upval, // an upvalue
	Proto, // a nested function
	Jump, // a jump offset
	Imm, // an immediate (signed where the field is)
	Count, // a count or flag
	Reg_Or_Const, // RK(C): a constant when k is set
}

Op_Info :: struct {
	format:  Op_Format,
	a, b, c: Operand,
}

OP_INFO := [Op]Op_Info {
	.MOVE       = {.ABC, .Reg, .Reg, .None},
	.LOADI      = {.AsBx, .Reg, .Imm, .None},
	.LOADF      = {.AsBx, .Reg, .Imm, .None},
	.LOADK      = {.ABx, .Reg, .Const, .None},
	.LOADKX     = {.ABx, .Reg, .None, .None},
	.LOADFALSE  = {.ABC, .Reg, .None, .None},
	.LFALSESKIP = {.ABC, .Reg, .None, .None},
	.LOADTRUE   = {.ABC, .Reg, .None, .None},
	.LOADNIL    = {.ABC, .Reg, .Count, .None},
	.GETUPVAL   = {.ABC, .Reg, .Upval, .None},
	.SETUPVAL   = {.ABC, .Reg, .Upval, .None},
	.GETGLOBAL  = {.ABx, .Reg, .Const, .None},
	.SETGLOBAL  = {.ABx, .Reg, .Const, .None},
	.GETTABLE   = {.ABC, .Reg, .Reg, .Reg},
	.GETI       = {.ABC, .Reg, .Reg, .Imm},
	.GETFIELD   = {.ABC, .Reg, .Reg, .Const},
	.SETTABLE   = {.ABC, .Reg, .Reg, .Reg_Or_Const},
	.SETI       = {.ABC, .Reg, .Imm, .Reg_Or_Const},
	.SETFIELD   = {.ABC, .Reg, .Const, .Reg_Or_Const},
	.NEWTABLE   = {.ABC, .Reg, .Count, .Count},
	.SELF       = {.ABC, .Reg, .Reg, .Reg_Or_Const},
	.ADDI       = {.ABC, .Reg, .Reg, .Imm},
	.ADDK       = {.ABC, .Reg, .Reg, .Const},
	.SUBK       = {.ABC, .Reg, .Reg, .Const},
	.MULK       = {.ABC, .Reg, .Reg, .Const},
	.MODK       = {.ABC, .Reg, .Reg, .Const},
	.POWK       = {.ABC, .Reg, .Reg, .Const},
	.DIVK       = {.ABC, .Reg, .Reg, .Const},
	.IDIVK      = {.ABC, .Reg, .Reg, .Const},
	.BANDK      = {.ABC, .Reg, .Reg, .Const},
	.BORK       = {.ABC, .Reg, .Reg, .Const},
	.BXORK      = {.ABC, .Reg, .Reg, .Const},
	.SHRI       = {.ABC, .Reg, .Reg, .Imm},
	.SHLI       = {.ABC, .Reg, .Reg, .Imm},
	.ADD        = {.ABC, .Reg, .Reg, .Reg},
	.SUB        = {.ABC, .Reg, .Reg, .Reg},
	.MUL        = {.ABC, .Reg, .Reg, .Reg},
	.MOD        = {.ABC, .Reg, .Reg, .Reg},
	.POW        = {.ABC, .Reg, .Reg, .Reg},
	.DIV        = {.ABC, .Reg, .Reg, .Reg},
	.IDIV       = {.ABC, .Reg, .Reg, .Reg},
	.BAND       = {.ABC, .Reg, .Reg, .Reg},
	.BOR        = {.ABC, .Reg, .Reg, .Reg},
	.BXOR       = {.ABC, .Reg, .Reg, .Reg},
	.SHL        = {.ABC, .Reg, .Reg, .Reg},
	.SHR        = {.ABC, .Reg, .Reg, .Reg},
	.UNM        = {.ABC, .Reg, .Reg, .None},
	.BNOT       = {.ABC, .Reg, .Reg, .None},
	.NOT        = {.ABC, .Reg, .Reg, .None},
	.LEN        = {.ABC, .Reg, .Reg, .None},
	.CONCAT     = {.ABC, .Reg, .Count, .None},
	.CLOSE      = {.ABC, .Reg, .None, .None},
	.JMP        = {.sJ, .Jump, .None, .None},
	.EQ         = {.ABC, .Reg, .Reg, .None},
	.LT         = {.ABC, .Reg, .Reg, .None},
	.LE         = {.ABC, .Reg, .Reg, .None},
	.EQK        = {.ABC, .Reg, .Const, .None},
	.EQI        = {.ABC, .Reg, .Imm, .Count},
	.LTI        = {.ABC, .Reg, .Imm, .Count},
	.LEI        = {.ABC, .Reg, .Imm, .Count},
	.GTI        = {.ABC, .Reg, .Imm, .Count},
	.GEI        = {.ABC, .Reg, .Imm, .Count},
	.TEST       = {.ABC, .Reg, .None, .None},
	.TESTSET    = {.ABC, .Reg, .Reg, .None},
	.CALL       = {.ABC, .Reg, .Count, .Count},
	.TAILCALL   = {.ABC, .Reg, .Count, .Count},
	.RETURN     = {.ABC, .Reg, .Count, .None},
	.RETURN0    = {.ABC, .None, .None, .None},
	.RETURN1    = {.ABC, .Reg, .None, .None},
	.FORLOOP    = {.ABx, .Reg, .Jump, .None},
	.FORPREP    = {.ABx, .Reg, .Jump, .None},
	.TFORPREP   = {.ABx, .Reg, .Jump, .None},
	.TFORCALL   = {.ABC, .Reg, .None, .Count},
	.TFORLOOP   = {.ABx, .Reg, .Jump, .None},
	.SETLIST    = {.ABC, .Reg, .Count, .Count},
	.CLOSURE    = {.ABx, .Reg, .Proto, .None},
	.VARARG     = {.ABC, .Reg, .None, .Count},
	.VARARGPREP = {.ABC, .Count, .None, .None},
	.EXTRAARG   = {.Ax, .Count, .None, .None},
}

MAXARG_A :: 255
MAXARG_B :: 255
MAXARG_C :: 255
MAXARG_BX :: 1 << 17 - 1
OFFSET_SBX :: MAXARG_BX >> 1 // 65535
MAXARG_AX :: 1 << 25 - 1
OFFSET_SJ :: 1 << 24 - 1
OFFSET_SC :: 127
NO_REG :: MAXARG_A

Instr :: u32

op_of :: #force_inline proc "contextless" (i: Instr) -> Op {return Op(i & 0x7f)}
arg_a :: #force_inline proc "contextless" (i: Instr) -> u32 {return (i >> 7) & 0xff}
arg_k :: #force_inline proc "contextless" (i: Instr) -> u32 {return (i >> 15) & 1}
arg_b :: #force_inline proc "contextless" (i: Instr) -> u32 {return (i >> 16) & 0xff}
arg_c :: #force_inline proc "contextless" (i: Instr) -> u32 {return i >> 24}
arg_sb :: #force_inline proc "contextless" (i: Instr) -> i32 {return i32(arg_b(i)) - OFFSET_SC}
arg_sc :: #force_inline proc "contextless" (i: Instr) -> i32 {return i32(arg_c(i)) - OFFSET_SC}
arg_bx :: #force_inline proc "contextless" (i: Instr) -> u32 {return i >> 15}
arg_sbx :: #force_inline proc "contextless" (i: Instr) -> i32 {return i32(i >> 15) - OFFSET_SBX}
arg_ax :: #force_inline proc "contextless" (i: Instr) -> u32 {return i >> 7}
arg_sj :: #force_inline proc "contextless" (i: Instr) -> i32 {return i32(i >> 7) - OFFSET_SJ}

make_abc :: #force_inline proc "contextless" (op: Op, a, b, c: u32, k: u32 = 0) -> Instr {
	return u32(op) | a << 7 | k << 15 | b << 16 | c << 24
}
make_abx :: #force_inline proc "contextless" (op: Op, a, bx: u32) -> Instr {
	return u32(op) | a << 7 | bx << 15
}
make_asbx :: #force_inline proc "contextless" (op: Op, a: u32, sbx: i32) -> Instr {
	return u32(op) | a << 7 | u32(sbx + OFFSET_SBX) << 15
}
make_ax :: #force_inline proc "contextless" (op: Op, ax: u32) -> Instr {
	return u32(op) | ax << 7
}
make_sj :: #force_inline proc "contextless" (op: Op, sj: i32) -> Instr {
	return u32(op) | u32(sj + OFFSET_SJ) << 7
}

set_arg_a :: #force_inline proc "contextless" (i: ^Instr, a: u32) {i^ =
		(i^ &~ (0xff << 7)) | a << 7}
set_arg_b :: #force_inline proc "contextless" (i: ^Instr, b: u32) {i^ =
		(i^ &~ (0xff << 16)) | b << 16}
set_arg_c :: #force_inline proc "contextless" (i: ^Instr, c: u32) {i^ =
		(i^ &~ (0xff << 24)) | c << 24}
set_arg_k :: #force_inline proc "contextless" (i: ^Instr, k: u32) {i^ =
		(i^ &~ (1 << 15)) | k << 15}
set_arg_sj :: #force_inline proc "contextless" (i: ^Instr, sj: i32) {i^ =
		(i^ & 0x7f) | u32(sj + OFFSET_SJ) << 7}
set_arg_bx :: #force_inline proc "contextless" (i: ^Instr, bx: u32) {i^ = (i^ & 0x7fff) | bx << 15}
