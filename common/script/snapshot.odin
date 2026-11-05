package script

import "core:fmt"
import "core:hash/xxhash"
import "core:strings"

// Snapshots: a VM that is idle, suspended or yielded, as bytes, and a new VM made
// from them. The heap is copied as it is (objects refer to each other by offset), so equal
// VM states give equal bytes on every OS. The format, little-endian, version 1:
//
//	"VXSS" version:u16 flags:u16 header_size:u32 checksum:u64 (XXH64 of what follows, seed 0)
//	the scalars (configuration, collector, heap, roots, strings, run, output)
//	the native names in id order, the handle kind names in kind order (u16 length + bytes)
//	the heap's bytes from 0 to top (header_size says where they begin)
//
// restore refuses a snapshot it cannot read, with a message naming the problem, and validates
// the structure before anything runs: every header, every reference, every frame, every
// proto (verify_proto). A save file is our own output, but a damaged one must not crash the
// server (ground rule 6).

SNAPSHOT_MAGIC :: "VXSS"
SNAPSHOT_VERSION :: 1
SNAPSHOT_FIXED :: 20 // magic, version, flags, header_size, checksum
SNAPSHOT_FLAG_GC_STRESS :: 1

// SNAPSHOT_FILL: a program that fills a 16 MiB heap with live strings (the size test and
// the snapshot benchmark).
SNAPSHOT_FILL :: `full = {}
for i = 1, 15200 do full[i] = string.rep("v", 1000) .. i end`

// Snapshots are for 64-bit little-endian targets (x64, arm64).
#assert(size_of(rawptr) == 8)
#assert(ODIN_ENDIAN == .Little)

@(private = "file")
Writer :: struct {
	buf: [dynamic]u8,
}

@(private = "file")
put :: proc(w: ^Writer, v: $T) {
	v := v
	b := transmute([size_of(T)]u8)v
	append(&w.buf, ..b[:])
}

@(private = "file")
put_value :: proc(w: ^Writer, v: Value) {
	put(w, v.bits)
	put(w, u8(v.tag))
	put(w, v.kind)
}

@(private = "file")
put_name :: proc(w: ^Writer, s: string) {
	put(w, u16(len(s)))
	append(&w.buf, s)
}

// snapshot writes vm's state; the VM must not be running.
snapshot :: proc(vm: ^VM, allocator := context.allocator) -> []u8 {
	assert(vm.state != .Running, "snapshot of a running VM")
	w := Writer {
		buf = make([dynamic]u8, 0, int(vm.top) + 4096, allocator),
	}
	append(&w.buf, SNAPSHOT_MAGIC)
	put(&w, u16(SNAPSHOT_VERSION))
	put(&w, u16(SNAPSHOT_FLAG_GC_STRESS if vm.gc_stress else 0))
	put(&w, u32(0)) // header_size, set below
	put(&w, u64(0)) // checksum, set below
	put(&w, vm.seed)
	l := vm.limits
	put(&w, l.slice)
	put(&w, l.run_instructions)
	put(&w, i64(l.memory))
	put(&w, l.call_depth)
	put(&w, l.string_max)
	put(&w, l.output_max)
	gp := vm.gc_params
	put(&w, gp.pause)
	put(&w, gp.stepmul)
	put(&w, gp.step_bytes)
	put(&w, gp.min_threshold)
	g := vm.gc
	put(&w, u8(g.phase))
	put(&w, g.white)
	put(&w, g.gray)
	put(&w, g.grayagain)
	put(&w, g.sweep)
	put(&w, g.sweep_run)
	put(&w, g.credit)
	put(&w, g.allocated)
	put(&w, g.estimate)
	put(&w, g.threshold)
	put(&w, g.collections)
	put(&w, g.units)
	put(&w, g.peak)
	put(&w, vm.top)
	put(&w, vm.in_use)
	for r in vm.free_small {put(&w, r)}
	for r in vm.free_large {put(&w, r)}
	for r in ([?]Ref{vm.globals, vm.registry, vm.string_meta, vm.handle_metas, vm.prelude_table, vm.main_thread, vm.current}) {
		put(&w, r)
	}
	put_value(&w, vm.call_through)
	for r in vm.mm_names {put(&w, r)}
	put(&w, vm.intern)
	put(&w, vm.intern_mask)
	put(&w, vm.intern_count)
	put(&w, vm.next_id)
	put(&w, u8(vm.state))
	put(&w, vm.meter)
	put(&w, vm.budget)
	put(&w, u8(vm.budget_is_last))
	put(&w, vm.run_used)
	put(&w, vm.depth)
	put(&w, u8(vm.fault))
	put(&w, u8(vm.yielding))
	put(&w, u8(vm.pending))
	put(&w, vm.yield_from)
	put(&w, u64(vm.output_dropped))
	put(&w, u32(len(vm.output)))
	append(&w.buf, ..vm.output[:])
	put(&w, u32(len(vm.natives)))
	for n in vm.natives {put_name(&w, n.name)}
	put(&w, u32(len(vm.handle_kinds)))
	for k in vm.handle_kinds {put_name(&w, k)}
	header_size := u32(len(w.buf))
	append(&w.buf, ..vm.mem[:vm.top])
	b := w.buf[:]
	(^u32le)(&b[8])^ = u32le(header_size)
	(^u64le)(&b[12])^ = u64le(xxhash.XXH64(b[SNAPSHOT_FIXED:]))
	return b
}

// heap_hash: XXH64 of the heap's bytes (tests compare VM states with it).
heap_hash :: proc(vm: ^VM) -> u64 {
	return xxhash.XXH64(vm.mem[:vm.top])
}

@(private = "file")
Reader :: struct {
	data: []u8,
	at:   int,
	ok:   bool,
}

@(private = "file")
get :: proc(r: ^Reader, $T: typeid) -> T {
	if !r.ok || r.at + size_of(T) > len(r.data) {
		r.ok = false
		return {}
	}
	b: [size_of(T)]u8
	copy(b[:], r.data[r.at:])
	r.at += size_of(T)
	return transmute(T)b
}

@(private = "file")
get_bytes :: proc(r: ^Reader, n: int) -> []u8 {
	if !r.ok || n < 0 || r.at + n > len(r.data) {
		r.ok = false
		return nil
	}
	b := r.data[r.at:][:n]
	r.at += n
	return b
}

@(private = "file")
get_value :: proc(r: ^Reader) -> Value {
	v: Value
	v.bits = get(r, u64)
	v.tag = Tag(get(r, u8))
	v.kind = get(r, u16)
	return v
}

@(private = "file")
get_name :: proc(r: ^Reader) -> string {
	n := get(r, u16)
	return string(get_bytes(r, int(n)))
}

// restore makes a new VM from a snapshot. The configuration gives the natives and handle
// kinds the host offers (every one the snapshot names must be there), the heap's size
// (config.limits.memory; the snapshot's when 0) and whether to verify compiled code; the
// other limits, the seed and the collector's pacing are the snapshot's.
restore :: proc(
	bytes: []u8,
	config: Config,
	allocator := context.allocator,
) -> (
	^VM,
	Script_Error,
) {
	return restore_from(bytes, config, true, allocator)
}

// restore_unchecked: restore without the checksum (tests and the snapshot fuzzer, so a
// mutation reaches the validation).
restore_unchecked :: proc(
	bytes: []u8,
	config: Config,
	allocator := context.allocator,
) -> (
	^VM,
	Script_Error,
) {
	return restore_from(bytes, config, false, allocator)
}

@(private = "file")
refused :: proc(format: string, args: ..any) -> Script_Error {
	return Script_Error{kind = .Runtime, message = fmt.tprintf(format, ..args)}
}

@(private = "file")
restore_from :: proc(
	bytes: []u8,
	config: Config,
	check_sum: bool,
	allocator := context.allocator,
) -> (
	^VM,
	Script_Error,
) {
	if len(bytes) < 4 || string(bytes[:4]) != SNAPSHOT_MAGIC {
		return nil, refused("not a script snapshot (no 'VXSS' at the start)")
	}
	if len(bytes) < SNAPSHOT_FIXED {return nil, refused("the snapshot is truncated")}
	r := Reader {
		data = bytes,
		at   = 4,
		ok   = true,
	}
	version := get(&r, u16)
	if version != SNAPSHOT_VERSION {
		return nil, refused("snapshot version %d; this build reads %d", version, SNAPSHOT_VERSION)
	}
	flags := get(&r, u16)
	header_size := get(&r, u32)
	sum := get(&r, u64)
	if flags &~ SNAPSHOT_FLAG_GC_STRESS != 0 {
		return nil, refused("the snapshot has flags this build does not know")
	}

	s: VM // the scalars, read into a VM value first
	s.seed = get(&r, u64)
	s.limits.slice = get(&r, i64)
	s.limits.run_instructions = get(&r, i64)
	s.limits.memory = int(get(&r, i64))
	s.limits.call_depth = get(&r, u32)
	s.limits.string_max = get(&r, u32)
	s.limits.output_max = get(&r, u32)
	s.gc_params.pause = get(&r, u32)
	s.gc_params.stepmul = get(&r, u32)
	s.gc_params.step_bytes = get(&r, u32)
	s.gc_params.min_threshold = get(&r, u64)
	phase := get(&r, u8)
	s.gc.white = get(&r, u8)
	s.gc.gray = get(&r, Ref)
	s.gc.grayagain = get(&r, Ref)
	s.gc.sweep = get(&r, u32)
	s.gc.sweep_run = get(&r, u32)
	s.gc.credit = get(&r, i64)
	s.gc.allocated = get(&r, i64)
	s.gc.estimate = get(&r, u64)
	s.gc.threshold = get(&r, u64)
	s.gc.collections = get(&r, u64)
	s.gc.units = get(&r, u64)
	s.gc.peak = get(&r, u64)
	s.top = get(&r, u32)
	s.in_use = get(&r, u64)
	for &f in s.free_small {f = get(&r, Ref)}
	for &f in s.free_large {f = get(&r, Ref)}
	s.globals = get(&r, Ref)
	s.registry = get(&r, Ref)
	s.string_meta = get(&r, Ref)
	s.handle_metas = get(&r, Ref)
	s.prelude_table = get(&r, Ref)
	s.main_thread = get(&r, Ref)
	s.current = get(&r, Ref)
	s.call_through = get_value(&r)
	for &m in s.mm_names {m = get(&r, Ref)}
	s.intern = get(&r, Ref)
	s.intern_mask = get(&r, u32)
	s.intern_count = get(&r, u32)
	s.next_id = get(&r, u32)
	state := get(&r, u8)
	s.meter = get(&r, i64)
	s.budget = get(&r, i64)
	budget_is_last := get(&r, u8)
	s.run_used = get(&r, i64)
	s.depth = get(&r, u32)
	fault := get(&r, u8)
	yielding := get(&r, u8)
	pending := get(&r, u8)
	s.yield_from = get(&r, u32)
	dropped := get(&r, u64)
	output := get_bytes(&r, int(get(&r, u32)))
	n_natives := get(&r, u32)
	if !r.ok {return nil, refused("the snapshot is truncated")}
	if u64(n_natives) > u64(len(bytes)) {return nil, refused("the snapshot is truncated")}
	native_names := make([]string, n_natives, context.temp_allocator)
	for &n in native_names {n = get_name(&r)}
	n_kinds := get(&r, u32)
	if !r.ok || u64(n_kinds) > u64(len(bytes)) {return nil, refused("the snapshot is truncated")}
	kind_names := make([]string, n_kinds, context.temp_allocator)
	for &k in kind_names {k = get_name(&r)}
	if !r.ok {return nil, refused("the snapshot is truncated")}
	if int(header_size) != r.at {return nil, refused("the snapshot's header size is wrong")}
	if len(bytes) - r.at < int(s.top) {return nil, refused("the snapshot is truncated")}
	if len(bytes) - r.at >
	   int(s.top) {return nil, refused("the snapshot has bytes after its heap")}
	// The checksum once the lengths are known (a truncated file says so, not "damaged").
	if check_sum && sum != xxhash.XXH64(bytes[SNAPSHOT_FIXED:]) {
		return nil, refused("the snapshot's checksum is wrong (the file is damaged)")
	}

	// The scalars that are enums or flags, and the sizes.
	switch {
	case phase > u8(max(Gc_Phase)):
		return nil, refused("the snapshot's collector phase is not one")
	case s.gc.white > 1:
		return nil, refused("the snapshot's current white is not one")
	case state > u8(max(VM_State)) || VM_State(state) == .Running:
		return nil, refused("the snapshot's run state is not one a snapshot has")
	case fault > u8(max(Limit_Kind)):
		return nil, refused("the snapshot's fault is not one")
	case budget_is_last > 1 || yielding > 1 || pending > 1:
		return nil, refused("the snapshot has a flag that is not 0 or 1")
	case s.top < HEAP_START || s.top % 16 != 0:
		return nil, refused("the snapshot's heap has a bad size")
	case s.limits.slice <= 0 || s.limits.run_instructions < 0 || s.limits.call_depth == 0:
		return nil, refused("the snapshot's limits are out of range")
	case s.limits.memory < MEMORY_MIN || s.limits.memory > MEMORY_MAX:
		return nil, refused("the snapshot's memory limit is out of range (256 KiB to 1 GiB)")
	case dropped > u64(max(i32)) || len(output) > int(s.limits.output_max) + 4096:
		return nil, refused("the snapshot's pending output is out of range")
	}
	memory := config.limits.memory if config.limits.memory != 0 else s.limits.memory
	if memory < MEMORY_MIN || memory > MEMORY_MAX {
		return nil, refused("memory limit out of range (256 KiB to 1 GiB)")
	}
	if u64(s.top) > u64(memory) {
		return nil, refused(
			"the snapshot's heap is %d bytes; this VM's memory limit is %d",
			s.top,
			memory,
		)
	}

	vm := new(VM, allocator)
	vm.allocator = allocator
	vm.limits = s.limits
	vm.limits.memory = memory
	vm.seed = s.seed
	vm.natives = make([dynamic]Native_Spec, allocator)
	vm.output = make([dynamic]u8, allocator)
	vm.fresh = make([dynamic]Ref, allocator)
	vm.handle_kinds = make([dynamic]string, allocator)
	vm.err.msg = strings.builder_make(allocator)
	vm.err.hint = strings.builder_make(allocator)
	vm.verify = config.verify
	if !heap_init(vm) {
		vm_destroy(vm)
		return nil, refused("could not reserve the script heap")
	}
	if !heap_commit(vm, s.top) {
		vm_destroy(vm)
		return nil, refused("could not commit the script heap")
	}
	copy(vm.mem[:s.top], bytes[r.at:])
	vm.top = s.top
	vm.in_use = s.in_use
	vm.free_small = s.free_small
	vm.free_large = s.free_large
	vm.gc_params = s.gc_params
	vm.gc_stress = flags & SNAPSHOT_FLAG_GC_STRESS != 0
	vm.gc = s.gc
	vm.gc.phase = Gc_Phase(phase)
	vm.globals = s.globals
	vm.registry = s.registry
	vm.string_meta = s.string_meta
	vm.handle_metas = s.handle_metas
	vm.prelude_table = s.prelude_table
	vm.main_thread = s.main_thread
	vm.current = s.current
	vm.call_through = s.call_through
	vm.mm_names = s.mm_names
	vm.intern = s.intern
	vm.intern_mask = s.intern_mask
	vm.intern_count = s.intern_count
	vm.next_id = s.next_id
	vm.state = VM_State(state)
	vm.meter = s.meter
	vm.budget = s.budget
	vm.budget_is_last = budget_is_last != 0
	vm.run_used = s.run_used
	vm.depth = s.depth
	vm.fault = Limit_Kind(fault)
	vm.yielding = yielding != 0
	vm.pending = pending != 0
	vm.yield_from = s.yield_from
	vm.output_dropped = int(dropped)
	append(&vm.output, ..output)

	// The natives, mapped from the snapshot's names to this VM's ids.
	natives_init(vm, config)
	remap := make([]u32, n_natives, context.temp_allocator)
	for name, i in native_names {
		// (in the same order in the same build: the name at i first)
		id := i if i < len(vm.natives) && vm.natives[i].name == name else find_native(vm, name)
		if id < 0 {
			vm_destroy(vm)
			return nil, refused("snapshot needs native '%s', which this VM does not have", name)
		}
		remap[i] = u32(id)
	}
	// Handle kinds keep their numbers (handle values in the heap carry them).
	for k in config.handle_kinds {register_handle_kind(vm, k)}
	for name, i in kind_names {
		have := -1
		for k, j in vm.handle_kinds {
			if k == name {have = j}
		}
		if have < 0 {
			vm_destroy(vm)
			return nil, refused(
				"snapshot needs handle kind '%s', which this VM does not have",
				name,
			)
		}
		if have != i {
			vm_destroy(vm)
			return nil, refused(
				"snapshot's handle kind '%s' is number %d; this VM's is %d",
				name,
				i + 1,
				have + 1,
			)
		}
	}

	if problem := restore_validate(vm, remap); problem != "" {
		vm_destroy(vm)
		return nil, refused("the snapshot is damaged: %s", problem)
	}
	return vm, {}
}

// restore_validate checks a restored heap before anything runs, and maps native ids.
@(private = "file")
restore_validate :: proc(vm: ^VM, remap: []u32) -> string {
	// Every header first, so the native closures can be found and remapped.
	at := u32(HEAP_START)
	for at < vm.top {
		h := (^Header)(&vm.mem[at])
		if h.size < 16 || h.size % 16 != 0 || u64(at) + u64(h.size) > u64(vm.top) {
			return fmt.tprintf("the block at %d has a bad size", at)
		}
		if h.kind > max(Obj_Kind) {return fmt.tprintf("the block at %d has a bad kind", at)}
		if h.kind == .Native_Closure {
			if h.size < NATIVE_UPVALS {return fmt.tprintf("the native at %d is too small", at)}
			nc := (^Native_Closure)(h)
			if int(nc.native) >= len(remap) {
				return fmt.tprintf("the native at %d has no name", at)
			}
			nc.native = remap[nc.native]
		}
		at += h.size
	}
	if ok, problem := roots_check(vm); !ok {return problem}
	if ok, problem := heap_check(vm); !ok {return problem}
	if ok, problem := structure_check(vm); !ok {return problem}
	at = HEAP_START
	for at < vm.top {
		h := (^Header)(&vm.mem[at])
		if h.kind == .Proto && !(vm.gc.phase == .Sweep && h.mark == vm.gc.white ~ 1) {
			if ok, problem := verify_proto(vm, Ref(at)); !ok {return problem}
		}
		at += h.size
	}
	return ""
}

// is_object: r is the start of a live block of one of kinds (the headers are known sane).
@(private = "file")
is_object :: proc(vm: ^VM, starts: []u8, r: Ref, kinds: bit_set[Obj_Kind]) -> bool {
	if r == 0 || u32(r) % 16 != 0 || u32(r) >= vm.top {return false}
	idx := u32(r) >> 4
	if starts[idx / 8] & (1 << (idx % 8)) == 0 {return false}
	return obj_kind(vm, r) in kinds
}

@(private = "file")
block_starts :: proc(vm: ^VM) -> []u8 {
	starts := make([]u8, (vm.top >> 4) / 8 + 1, context.temp_allocator)
	for at := u32(HEAP_START); at < vm.top; at += (^Header)(&vm.mem[at]).size {
		idx := at >> 4
		starts[idx / 8] |= 1 << (idx % 8)
	}
	return starts
}

// roots_check: the VM's roots and the intern index are objects of their kinds (heap_check
// reads through them).
@(private = "file")
roots_check :: proc(vm: ^VM) -> (bool, string) {
	starts := block_starts(vm)
	for r in ([?]Ref{vm.globals, vm.registry, vm.string_meta, vm.handle_metas, vm.prelude_table}) {
		if !is_object(vm, starts, r, {.Table}) {return false, "a root table is not a table"}
	}
	if !is_object(vm, starts, vm.main_thread, {.Thread}) ||
	   !is_object(vm, starts, vm.current, {.Thread}) {
		return false, "a root thread is not a thread"
	}
	for r in vm.mm_names {
		if !is_object(vm, starts, r, {.String}) {return false, "a metamethod name is not a string"}
	}
	if vm.call_through.tag != .Function ||
	   !is_object(vm, starts, as_ref(vm.call_through), {.Closure, .Native_Closure}) {
		return false, "the prelude's call_through is not a function"
	}
	n := u64(vm.intern_mask) + 1
	if !is_object(vm, starts, vm.intern, {.Bytes}) ||
	   n < 4 ||
	   n & (n - 1) != 0 ||
	   BUF_DATA + n * 4 > u64((^Header)(&vm.mem[vm.intern]).size) ||
	   u64(vm.intern_count) >= n {
		return false, "the intern index is not a buffer of its size"
	}
	if vm.gc.phase == .Sweep && (vm.gc.sweep < HEAP_START || vm.gc.sweep > vm.top) {
		return false, "the sweep's cursor is outside the heap"
	}
	if vm.gc.sweep_run != 0 &&
	   (vm.gc.phase != .Sweep || vm.gc.sweep_run >= vm.gc.sweep || vm.gc.sweep_run % 16 != 0) {
		return false, "the sweep's free run is outside the swept part"
	}
	if vm.gc.phase != .Propagate && (vm.gc.gray != 0 || vm.gc.grayagain != 0) {
		return false, "gray lists outside marking"
	}
	return true, ""
}

// structure_check: what heap_check does not look at and the VM relies on: table indexes
// with room, lists without cycles, closures matching their protos, frames inside their
// stacks, threads in states they can be in.
structure_check :: proc(vm: ^VM) -> (bool, string) {
	starts := block_starts(vm)
	blocks := int(vm.top / 16)
	dead: u8 = 255
	if vm.gc.phase == .Sweep {dead = vm.gc.white ~ 1}
	// The gray lists: gray objects of the kinds with a gclist, no cycle.
	seen := make([]u8, len(starts), context.temp_allocator)
	for head in ([?]Ref{vm.gc.gray, vm.gc.grayagain}) {
		n := 0
		for r := head; r != 0; r = gclist_of(vm, r)^ {
			if !is_object(vm, starts, r, {.Table, .Closure, .Native_Closure, .Proto, .Thread}) {
				return false, "a gray list holds a wrong block"
			}
			idx := u32(r) >> 4
			if seen[idx / 8] & (1 << (idx % 8)) != 0 {return false, "a gray list has a cycle"}
			seen[idx / 8] |= 1 << (idx % 8)
			if (^Header)(&vm.mem[r]).mark !=
			   GRAY {return false, "a gray list holds a block that is not gray"}
			n += 1
			if n > blocks {return false, "a gray list has a cycle"}
		}
	}
	at := u32(HEAP_START)
	for at < vm.top {
		h := (^Header)(&vm.mem[at])
		r := Ref(at)
		at += h.size
		if h.kind == .Free {
			// An allocation hands a free block out as it is, so it must be zeroed.
			for b in vm.mem[u32(r) + size_of(Free_Block):at] {
				if b != 0 {return false, fmt.tprintf("the free block at %d is not zeroed", r)}
			}
			continue
		}
		if h.mark == dead {continue}
		#partial switch h.kind {
		case .Table:
			t := (^Table)(h)
			if (t.arr == 0) != (t.arr_cap == 0) || (t.entries == 0) != (t.entries_cap == 0) {
				return false, fmt.tprintf("the table at %d has a buffer of no size", r)
			}
			if t.entries_cap == 0 {
				if t.index != 0 || t.live != 0 || t.entries_len != 0 {
					return false, fmt.tprintf("the table at %d has an index without entries", r)
				}
				continue
			}
			slots := u64(t.index_mask) + 1
			if t.index == 0 || slots & (slots - 1) != 0 || slots < 2 * u64(t.entries_cap) {
				return false, fmt.tprintf("the table at %d has an index of a bad size", r)
			}
			used: u32
			for e in bytes_of(vm, t.index, u32, t.index_mask + 1) {
				if e == 0 {continue}
				if e > t.entries_len {
					return false, fmt.tprintf("the table at %d has an index past its entries", r)
				}
				used += 1
			}
			if used != t.entries_len {
				return false, fmt.tprintf(
					"the table at %d indexes %d of %d entries",
					r,
					used,
					t.entries_len,
				)
			}
			live: u32
			entries := values_of(vm, t.entries, t.entries_len * 2)
			for i in 0 ..< t.entries_len {
				k := entries[i * 2]
				if k.tag == .Nil || (k.tag == .Float && as_float(k) != as_float(k)) {
					return false, fmt.tprintf("the table at %d has a nil or NaN key", r)
				}
				if entries[i * 2 + 1].tag != .Nil {live += 1}
			}
			if live !=
			   t.live {return false, fmt.tprintf("the table at %d miscounts its entries", r)}
		case .Closure:
			c := (^Closure)(h)
			if u32(c.nup) != obj(vm, c.proto, Proto).upvals_len {
				return false, fmt.tprintf(
					"the closure at %d has %d upvalues; its function %d",
					r,
					c.nup,
					obj(vm, c.proto, Proto).upvals_len,
				)
			}
			for u in closure_upvals(vm, r) {
				if u == 0 {return false, fmt.tprintf("the closure at %d has an empty upvalue", r)}
			}
		case .Native_Closure:
			c := (^Native_Closure)(h)
			if c.intrinsic > max(Intrinsic) {
				return false, fmt.tprintf("the native at %d has a bad intrinsic", r)
			}
			if c.intrinsic == .Wrap && (c.nup < 1 || native_upvals(vm, r)[0].tag != .Thread) {
				return false, fmt.tprintf("the wrapped coroutine at %d has no thread", r)
			}
		case .Upvalue:
			uv := (^Upvalue)(h)
			if transmute(u8)uv.open >
			   1 {return false, fmt.tprintf("the upvalue at %d has a bad flag", r)}
		case .Thread:
			if ok, problem := thread_check(vm, r, blocks); !ok {return false, problem}
		}
	}
	return true, ""
}

@(private = "file")
thread_check :: proc(vm: ^VM, r: Ref, blocks: int) -> (bool, string) {
	th := obj(vm, r, Thread)
	if th.status > max(Thread_Status) || th.wait_cont > max(Cont) {
		return false, fmt.tprintf("the thread at %d has a bad state", r)
	}
	if transmute(u8)th.wait_flags >
	   3 {return false, fmt.tprintf("the thread at %d has bad flags", r)}
	if th.stack == 0 || th.frames == 0 || th.stack_cap < EXTRA_STACK {
		return false, fmt.tprintf("the thread at %d has no stack", r)
	}
	if th.wait_slot >= th.stack_cap || th.wait_nres < -1 {
		return false, fmt.tprintf("the thread at %d waits outside its stack", r)
	}
	if th.status == .Dead && th.frame_count != 0 {
		return false, fmt.tprintf("the dead thread at %d has frames", r)
	}
	// Open upvalues: this thread's, open, slots inside the stack, highest first, no cycle.
	n := 0
	last := max(u32)
	for u := th.open_upvals; u != 0; u = obj(vm, u, Upvalue).next_open {
		uv := obj(vm, u, Upvalue)
		if !uv.open || uv.thread != r || uv.slot >= th.stack_cap || uv.slot >= last {
			return false, fmt.tprintf("the thread at %d has a bad open upvalue", r)
		}
		last = uv.slot
		n += 1
		if n > blocks {return false, fmt.tprintf("the thread at %d has a cycle of upvalues", r)}
	}
	stack := thread_stack(vm, th)
	frames := thread_frames(vm, th)
	for f, i in frames[:th.frame_count] {
		if f.cont > max(Cont) || transmute(u8)f.flags > 7 || f.nresults < -1 {
			return false, fmt.tprintf("frame %d of the thread at %d has a bad state", i, r)
		}
		if f.func >= th.stack_cap ||
		   f.base != f.func + 1 ||
		   f.top > th.stack_cap ||
		   f.top < f.base {
			return false, fmt.tprintf("frame %d of the thread at %d is outside its stack", i, r)
		}
		if f.nresults > 0 && u64(f.func) + u64(f.nresults) > u64(th.stack_cap) {
			return false, fmt.tprintf(
				"frame %d of the thread at %d returns outside its stack",
				i,
				r,
			)
		}
		fn := stack[f.func]
		if .Native in f.flags {
			if fn.tag != .Function || obj_kind(vm, as_ref(fn)) != .Native_Closure {
				return false, fmt.tprintf("frame %d of the thread at %d is not a native's", i, r)
			}
			continue
		}
		if fn.tag != .Function || obj_kind(vm, as_ref(fn)) != .Closure {
			return false, fmt.tprintf("frame %d of the thread at %d is not a function's", i, r)
		}
		p := obj(vm, obj(vm, as_ref(fn), Closure).proto, Proto)
		if f.top != f.base + u32(p.max_stack) ||
		   f.pc > p.code_len ||
		   f.top + EXTRA_STACK > th.stack_cap {
			return false, fmt.tprintf(
				"frame %d of the thread at %d does not fit its function",
				i,
				r,
			)
		}
		if p.is_vararg != 0 && u64(f.func) < u64(f.nvarargs) + u64(p.num_params) + 1 {
			return false, fmt.tprintf(
				"frame %d of the thread at %d has varargs below the stack",
				i,
				r,
			)
		}
		if p.is_vararg == 0 && f.nvarargs != 0 {
			return false, fmt.tprintf("frame %d of the thread at %d has varargs it cannot", i, r)
		}
		// A continuation finishes the instruction of the frame below.
		#partial switch f.cont {
		case .Store, .Compare, .Discard, .Concat:
			if i ==
			   0 {return false, fmt.tprintf("frame %d of the thread at %d continues nothing", i, r)}
			below := frames[i - 1]
			room := below.top - below.base
			if f.cont == .Store && f.cont_arg >= room {
				return false, fmt.tprintf("frame %d of the thread at %d stores outside", i, r)
			}
			if f.cont == .Concat {
				a, cn := f.cont_arg >> 16, f.cont_arg & 0xffff
				if cn < 2 || a + cn > room {
					return false, fmt.tprintf(
						"frame %d of the thread at %d concatenates outside",
						i,
						r,
					)
				}
			}
		}
	}
	if th.top > th.stack_cap {return false, fmt.tprintf("the thread at %d is past its stack", r)}
	return true, ""
}
