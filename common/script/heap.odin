package script

import "core:math/bits"
import "core:mem"
import "core:mem/virtual"

// The heap: one region of limits.memory bytes, reserved at once and committed in 64 KiB
// steps. Allocation is deterministic: the same operations give the same offsets on
// every OS. Blocks are 16-byte aligned; offset 0..15 is reserved so no object is at Ref 0.

HEAP_START :: 16
COMMIT_STEP :: 64 * 1024
SMALL_MAX :: 512

// Free_Block: a free block's header and its free-list link.
Free_Block :: struct {
	using hdr: Header,
	next:      Ref,
}

heap_init :: proc(vm: ^VM) -> bool {
	data, err := virtual.reserve(uint(vm.limits.memory))
	if err != nil {return false}
	vm.mem = data
	vm.top = HEAP_START
	return heap_commit(vm, HEAP_START)
}

heap_release :: proc(vm: ^VM) {
	if vm.mem != nil {virtual.release(raw_data(vm.mem), uint(len(vm.mem)))}
	vm.mem = nil
}

heap_commit :: proc(vm: ^VM, need: u32) -> bool {
	if need <= vm.committed {return true}
	target := (u64(need) + COMMIT_STEP - 1) / COMMIT_STEP * COMMIT_STEP
	target = min(target, u64(len(vm.mem)))
	if virtual.commit(&vm.mem[vm.committed], uint(target - u64(vm.committed))) != nil {
		return false
	}
	vm.committed = u32(target)
	return true
}

large_class :: #force_inline proc "contextless" (size: u32) -> int {
	return int(31 - bits.count_leading_zeros(size))
}

// heap_alloc gives a zeroed block of kind holding size bytes (header included). It
// charges the meter one unit per 64 bytes. When there is no room, inside a run, the
// collector finishes its cycle and runs a full one, and the allocation is tried once more;
// then it sets the memory fault and returns 0.
heap_alloc :: proc(vm: ^VM, kind: Obj_Kind, size: int) -> Ref {
	if size <= 0 || u64(size) > u64(len(vm.mem)) {
		vm.fault = .Memory
		vm.pending = true
		return 0
	}
	need := u32((size + 15) &~ 15)
	vm.meter -= i64((need + 63) / 64)
	r := heap_take(vm, need)
	if r == 0 && vm.state == .Running && !vm.gc.collecting {
		gc_emergency(vm)
		r = heap_take(vm, need)
	}
	if r == 0 {
		vm.fault = .Memory
		vm.pending = true
		return 0
	}
	h := (^Header)(&vm.mem[r])
	h^ = Header {
		size = h.size,
		kind = kind,
		mark = vm.gc.white,
	}
	sz := u64(h.size)
	vm.in_use += sz
	vm.gc.peak = max(vm.gc.peak, vm.in_use)
	vm.gc.allocated += i64(sz)
	vm.gc.credit -= i64(sz)
	if vm.state == .Running {append(&vm.fresh, r)}
	vm.pending = true
	return r
}

// heap_take finds room for need bytes: a free list's block, or the end of the heap. The
// block's header has its size; 0 when there is no room.
@(private = "file")
heap_take :: proc(vm: ^VM, need: u32) -> Ref {
	r: Ref
	if need <= SMALL_MAX {
		list := &vm.free_small[need / 16 - 1]
		if list^ != 0 {
			r = list^
			fb := (^Free_Block)(&vm.mem[r])
			list^ = fb.next
			fb.next = 0
			return r
		}
	}
	// A large free block, split (the sweep merges free neighbours, so small blocks come
	// from large ones too).
	{
		for c in large_class(max(need, SMALL_MAX + 16)) ..< len(vm.free_large) {
			prev: ^Ref = &vm.free_large[c]
			for b := prev^; b != 0; {
				fb := (^Free_Block)(&vm.mem[b])
				if fb.size >= need {
					prev^ = fb.next
					fb.next = 0
					rest := fb.size - need
					if rest >= 16 {
						fb.size = need
						rest_ref := Ref(u32(b) + need)
						rb := (^Free_Block)(&vm.mem[rest_ref])
						rb.size = rest
						rb.kind = .Free
						free_push(vm, rest_ref)
					}
					return b
				}
				prev = &fb.next
				b = fb.next
			}
		}
	}
	if u64(vm.top) + u64(need) > u64(len(vm.mem)) || !heap_commit(vm, vm.top + need) {
		return 0
	}
	r = Ref(vm.top)
	vm.top += need
	(^Header)(&vm.mem[r]).size = need
	return r
}

free_push :: proc(vm: ^VM, r: Ref) {
	fb := (^Free_Block)(&vm.mem[r])
	if fb.size <= SMALL_MAX {
		list := &vm.free_small[fb.size / 16 - 1]
		fb.next = list^
		list^ = r
	} else {
		list := &vm.free_large[large_class(fb.size)]
		fb.next = list^
		list^ = r
	}
}

// heap_free returns a block to its free list, zeroed. Used directly only for buffers
// their owner replaces; the sweep frees everything else.
heap_free :: proc(vm: ^VM, r: Ref) {
	if r == 0 {return}
	h := (^Header)(&vm.mem[r])
	size := h.size
	vm.in_use -= u64(size)
	mem.zero(&vm.mem[u32(r)], int(size))
	h.size = size
	h.kind = .Free
	// A block the sweep has still to pass joins its free run there.
	if vm.gc.phase == .Sweep && u32(r) >= vm.gc.sweep {return}
	free_push(vm, r)
}

// alloc_values: a Values buffer of n values, all nil.
alloc_values :: proc(vm: ^VM, n: u32) -> Ref {
	return heap_alloc(vm, .Values, BUF_DATA + int(max(n, 1)) * size_of(Value))
}

// alloc_bytes: a Bytes buffer of n bytes.
alloc_bytes :: proc(vm: ^VM, n: int) -> Ref {
	return heap_alloc(vm, .Bytes, BUF_DATA + max(n, 1))
}
