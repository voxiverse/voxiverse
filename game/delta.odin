package game

import "base:runtime"
import "core:mem"
import "core:strings"

// The value codec of the state model (M39), derived from schema.odin's fields:
// whole values (creates, events, array elements), field deltas (changes), and
// the comparisons, copies and checks that go with them. Nothing here knows a
// game type.

@(private)
load_bits :: proc(data: rawptr, size: int) -> u64 {
	switch size {
	case 1:
		return u64((^u8)(data)^)
	case 2:
		return u64((^u16)(data)^)
	case 4:
		return u64((^u32)(data)^)
	case 8:
		return (^u64)(data)^
	}
	panic("integer of an odd size")
}

@(private)
store_bits :: proc(data: rawptr, size: int, v: u64) {
	switch size {
	case 1:
		(^u8)(data)^ = u8(v)
	case 2:
		(^u16)(data)^ = u16(v)
	case 4:
		(^u32)(data)^ = u32(v)
	case 8:
		(^u64)(data)^ = v
	case:
		panic("integer of an odd size")
	}
}

@(private)
sign_extend :: proc(v: u64, size: int) -> i64 {
	switch size {
	case 1:
		return i64(i8(v))
	case 2:
		return i64(i16(v))
	case 4:
		return i64(i32(v))
	}
	return i64(v)
}

@(private)
width_mask :: proc(size: int) -> u64 {
	return max(u64) if size >= 8 else (u64(1) << uint(size * 8)) - 1
}

// int_signed: whether an integer or enum type is signed.
@(private)
int_signed :: proc(base: ^runtime.Type_Info) -> bool {
	#partial switch v in base.variant {
	case runtime.Type_Info_Integer:
		return v.signed
	case runtime.Type_Info_Enum:
		return int_signed(runtime.type_info_base(v.base))
	}
	return false
}

@(private)
bit_set_bits :: proc(v: runtime.Type_Info_Bit_Set) -> (valid: u64) {
	if en, is_enum := runtime.type_info_base(v.elem).variant.(runtime.Type_Info_Enum); is_enum {
		for x in en.values {valid |= 1 << uint(i64(x) - i64(v.lower))}
	} else {
		for bit in v.lower ..= v.upper {valid |= 1 << uint(bit - v.lower)}
	}
	return
}

@(private)
write_int :: proc(w: ^Writer, base: ^runtime.Type_Info, data: rawptr) {
	bits := load_bits(data, base.size)
	if int_signed(base) {
		write_svarint64(w, sign_extend(bits, base.size))
	} else {
		write_varint64(w, bits)
	}
}

@(private)
read_int :: proc(r: ^Reader, base: ^runtime.Type_Info, data: rawptr) -> u64 {
	size := base.size
	if int_signed(base) {
		s := read_svarint64(r)
		if size < 8 {
			limit := i64(1) << uint(size * 8 - 1)
			if s < -limit || s >= limit {r.ok = false}
		}
		v := u64(s) & width_mask(size)
		if r.ok {store_bits(data, size, v)}
		return v
	}
	v := read_varint64(r)
	if v & ~width_mask(size) != 0 {r.ok = false}
	if r.ok {store_bits(data, size, v)}
	return v
}

// write_whole writes a value of any supported type, absolute.
write_whole :: proc(w: ^Writer, ti: ^runtime.Type_Info, data: rawptr) {
	base := runtime.type_info_base(ti)
	#partial switch v in base.variant {
	case runtime.Type_Info_Boolean:
		write_u8(w, 1 if load_bits(data, base.size) != 0 else 0)
	case runtime.Type_Info_Integer:
		write_int(w, base, data)
	case runtime.Type_Info_Float:
		if base.size == 4 {write_f32(w, (^f32)(data)^)} else {write_f64(w, (^f64)(data)^)}
	case runtime.Type_Info_Enum:
		write_int(w, runtime.type_info_base(v.base), data)
	case runtime.Type_Info_Bit_Set:
		write_varint64(w, load_bits(data, base.size))
	case runtime.Type_Info_Array:
		for i in 0 ..< v.count {
			write_whole(w, v.elem, rawptr(uintptr(data) + uintptr(i * v.elem_size)))
		}
	case runtime.Type_Info_Enumerated_Array:
		for i in 0 ..< v.count {
			write_whole(w, v.elem, rawptr(uintptr(data) + uintptr(i * v.elem_size)))
		}
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(v.field_count) {
			if v.names[i] == "_" {continue}
			write_whole(w, v.types[i], rawptr(uintptr(data) + v.offsets[i]))
		}
	case runtime.Type_Info_Union:
		tag := load_bits(rawptr(uintptr(data) + v.tag_offset), v.tag_type.size)
		write_u8(w, u8(tag))
		index := int(tag) - (0 if v.no_nil else 1)
		if index >= 0 {write_whole(w, v.variants[index], data)}
	case:
		panic("write_whole: a type the schema refuses")
	}
}

// read_whole reads one into data (memory of the type, any content); false (and
// the reader failed) if it is not valid.
read_whole :: proc(r: ^Reader, ti: ^runtime.Type_Info, data: rawptr) -> bool {
	base := runtime.type_info_base(ti)
	#partial switch v in base.variant {
	case runtime.Type_Info_Boolean:
		b := read_u8(r)
		if b > 1 {r.ok = false}
		if r.ok {store_bits(data, base.size, u64(b))}
	case runtime.Type_Info_Integer:
		read_int(r, base, data)
	case runtime.Type_Info_Float:
		if base.size == 4 {
			x := read_f32(r)
			if r.ok {(^f32)(data)^ = x}
		} else {
			x := read_f64(r)
			if r.ok {(^f64)(data)^ = x}
		}
	case runtime.Type_Info_Enum:
		bits := read_int(r, runtime.type_info_base(v.base), data)
		if r.ok {
			value := sign_extend(bits, base.size) if int_signed(runtime.type_info_base(v.base)) else i64(bits)
			found := false
			for x in v.values {if i64(x) == value {found = true}}
			if !found {r.ok = false}
		}
	case runtime.Type_Info_Bit_Set:
		bits := read_varint64(r)
		if bits & ~width_mask(base.size) != 0 || bits & ~bit_set_bits(v) != 0 {r.ok = false}
		if r.ok {store_bits(data, base.size, bits)}
	case runtime.Type_Info_Array:
		for i in 0 ..< v.count {
			if !read_whole(r, v.elem, rawptr(uintptr(data) + uintptr(i * v.elem_size))) {return false}
		}
	case runtime.Type_Info_Enumerated_Array:
		for i in 0 ..< v.count {
			if !read_whole(r, v.elem, rawptr(uintptr(data) + uintptr(i * v.elem_size))) {return false}
		}
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(v.field_count) {
			if v.names[i] == "_" {continue}
			if !read_whole(r, v.types[i], rawptr(uintptr(data) + v.offsets[i])) {return false}
		}
	case runtime.Type_Info_Union:
		tag := read_u8(r)
		index := int(tag) - (0 if v.no_nil else 1)
		if index >= len(v.variants) {r.ok = false}
		if !r.ok {return false}
		store_bits(rawptr(uintptr(data) + v.tag_offset), v.tag_type.size, u64(tag))
		if index >= 0 {read_whole(r, v.variants[index], data)}
	case:
		panic("read_whole: a type the schema refuses")
	}
	return r.ok
}

// whole_equal compares two values by their content (bits for floats, so -0
// differs from 0; padding never counts).
whole_equal :: proc(ti: ^runtime.Type_Info, a, b: rawptr) -> bool {
	base := runtime.type_info_base(ti)
	#partial switch v in base.variant {
	case runtime.Type_Info_Array:
		for i in 0 ..< v.count {
			off := uintptr(i * v.elem_size)
			if !whole_equal(v.elem, rawptr(uintptr(a) + off), rawptr(uintptr(b) + off)) {return false}
		}
		return true
	case runtime.Type_Info_Enumerated_Array:
		for i in 0 ..< v.count {
			off := uintptr(i * v.elem_size)
			if !whole_equal(v.elem, rawptr(uintptr(a) + off), rawptr(uintptr(b) + off)) {return false}
		}
		return true
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(v.field_count) {
			if v.names[i] == "_" {continue}
			off := v.offsets[i]
			if !whole_equal(v.types[i], rawptr(uintptr(a) + off), rawptr(uintptr(b) + off)) {return false}
		}
		return true
	case runtime.Type_Info_Union:
		ta := load_bits(rawptr(uintptr(a) + v.tag_offset), v.tag_type.size)
		tb := load_bits(rawptr(uintptr(b) + v.tag_offset), v.tag_type.size)
		if ta != tb {return false}
		index := int(ta) - (0 if v.no_nil else 1)
		return index < 0 || whole_equal(v.variants[index], a, b)
	case runtime.Type_Info_String:
		return (^string)(a)^ == (^string)(b)^
	}
	return mem.compare_ptrs(a, b, base.size) == 0
}

@(private)
leaf_at :: #force_inline proc(f: ^Field, value: rawptr) -> rawptr {
	return rawptr(uintptr(value) + uintptr(f.offset))
}

@(private)
elem_at :: #force_inline proc(f: ^Field, leaf: rawptr, i: int) -> rawptr {
	return rawptr(uintptr(leaf) + uintptr(i * f.elem_size))
}

leaf_equal :: proc(f: ^Field, a, b: rawptr) -> bool {
	switch f.type {
	case .Bool, .Uint, .Int, .F32, .F64, .Enum, .Bit_Set:
		return mem.compare_ptrs(a, b, f.size) == 0
	case .Array:
		if f.scalar {return mem.compare_ptrs(a, b, f.size) == 0}
		return whole_equal(f.ti, a, b)
	case .Union:
		return whole_equal(f.ti, a, b)
	case .String:
		return (^string)(a)^ == (^string)(b)^
	}
	return true
}

// value_diff: the mask of fields of k whose values differ.
value_diff :: proc(k: ^Schema_Kind, a, b: rawptr) -> (mask: u64) {
	for &f, i in k.fields {
		if !leaf_equal(&f, leaf_at(&f, a), leaf_at(&f, b)) {mask |= 1 << uint(i)}
	}
	return
}

value_all :: proc(k: ^Schema_Kind) -> u64 {
	return (u64(1) << uint(len(k.fields))) - 1
}

// leaf_write writes the field's value from p, whole.
leaf_write :: proc(w: ^Writer, f: ^Field, p: rawptr) {
	if f.type == .String {
		write_string(w, (^string)(p)^)
		return
	}
	write_whole(w, f.ti, p)
}

// leaf_read reads the field's value into p, whole. own: a string is copied
// (the record keeps it); else it is a view into the message.
leaf_read :: proc(r: ^Reader, f: ^Field, p: rawptr, own: bool) -> bool {
	if f.type == .String {
		s := read_string(r, f.max)
		if !r.ok {return false}
		sp := (^string)(p)
		if own {
			delete(sp^)
			sp^ = strings.clone(s)
		} else {
			sp^ = s
		}
		return true
	}
	return read_whole(r, f.ti, p)
}

// leaf_write_delta writes what changed in the field: integers as the zigzag
// difference from old (in the field's width, wrapping), arrays of structs as
// the elements that differ, the rest whole.
leaf_write_delta :: proc(w: ^Writer, f: ^Field, p, old: rawptr) {
	switch f.type {
	case .Uint, .Int:
		nv, ov := load_bits(p, f.size), load_bits(old, f.size)
		d := sign_extend((nv - ov) & width_mask(f.size), f.size)
		write_varint64(w, u64((d << 1) ~ (d >> 63)))
	case .Array:
		if f.scalar {
			write_whole(w, f.ti, p)
			return
		}
		n := 0
		for i in 0 ..< f.count {
			if !whole_equal(f.elem, elem_at(f, p, i), elem_at(f, old, i)) {n += 1}
		}
		write_varint(w, u32(n))
		for i in 0 ..< f.count {
			if whole_equal(f.elem, elem_at(f, p, i), elem_at(f, old, i)) {continue}
			write_varint(w, u32(i))
			write_whole(w, f.elem, elem_at(f, p, i))
		}
	case .Bool, .F32, .F64, .Enum, .Bit_Set, .Union, .String:
		leaf_write(w, f, p)
	}
}

// leaf_read_delta applies a delta to p (holding the old value).
leaf_read_delta :: proc(r: ^Reader, f: ^Field, p: rawptr, own: bool) -> bool {
	switch f.type {
	case .Uint, .Int:
		zz := read_varint64(r)
		if f.size < 8 && zz >> uint(f.size * 8) != 0 {r.ok = false}
		if !r.ok {return false}
		d := i64(zz >> 1) ~ -i64(zz & 1)
		store_bits(p, f.size, (load_bits(p, f.size) + u64(d)) & width_mask(f.size))
		return true
	case .Array:
		if f.scalar {return read_whole(r, f.ti, p)}
		n := int(read_varint(r))
		if !r.ok || n < 1 || n > f.count {
			r.ok = false
			return false
		}
		last := -1
		for _ in 0 ..< n {
			i := int(read_varint(r))
			if !r.ok || i <= last || i >= f.count {
				r.ok = false
				return false
			}
			last = i
			if !read_whole(r, f.elem, elem_at(f, p, i)) {return false}
		}
		return true
	case .Bool, .F32, .F64, .Enum, .Bit_Set, .Union, .String:
		return leaf_read(r, f, p, own)
	}
	return false
}

// value_copy: dst becomes a copy of src (strings are copied, not shared).
value_copy :: proc(k: ^Schema_Kind, dst, src: rawptr) {
	if k.has_strings {
		value_free(k, dst)
	}
	mem.copy(dst, src, k.size)
	if k.has_strings {
		for &f in k.fields {
			if f.type == .String {
				sp := (^string)(leaf_at(&f, dst))
				sp^ = strings.clone(sp^)
			}
		}
	}
}

// value_free releases the strings a value owns.
value_free :: proc(k: ^Schema_Kind, v: rawptr) {
	if !k.has_strings {return}
	for &f in k.fields {
		if f.type == .String {
			sp := (^string)(leaf_at(&f, v))
			delete(sp^)
			sp^ = ""
		}
	}
}
