package script

import "core:mem"

// Strings are all interned: equal strings are the same Ref. The intern index is a Bytes
// buffer of u32 slots (a string's Ref, 0 empty), a power of two, linear probing.

FNV_OFFSET :: 0xcbf2_9ce4_8422_2325
FNV_PRIME :: 0x0000_0100_0000_01b3

splitmix_finish :: #force_inline proc "contextless" (x: u64) -> u64 {
	z := x
	z = (z ~ (z >> 30)) * 0xbf58_476d_1ce4_e5b9
	z = (z ~ (z >> 27)) * 0x94d0_49bb_1331_11eb
	return z ~ (z >> 31)
}

string_hash :: proc "contextless" (seed: u64, s: string) -> u32 {
	h := u64(FNV_OFFSET) ~ seed
	for i in 0 ..< len(s) {
		h ~= u64(s[i])
		h *= FNV_PRIME
	}
	return u32(splitmix_finish(h))
}

// intern returns the string's Ref, making it if it is new; 0 on the memory fault.
intern :: proc(vm: ^VM, s: string) -> Ref {
	h := string_hash(vm.seed, s)
	slots := bytes_of(vm, vm.intern, u32, vm.intern_mask + 1)
	i := h & vm.intern_mask
	for {
		r := Ref(slots[i])
		if r == 0 {break}
		str := (^String)(&vm.mem[r])
		if str.hash == h && int(str.len) == len(s) && string_bytes(vm, r) == s {return r}
		i = (i + 1) & vm.intern_mask
	}
	r := heap_alloc(vm, .String, STRING_DATA + len(s) + 1)
	if r == 0 {return 0}
	str := (^String)(&vm.mem[r])
	str.len = u32(len(s))
	str.hash = h
	if len(s) > 0 {mem.copy(&vm.mem[u32(r) + STRING_DATA], raw_data(s), len(s))}
	// The index may have moved: no, it is a heap block that stays; look up the slot again
	// only if it grows below.
	slots = bytes_of(vm, vm.intern, u32, vm.intern_mask + 1)
	slots[i] = u32(r)
	vm.intern_count += 1
	if vm.intern_count * 4 >= (vm.intern_mask + 1) * 3 {
		if !intern_grow(vm) {return 0}
	}
	return r
}

intern_init :: proc(vm: ^VM, slots: u32) -> bool {
	vm.intern = alloc_bytes(vm, int(slots) * 4)
	vm.intern_mask = slots - 1
	return vm.intern != 0
}

@(private = "file")
intern_grow :: proc(vm: ^VM) -> bool {
	old := vm.intern
	old_n := vm.intern_mask + 1
	n := old_n * 2
	fresh := alloc_bytes(vm, int(n) * 4)
	if fresh == 0 {return false}
	old_slots := bytes_of(vm, old, u32, old_n)
	slots := bytes_of(vm, fresh, u32, n)
	mask := n - 1
	for r in old_slots {
		if r == 0 {continue}
		i := (^String)(&vm.mem[r]).hash & mask
		for slots[i] != 0 {i = (i + 1) & mask}
		slots[i] = r
	}
	vm.intern = fresh
	vm.intern_mask = mask
	heap_free(vm, old)
	return true
}

// new_string makes (or finds) a string value; NIL on the memory fault.
new_string :: proc(vm: ^VM, s: string) -> Value {
	r := intern(vm, s)
	if r == 0 {return NIL}
	return ref_value(.String, r)
}
