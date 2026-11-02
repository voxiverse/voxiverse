package script

// Object layouts in the heap. Each starts with Header; objects refer to each other by
// Ref, so the heap is position independent. Field order is the snapshot's layout.

Obj_Kind :: enum u8 {
	Free,
	String,
	Table,
	Closure,
	Native_Closure,
	Upvalue,
	Proto,
	Thread,
	Values,
	Bytes,
}

Header :: struct {
	size:  u32, // bytes including the header, a multiple of 16
	kind:  Obj_Kind,
	mark:  u8,
	flags: u8,
	_:     u8,
}
#assert(size_of(Header) == 8)

// BUF_DATA: where a Values or Bytes buffer's contents begin.
BUF_DATA :: 8

String :: struct {
	using hdr: Header,
	len:       u32,
	hash:      u32,
	// len bytes and a zero byte follow
}
STRING_DATA :: 16
#assert(size_of(String) == STRING_DATA)

Table :: struct {
	using hdr:   Header,
	meta:        Ref,
	arr:         Ref, // Values
	arr_len:     u32,
	arr_cap:     u32,
	entries:     Ref, // Values: key, value per entry, in insertion order
	entries_len: u32,
	entries_cap: u32,
	live:        u32,
	index:       Ref, // Bytes: u32 slots, entry number + 1, 0 empty
	index_mask:  u32,
	mm_absent:   u16, // a bit per metamethod known absent (as a metatable)
	_:           u16,
	id:          u32,
	gclist:      Ref,
}

Upval_Desc :: struct {
	instack:    u8,
	index:      u8,
	_:          u16,
	name_const: u32,
}

Line_Info :: struct {
	line: u32,
	col:  u16,
	span: u16, // bytes the caret underlines
}

Local_Info :: struct {
	name_const: u32,
	start_pc:   u32,
	end_pc:     u32,
	register:   u32,
}

Proto :: struct {
	using hdr:    Header,
	code:         Ref, // Bytes of u32 instructions
	consts:       Ref, // Values
	protos:       Ref, // Values of nested protos
	upvals:       Ref, // Bytes of Upval_Desc
	lines:        Ref, // Bytes of Line_Info, one per instruction
	locals:       Ref, // Bytes of Local_Info
	source:       Ref,
	name:         Ref,
	text:         Ref, // the module's source text, for error messages
	code_len:     u32,
	consts_len:   u32,
	protos_len:   u32,
	upvals_len:   u32,
	locals_len:   u32,
	line_defined: u32,
	last_line:    u32,
	num_params:   u8,
	is_vararg:    u8,
	max_stack:    u8,
	_:            u8,
	gclist:       Ref,
}

Closure :: struct {
	using hdr: Header,
	proto:     Ref,
	env:       Ref, // the globals table it reads and writes
	id:        u32,
	nup:       u16,
	_:         u16,
	// nup upvalue Refs follow
}
CLOSURE_UPVALS :: 24
#assert(size_of(Closure) == CLOSURE_UPVALS)

Intrinsic :: enum u8 {
	None,
	Pcall,
	Xpcall,
	Resume,
	Yield,
	Wrap,
}

Native_Closure :: struct {
	using hdr: Header,
	native:    u32, // index into the VM's native table
	intrinsic: Intrinsic,
	_:         u8,
	nup:       u16,
	id:        u32,
	_:         u32,
	// nup values follow
}
NATIVE_UPVALS :: 24
#assert(size_of(Native_Closure) == NATIVE_UPVALS)

Upvalue :: struct {
	using hdr: Header,
	value:     Value, // when closed
	thread:    Ref,
	slot:      u32,
	open:      bool,
	_:         [3]u8,
	next_open: Ref, // the thread's open list, sorted by slot, highest first
}

Thread_Status :: enum u8 {
	Suspended,
	Running,
	Normal,
	Dead,
}

Thread :: struct {
	using hdr:   Header,
	stack:       Ref, // Values
	stack_cap:   u32,
	top:         u32,
	frames:      Ref, // Bytes of Frame
	frame_count: u32,
	frame_cap:   u32,
	open_upvals: Ref,
	status:      Thread_Status,
	_:           [3]u8,
	resumer:     Ref,
	id:          u32,
	gclist:      Ref,
}

// Cont: what finishes the caller's instruction when a frame returns.
Cont :: enum u8 {
	None,
	Host,
	Store,
	Compare,
	Discard,
	Concat,
	Pcall,
	Xpcall,
	Xpcall_Handler,
	Resume,
}

Frame_Flag :: enum u8 {
	Protected,
	Native,
	Tail,
}

// Frame: plain integers, no Ref (the function is its stack slot).
Frame :: struct {
	func:     u32,
	base:     u32,
	top:      u32,
	pc:       u32,
	nresults: i16, // -1: multiple
	cont:     Cont,
	flags:    bit_set[Frame_Flag;u8],
	nvarargs: u16,
	_:        u16,
	cont_arg: u32,
}
#assert(size_of(Frame) == 28)

obj :: #force_inline proc "contextless" (vm: ^VM, r: Ref, $T: typeid) -> ^T {
	return (^T)(&vm.mem[r])
}

values_of :: #force_inline proc "contextless" (vm: ^VM, r: Ref, n: u32) -> []Value {
	return ([^]Value)(&vm.mem[u32(r) + BUF_DATA])[:n]
}

bytes_of :: #force_inline proc "contextless" (vm: ^VM, r: Ref, $T: typeid, n: u32) -> []T {
	return ([^]T)(&vm.mem[u32(r) + BUF_DATA])[:n]
}

string_bytes :: #force_inline proc "contextless" (vm: ^VM, r: Ref) -> string {
	s := (^String)(&vm.mem[r])
	return string(vm.mem[u32(r) + STRING_DATA:][:s.len])
}

value_string :: #force_inline proc "contextless" (vm: ^VM, v: Value) -> string {
	return string_bytes(vm, as_ref(v))
}

closure_upvals :: #force_inline proc "contextless" (vm: ^VM, r: Ref) -> []Ref {
	c := (^Closure)(&vm.mem[r])
	return ([^]Ref)(&vm.mem[u32(r) + CLOSURE_UPVALS])[:c.nup]
}

native_upvals :: #force_inline proc "contextless" (vm: ^VM, r: Ref) -> []Value {
	c := (^Native_Closure)(&vm.mem[r])
	return ([^]Value)(&vm.mem[u32(r) + NATIVE_UPVALS])[:c.nup]
}

obj_kind :: #force_inline proc "contextless" (vm: ^VM, r: Ref) -> Obj_Kind {
	return (^Header)(&vm.mem[r]).kind
}

// The collector's barriers: empty until M51b fills them in. Every store into a heap
// object calls one.
barrier_back :: #force_inline proc "contextless" (vm: ^VM, t: Ref) {}
barrier_forward :: #force_inline proc "contextless" (vm: ^VM, owner: Ref, v: Value) {}
