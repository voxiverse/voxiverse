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

@(private = "file")
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

@(private = "file")
large_class :: #force_inline proc "contextless" (size: u32) -> int {
	return int(31 - bits.count_leading_zeros(size))
}

// heap_alloc gives a zeroed block of kind holding size bytes (header included). It
// charges the meter one unit per 64 bytes; when there is no room it sets the memory
// fault and returns 0.
heap_alloc :: proc(vm: ^VM, kind: Obj_Kind, size: int) -> Ref {
	if size <= 0 || u64(size) > u64(len(vm.mem)) {
		vm.fault = .Memory
		return 0
	}
	need := u32((size + 15) &~ 15)
	vm.meter -= i64((need + 63) / 64)
	r: Ref
	if need <= SMALL_MAX {
		list := &vm.free_small[need / 16 - 1]
		if list^ != 0 {
			r = list^
			list^ = (^Free_Block)(&vm.mem[r]).next
		}
	} else {
		search: for c in large_class(need) ..< len(vm.free_large) {
			prev: ^Ref = &vm.free_large[c]
			for b := prev^; b != 0; {
				fb := (^Free_Block)(&vm.mem[b])
				if fb.size >= need {
					prev^ = fb.next
					r = b
					rest := fb.size - need
					if rest >= 16 {
						fb.size = need
						rest_ref := Ref(u32(b) + need)
						rb := (^Free_Block)(&vm.mem[rest_ref])
						rb.size = rest
						rb.kind = .Free
						free_push(vm, rest_ref)
					}
					break search
				}
				prev = &fb.next
				b = fb.next
			}
		}
	}
	if r == 0 {
		if u64(vm.top) + u64(need) > u64(len(vm.mem)) || !heap_commit(vm, vm.top + need) {
			vm.fault = .Memory
			return 0
		}
		r = Ref(vm.top)
		vm.top += need
		h := (^Header)(&vm.mem[r])
		h^ = Header {
			size = need,
			kind = kind,
		}
	} else {
		h := (^Free_Block)(&vm.mem[r])
		sz := h.size
		h.next = 0
		h.hdr = Header {
			size = sz,
			kind = kind,
		}
	}
	vm.in_use += u64((^Header)(&vm.mem[r]).size)
	return r
}

@(private = "file")
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
// their owner replaces; the sweep (M51b) frees everything else.
heap_free :: proc(vm: ^VM, r: Ref) {
	if r == 0 {return}
	h := (^Header)(&vm.mem[r])
	size := h.size
	vm.in_use -= u64(size)
	mem.zero(&vm.mem[u32(r)], int(size))
	h.size = size
	h.kind = .Free
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

// heap_check walks the heap: headers sane, every block inside top, free lists made of
// free blocks. M51b adds the references and the collector's colours.
heap_check :: proc(vm: ^VM) -> (ok: bool, problem: string) {
	at := u32(HEAP_START)
	in_use: u64
	for at < vm.top {
		h := (^Header)(&vm.mem[at])
		if h.size < 16 || h.size % 16 != 0 || at + h.size > vm.top {
			return false, "a block header has a bad size"
		}
		if h.kind > .Bytes {return false, "a block header has a bad kind"}
		if h.kind != .Free {in_use += u64(h.size)}
		at += h.size
	}
	if at != vm.top {return false, "the blocks do not end at top"}
	if in_use != vm.in_use {return false, "bytes in use disagree with the blocks"}
	for head, i in vm.free_small {
		for b := head; b != 0; b = (^Free_Block)(&vm.mem[b]).next {
			fb := (^Free_Block)(&vm.mem[b])
			if u32(b) >= vm.top || fb.kind != .Free || fb.size != u32(i + 1) * 16 {
				return false, "a small free list holds a wrong block"
			}
		}
	}
	for head in vm.free_large {
		for b := head; b != 0; b = (^Free_Block)(&vm.mem[b]).next {
			fb := (^Free_Block)(&vm.mem[b])
			if u32(b) >= vm.top || fb.kind != .Free || fb.size <= SMALL_MAX {
				return false, "a large free list holds a wrong block"
			}
		}
	}
	return true, ""
}
