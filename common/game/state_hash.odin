package game

import "base:runtime"
import "core:fmt"
import "core:strings"

// The state hash's walker (docs/determinism.md): one reflective walk over a
// value with two outputs. hash_value folds it into a Hasher; dump_value writes
// a line per leaf, `entities[3].body.velocity.x = 0x3f8ccccd (1.1)`, which is
// how a divergence is named. A field added to a struct is hashed without
// anyone remembering to. A map, a pointer or a procedure panics with the
// field's path: keyed state is hashed by hand, in sorted order.
//
// Integers, enums, bools and bit_sets are their bytes; floats are their bits
// (so -0 is not 0); padding never enters (fields are walked, not bytes of the
// struct); arrays, structs and unions (tag, then value) are walked; slices,
// dynamic arrays and strings are a length, then their elements.

// A Hasher folds u64 words, each mixed as h = (h ~ w) * FNV prime.
Hasher :: struct {
	h: u64,
}

hasher_make :: proc "contextless" () -> Hasher {
	return {0xcbf2_9ce4_8422_2325}
}

hasher_mix :: #force_inline proc "contextless" (h: ^Hasher, word: u64) {
	h.h = (h.h ~ word) * 0x0000_0100_0000_01b3
}

hasher_bytes :: proc "contextless" (h: ^Hasher, bytes: []u8) {
	i := 0
	for ; i + 8 <= len(bytes); i += 8 {
		w: u64
		for k in 0 ..< 8 {w |= u64(bytes[i + k]) << (8 * uint(k))}
		hasher_mix(h, w)
	}
	if i < len(bytes) {
		w: u64
		for k in 0 ..< len(bytes) - i {w |= u64(bytes[i + k]) << (8 * uint(k))}
		hasher_mix(h, w)
	}
	hasher_mix(h, u64(len(bytes)))
}

// hasher_finish is splitmix64's finalizer.
hasher_finish :: proc "contextless" (h: Hasher) -> u64 {
	z := h.h
	z = (z ~ (z >> 30)) * 0xbf58_476d_1ce4_e5b9
	z = (z ~ (z >> 27)) * 0x94d0_49bb_1331_11eb
	return z ~ (z >> 31)
}

hash_value :: proc(h: ^Hasher, v: any, name := "value") {
	w := Walker {
		h    = h,
		path = make([dynamic]u8, context.temp_allocator),
	}
	append(&w.path, ..transmute([]u8)name)
	walk(&w, v.data, runtime.type_info_base(type_info_of(v.id)), type_info_of(v.id))
}

// hash_refusal walks v without hashing and returns the message hash_value
// would panic with, or "" if v is hashable. It exists so a test can see the
// refusal without catching a panic (the runner's assert capture does not
// survive on every OS).
hash_refusal :: proc(v: any, name := "value") -> string {
	refused: string
	w := Walker {
		h       = &Hasher{},
		path    = make([dynamic]u8, context.temp_allocator),
		refused = &refused,
	}
	append(&w.path, ..transmute([]u8)name)
	walk(&w, v.data, runtime.type_info_base(type_info_of(v.id)), type_info_of(v.id))
	return refused
}

// dump_value writes one line per leaf of v, named from path.
dump_value :: proc(b: ^strings.Builder, path: string, v: any) {
	w := Walker {
		b    = b,
		path = make([dynamic]u8, context.temp_allocator),
	}
	append(&w.path, ..transmute([]u8)path)
	walk(&w, v.data, runtime.type_info_base(type_info_of(v.id)), type_info_of(v.id))
}

@(private = "file")
Walker :: struct {
	h:       ^Hasher,
	b:       ^strings.Builder,
	path:    [dynamic]u8,
	refused: ^string, // set: the first refusal is recorded here, not panicked
}

@(private = "file")
leaf :: proc(w: ^Walker, data: rawptr, size: int, shown: any) {
	bytes := ([^]u8)(data)[:size]
	if w.h != nil {
		hasher_bytes(w.h, bytes)
		return
	}
	bits: u64
	for x, k in bytes {bits |= u64(x) << (8 * uint(k))}
	fmt.sbprintf(w.b, "%s = 0x%x (%v)\n", string(w.path[:]), bits, shown)
}

@(private = "file")
length :: proc(w: ^Walker, n: int) {
	if w.h != nil {
		hasher_mix(w.h, u64(n))
	} else {
		fmt.sbprintf(w.b, "%s.len = %d\n", string(w.path[:]), n)
	}
}

@(private = "file")
refuse :: proc(w: ^Walker, what: string) {
	msg := fmt.tprintf(
		"state hash: %s is %s: hash it by hand, in sorted order",
		string(w.path[:]),
		what,
	)
	if w.refused != nil {
		if w.refused^ == "" {w.refused^ = msg}
		return
	}
	panic(msg)
}

@(private = "file")
scalar_array :: proc(base: ^runtime.Type_Info) -> bool {
	#partial switch v in base.variant {
	case runtime.Type_Info_Integer,
	     runtime.Type_Info_Float,
	     runtime.Type_Info_Boolean,
	     runtime.Type_Info_Enum,
	     runtime.Type_Info_Rune,
	     runtime.Type_Info_Bit_Set:
		return true
	}
	return false
}

@(private = "file")
walk :: proc(w: ^Walker, data: rawptr, base: ^runtime.Type_Info, ti: ^runtime.Type_Info) {
	mark := len(w.path)
	defer resize(&w.path, mark)
	elements :: proc(
		w: ^Walker,
		data: rawptr,
		count: int,
		elem: ^runtime.Type_Info,
		vector := false,
	) {
		eb := runtime.type_info_base(elem)
		if w.h != nil && scalar_array(eb) { 	// plain scalars: one go
			hasher_bytes(w.h, ([^]u8)(data)[:count * elem.size])
			return
		}
		mark := len(w.path)
		for i in 0 ..< count {
			resize(&w.path, mark)
			if vector { 	// a position, a velocity: .x .y .z .w, as it is written in code
				letters := "xyzw"
				append(&w.path, '.', letters[i])
			} else {
				append(&w.path, ..transmute([]u8)fmt.tprintf("[%d]", i))
			}
			walk(w, rawptr(uintptr(data) + uintptr(i * elem.size)), eb, elem)
		}
	}
	switch v in base.variant {
	case runtime.Type_Info_Integer,
	     runtime.Type_Info_Float,
	     runtime.Type_Info_Boolean,
	     runtime.Type_Info_Rune,
	     runtime.Type_Info_Bit_Set,
	     runtime.Type_Info_Bit_Field,
	     runtime.Type_Info_Complex,
	     runtime.Type_Info_Quaternion,
	     runtime.Type_Info_Simd_Vector:
		leaf(w, data, ti.size, any{data, ti.id})
	case runtime.Type_Info_Enum:
		leaf(w, data, ti.size, any{data, ti.id})
	case runtime.Type_Info_Array:
		elements(w, data, v.count, v.elem, v.count <= 4)
	case runtime.Type_Info_Enumerated_Array:
		elements(w, data, v.count, v.elem)
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(v.field_count) {
			resize(&w.path, mark)
			append(&w.path, '.')
			append(&w.path, ..transmute([]u8)v.names[i])
			walk(
				w,
				rawptr(uintptr(data) + v.offsets[i]),
				runtime.type_info_base(v.types[i]),
				v.types[i],
			)
		}
	case runtime.Type_Info_Union:
		tag: u64
		switch v.tag_type.size {
		case 1:
			tag = u64((^u8)(uintptr(data) + v.tag_offset)^)
		case 2:
			tag = u64((^u16)(uintptr(data) + v.tag_offset)^)
		case 4:
			tag = u64((^u32)(uintptr(data) + v.tag_offset)^)
		case:
			tag = u64((^u64)(uintptr(data) + v.tag_offset)^)
		}
		if w.h != nil {
			hasher_mix(w.h, tag)
		} else {
			fmt.sbprintf(w.b, "%s.tag = %d\n", string(w.path[:]), tag)
		}
		index := int(tag) - (0 if v.no_nil else 1)
		if index >= 0 && index < len(v.variants) {
			walk(w, data, runtime.type_info_base(v.variants[index]), v.variants[index])
		}
	case runtime.Type_Info_Slice:
		raw := (^runtime.Raw_Slice)(data)^
		length(w, raw.len)
		elements(w, raw.data, raw.len, v.elem)
	case runtime.Type_Info_Dynamic_Array:
		raw := (^runtime.Raw_Dynamic_Array)(data)^
		length(w, raw.len)
		elements(w, raw.data, raw.len, v.elem)
	case runtime.Type_Info_String:
		raw := (^runtime.Raw_String)(data)^
		length(w, raw.len)
		if raw.len > 0 {leaf(w, raw.data, raw.len, string(([^]u8)(raw.data)[:raw.len]))}
	case runtime.Type_Info_Fixed_Capacity_Dynamic_Array:
		n := (^int)(uintptr(data) + v.len_offset)^
		length(w, n)
		elements(w, data, n, v.elem)
	case runtime.Type_Info_Map:
		refuse(w, "a map")
	case runtime.Type_Info_Pointer, runtime.Type_Info_Multi_Pointer:
		refuse(w, "a pointer")
	case runtime.Type_Info_Procedure:
		refuse(w, "a procedure")
	case runtime.Type_Info_Any, runtime.Type_Info_Type_Id, runtime.Type_Info_Parameters:
		refuse(w, "a type-erased value")
	case runtime.Type_Info_Named:
		unreachable() // (base type)
	case runtime.Type_Info_Matrix:
		leaf(w, data, ti.size, "")
	case runtime.Type_Info_Soa_Pointer:
		refuse(w, "a pointer")
	}
}

// hash_chunk_blocks folds a chunk's blocks the same whether it is stored
// uniform or as an array (the server's and a client's copies differ in that).
hash_chunk_blocks :: proc(h: ^Hasher, c: ^Chunk_Blocks) {
	if c.array != nil {
		hasher_bytes(h, ([^]u8)(c.array)[:size_of(Block_Array)])
		return
	}
	filled := new(Block_Array, context.temp_allocator)
	for &b in filled {b = c.uniform}
	hasher_bytes(h, ([^]u8)(filled)[:size_of(Block_Array)])
}

// hash_chunk folds a chunk's position and blocks (a checkpoint's unit).
hash_chunk :: proc(h: ^Hasher, pos: Chunk_Pos, c: ^Chunk_Blocks) {
	hasher_mix(h, u64(u32(pos.x)) | u64(u32(pos.y)) << 32)
	hasher_mix(h, u64(u32(pos.z)))
	hash_chunk_blocks(h, c)
}
