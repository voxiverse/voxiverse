package script

import "core:mem"

// Tables: an array part (keys 1..arr_len) and a hash part whose entries keep insertion
// order. A key set to nil stays dead in place (so next can go on past it) and revives in
// place when set again; full entries are compacted when a quarter are dead, else doubled.

Set_Result :: enum u8 {
	Ok,
	Memory,
	Nil_Key,
	Nan_Key,
}

table_new :: proc(vm: ^VM, narr: u32 = 0, nhash: u32 = 0) -> Ref {
	r := heap_alloc(vm, .Table, size_of(Table))
	if r == 0 {return 0}
	if narr > 0 {
		arr := alloc_values(vm, narr)
		if arr == 0 {return 0}
		t := obj(vm, r, Table)
		t.arr = arr
		t.arr_cap = narr
	}
	if nhash > 0 {
		if !hash_resize(vm, r, nhash) {return 0}
	}
	return r
}

// normalize_key: a float key with an integer value is that integer.
normalize_key :: #force_inline proc "contextless" (key: Value) -> Value {
	if key.tag == .Float {
		if i, ok := float_to_int_exact(as_float(key)); ok {return int_value(i)}
	}
	return key
}

key_hash :: #force_inline proc "contextless" (key: Value, vm: ^VM) -> u32 {
	if key.tag == .String {return (^String)(&vm.mem[as_ref(key)]).hash}
	return u32(splitmix_finish(key.bits ~ (u64(key.tag) << 56) ~ (u64(key.kind) << 40)))
}

@(private = "file")
key_same :: #force_inline proc "contextless" (a, b: Value) -> bool {
	return a.tag == b.tag && a.bits == b.bits && a.kind == b.kind
}

// hash_find: the entry number of key in the hash part, or -1.
hash_find :: proc(vm: ^VM, t: ^Table, key: Value) -> int {
	if t.index == 0 {return -1}
	slots := bytes_of(vm, t.index, u32, t.index_mask + 1)
	entries := values_of(vm, t.entries, t.entries_cap * 2)
	i := key_hash(key, vm) & t.index_mask
	first := true
	for {
		if !first {vm.meter -= 1}
		first = false
		e := slots[i]
		if e == 0 {return -1}
		if key_same(entries[(e - 1) * 2], key) {return int(e - 1)}
		i = (i + 1) & t.index_mask
	}
}

@(private = "file")
hash_insert_index :: proc(vm: ^VM, t: ^Table, key: Value, entry: u32) {
	slots := bytes_of(vm, t.index, u32, t.index_mask + 1)
	i := key_hash(key, vm) & t.index_mask
	for slots[i] != 0 {i = (i + 1) & t.index_mask}
	slots[i] = entry + 1
}

// hash_resize makes room for cap entries, dropping dead ones (order kept).
@(private = "file")
hash_resize :: proc(vm: ^VM, tr: Ref, cap: u32) -> bool {
	nslots := u32(4)
	for nslots < cap * 2 {nslots *= 2}
	entries := alloc_values(vm, cap * 2)
	if entries == 0 {return false}
	index := alloc_bytes(vm, int(nslots) * 4)
	if index == 0 {return false}
	t := obj(vm, tr, Table)
	n: u32
	if t.entries != 0 {
		old := values_of(vm, t.entries, t.entries_len * 2)
		fresh := values_of(vm, entries, cap * 2)
		for i in 0 ..< t.entries_len {
			if old[i * 2 + 1].tag == .Nil {continue}
			fresh[n * 2] = old[i * 2]
			fresh[n * 2 + 1] = old[i * 2 + 1]
			n += 1
		}
		heap_free(vm, t.entries)
		heap_free(vm, t.index)
	}
	t.entries = entries
	t.entries_cap = cap
	t.entries_len = n
	t.live = n
	t.index = index
	t.index_mask = nslots - 1
	fresh := values_of(vm, entries, cap * 2)
	for i in 0 ..< n {hash_insert_index(vm, t, fresh[i * 2], i)}
	return true
}

table_get_int :: proc(vm: ^VM, tr: Ref, k: i64) -> Value {
	t := obj(vm, tr, Table)
	if k >= 1 && k <= i64(t.arr_len) {return values_of(vm, t.arr, t.arr_cap)[k - 1]}
	e := hash_find(vm, t, int_value(k))
	if e < 0 {return NIL}
	return values_of(vm, t.entries, t.entries_cap * 2)[e * 2 + 1]
}

table_get_str :: proc(vm: ^VM, tr: Ref, key: Value) -> Value {
	t := obj(vm, tr, Table)
	e := hash_find(vm, t, key)
	if e < 0 {return NIL}
	return values_of(vm, t.entries, t.entries_cap * 2)[e * 2 + 1]
}

table_get :: proc(vm: ^VM, tr: Ref, key_in: Value) -> Value {
	key := normalize_key(key_in)
	#partial switch key.tag {
	case .Nil:
		return NIL
	case .Int:
		return table_get_int(vm, tr, as_int(key))
	case .Float:
		if as_float(key) != as_float(key) {return NIL}
	}
	return table_get_str(vm, tr, key)
}

// table_set stores without metamethods. A nil value deletes.
table_set :: proc(vm: ^VM, tr: Ref, key_in: Value, val: Value) -> Set_Result {
	key := normalize_key(key_in)
	#partial switch key.tag {
	case .Nil:
		return .Nil_Key
	case .Float:
		if as_float(key) != as_float(key) {return .Nan_Key}
	case .Int:
		return table_set_int(vm, tr, as_int(key), val)
	}
	return hash_set(vm, tr, key, val)
}

table_set_int :: proc(vm: ^VM, tr: Ref, k: i64, val: Value) -> Set_Result {
	t := obj(vm, tr, Table)
	barrier_back(vm, tr)
	if k >= 1 && k <= i64(t.arr_len) {
		arr := values_of(vm, t.arr, t.arr_cap)
		arr[k - 1] = val
		if val.tag == .Nil && k == i64(t.arr_len) {
			n := t.arr_len
			for n > 0 && arr[n - 1].tag == .Nil {n -= 1}
			t.arr_len = n
		}
		return .Ok
	}
	if k == i64(t.arr_len) + 1 && val.tag != .Nil {
		if !array_push(vm, tr, val) {return .Memory}
		// Move the following integer keys out of the hash part.
		for {
			t = obj(vm, tr, Table)
			if t.live == 0 {break}
			next := int_value(i64(t.arr_len) + 1)
			e := hash_find(vm, t, next)
			if e < 0 {break}
			entries := values_of(vm, t.entries, t.entries_cap * 2)
			v := entries[e * 2 + 1]
			if v.tag == .Nil {break}
			entries[e * 2 + 1] = NIL
			t.live -= 1
			if !array_push(vm, tr, v) {return .Memory}
		}
		return .Ok
	}
	return hash_set(vm, tr, int_value(k), val)
}

@(private = "file")
array_push :: proc(vm: ^VM, tr: Ref, val: Value) -> bool {
	t := obj(vm, tr, Table)
	if t.arr_len == t.arr_cap {
		cap := max(4, t.arr_cap * 2)
		arr := alloc_values(vm, cap)
		if arr == 0 {return false}
		t = obj(vm, tr, Table)
		if t.arr != 0 {
			mem.copy(
				&vm.mem[u32(arr) + BUF_DATA],
				&vm.mem[u32(t.arr) + BUF_DATA],
				int(t.arr_len) * size_of(Value),
			)
			heap_free(vm, t.arr)
		}
		t.arr = arr
		t.arr_cap = cap
	}
	values_of(vm, t.arr, t.arr_cap)[t.arr_len] = val
	t.arr_len += 1
	return true
}

@(private = "file")
hash_set :: proc(vm: ^VM, tr: Ref, key: Value, val: Value) -> Set_Result {
	t := obj(vm, tr, Table)
	barrier_back(vm, tr)
	e := hash_find(vm, t, key)
	if e >= 0 {
		slot := &values_of(vm, t.entries, t.entries_cap * 2)[e * 2 + 1]
		was_nil := slot.tag == .Nil
		slot^ = val
		if was_nil && val.tag != .Nil {
			t.live += 1
			t.mm_absent = 0
		} else if !was_nil && val.tag == .Nil {
			t.live -= 1
		}
		return .Ok
	}
	if val.tag == .Nil {return .Ok}
	if t.entries_len == t.entries_cap {
		dead := t.entries_len - t.live
		cap := t.entries_cap
		if cap == 0 {
			cap = 4
		} else if dead * 4 < cap {
			cap *= 2
		}
		if !hash_resize(vm, tr, cap) {return .Memory}
		t = obj(vm, tr, Table)
	}
	entries := values_of(vm, t.entries, t.entries_cap * 2)
	n := t.entries_len
	entries[n * 2] = key
	entries[n * 2 + 1] = val
	t.entries_len += 1
	t.live += 1
	t.mm_absent = 0
	hash_insert_index(vm, t, key, n)
	return .Ok
}

table_len :: #force_inline proc "contextless" (vm: ^VM, tr: Ref) -> i64 {
	return i64((^Table)(&vm.mem[tr]).arr_len)
}

// table_next: the entry after key (nil: the first); found is false for a key that is
// not in the table ("invalid key to 'next'"), done when there is none after it.
table_next :: proc(vm: ^VM, tr: Ref, key_in: Value) -> (k, v: Value, found: bool) {
	t := obj(vm, tr, Table)
	key := normalize_key(key_in)
	arr_from: u32 = 0
	hash_from: u32 = 0
	switch {
	case key.tag == .Nil:
	case key.tag == .Int && as_int(key) >= 1 && as_int(key) <= i64(t.arr_len):
		arr_from = u32(as_int(key))
	case:
		e := hash_find(vm, t, key)
		if e >= 0 {
			arr_from = t.arr_len
			hash_from = u32(e + 1)
		} else if key.tag == .Int && as_int(key) >= 1 && as_int(key) <= i64(t.arr_cap) {
			// A key the array part held when the traversal passed it, since shrunk.
			arr_from = u32(as_int(key))
		} else {
			return NIL, NIL, false
		}
	}
	if arr_from < t.arr_len {
		arr := values_of(vm, t.arr, t.arr_cap)
		for i in arr_from ..< t.arr_len {
			if arr[i].tag != .Nil {return int_value(i64(i) + 1), arr[i], true}
		}
	}
	if t.entries != 0 {
		entries := values_of(vm, t.entries, t.entries_cap * 2)
		for i in hash_from ..< t.entries_len {
			if entries[i * 2 + 1].tag != .Nil {return entries[i * 2], entries[i * 2 + 1], true}
		}
	}
	return NIL, NIL, true
}
