package game

import "core:mem"

// Structures: built things kept to paste again, by players
// (`structure save` / `paste`) and by world generation. A Template is a
// box of cells, each a block or VOID: a void cell leaves whatever is there
// (so a ruin can sit on uneven ground), an air cell clears it.
//
// A .vxs file: "VXS1", the size, a palette of block names ("void" for
// VOID; names, not ids, so a file outlives any reordering), then runs of
// (count, palette index) over the cells, x fastest, then z, then y.

VOID :: max(u16)
MAX_TEMPLATE_SIZE :: 64 // blocks on each side
TEMPLATE_MAGIC :: u32(0x3153_5856) // "VXS1"

Template :: struct {
	size:  [3]i32,
	cells: []u16, // a Block, or VOID
}

template_index :: #force_inline proc(t: ^Template, l: [3]i32) -> int {
	return int(l.x) + int(l.z) * int(t.size.x) + int(l.y) * int(t.size.x) * int(t.size.z)
}

// rotated_size: the template's box turned rotation quarter turns.
rotated_size :: proc(size: [3]i32, rotation: u8) -> [3]i32 {
	return {size.z, size.y, size.x} if rotation & 1 == 1 else size
}

// template_cell: the cell at l in the template turned rotation quarter
// turns (clockwise seen from above); l within rotated_size.
template_cell :: proc(t: ^Template, l: [3]i32, rotation: u8) -> u16 {
	x, z := l.x, l.z
	switch rotation & 3 {
	case 1:
		x, z = l.z, t.size.z - 1 - l.x
	case 2:
		x, z = t.size.x - 1 - l.x, t.size.z - 1 - l.z
	case 3:
		x, z = t.size.x - 1 - l.z, l.x
	}
	return t.cells[template_index(t, {x, l.y, z})]
}

template_encode :: proc(w: ^Writer, t: ^Template) {
	write_u32(w, TEMPLATE_MAGIC)
	for v in t.size {write_i32(w, v)}
	// The palette: the cells' kinds in order of first appearance.
	palette := make([dynamic]u16, context.temp_allocator)
	for c in t.cells {
		found := false
		for p in palette {if p == c {found = true; break}}
		if !found {append(&palette, c)}
	}
	write_varint(w, u32(len(palette)))
	for p in palette {write_string(w, "void" if p == VOID else BLOCK_INFO[Block(p)].name)}
	for i := 0; i < len(t.cells); {
		j := i
		for j < len(t.cells) && t.cells[j] == t.cells[i] {j += 1}
		k := 0
		for palette[k] != t.cells[i] {k += 1}
		write_varint(w, u32(j - i))
		write_varint(w, u32(k))
		i = j
	}
}

// template_decode reads a .vxs; false for a damaged file or an unknown
// block name.
template_decode :: proc(data: []u8, allocator := context.allocator) -> (t: Template, ok: bool) {
	r := reader_make(data)
	if read_u32(&r) != TEMPLATE_MAGIC {return}
	for &v in t.size {v = read_i32(&r)}
	if !r.ok {return}
	for v in t.size {if v < 1 || v > MAX_TEMPLATE_SIZE {return}}
	palette := make([dynamic]u16, context.temp_allocator)
	n := read_varint(&r)
	if n > u32(len(Block)) + 1 {return}
	for _ in 0 ..< n {
		name := read_string(&r, 64)
		if name == "void" {
			append(&palette, VOID)
			continue
		}
		b, known := block_by_name(name)
		if !known {return}
		append(&palette, u16(b))
	}
	err: mem.Allocator_Error
	t.cells, err = make([]u16, int(t.size.x * t.size.y * t.size.z), allocator)
	if err != nil {return}
	at := 0
	for at < len(t.cells) && r.ok {
		count, k := int(read_varint(&r)), int(read_varint(&r))
		if count == 0 || at + count > len(t.cells) || k >= len(palette) {
			r.ok = false
			break
		}
		for &c in t.cells[at:][:count] {c = palette[k]}
		at += count
	}
	if !reader_finish(&r) {
		delete(t.cells, allocator)
		return {}, false
	}
	return t, true
}
