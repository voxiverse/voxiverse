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

// template_make: a template of size, every cell air, as a game lays out a seeded arena
// in code (template_fill its boxes, then core.bulk_edit's .Paste puts it in the world).
template_make :: proc(size: [3]i32, allocator := context.allocator) -> Template {
	return {size = size, cells = make([]u16, int(size.x) * int(size.y) * int(size.z), allocator)}
}

// template_fill: every cell of the box lo..hi (inclusive) that is inside the template
// becomes block; the rest of the box is ignored, so a game lays out boxes that run over
// its edges without clipping them itself.
template_fill :: proc(t: ^Template, lo, hi: [3]i32, block: Block) {
	for y in max(lo.y, 0) ..= min(hi.y, t.size.y - 1) {
		for z in max(lo.z, 0) ..= min(hi.z, t.size.z - 1) {
			for x in max(lo.x, 0) ..= min(hi.x, t.size.x - 1) {
				t.cells[template_index(t, {x, y, z})] = u16(block)
			}
		}
	}
}

// template_build: a template from text, as a game writes its buildings in code: layers
// from the bottom up, each its rows from -z to +z separated by '/', each row its cells
// from -x to +x, one character each; key's i-th character stands for cells[i] (a
// Block, or VOID). False for rows or layers of uneven length, a character not in key,
// or a size past MAX_TEMPLATE_SIZE.
//
//	template_build({"###/#.#/###", "#.#/.../#.#"}, "#.", {u16(planks), VOID})
template_build :: proc(
	layers: []string,
	key: string,
	cells: []u16,
	allocator := context.allocator,
) -> (
	t: Template,
	ok: bool,
) {
	if len(layers) == 0 || len(layers) > MAX_TEMPLATE_SIZE || len(key) != len(cells) {return}
	width, depth := -1, 0
	for layer in layers {
		rows, x := 1, 0
		for c in layer {
			if c == '/' {
				if width >= 0 && x != width {return}
				width, x, rows = x, 0, rows + 1
				continue
			}
			x += 1
		}
		if width >= 0 && x != width {return}
		width = x
		if depth != 0 && rows != depth {return}
		depth = rows
	}
	if width < 1 || width > MAX_TEMPLATE_SIZE || depth > MAX_TEMPLATE_SIZE {return}
	t.size = {i32(width), i32(len(layers)), i32(depth)}
	t.cells = make([]u16, width * depth * len(layers), allocator)
	for layer, y in layers {
		x, z := 0, 0
		for c in layer {
			if c == '/' {
				x, z = 0, z + 1
				continue
			}
			k := -1
			for kc, i in key {if kc == c {k = i}}
			if k < 0 {
				delete(t.cells, allocator)
				return {}, false
			}
			t.cells[template_index(&t, {i32(x), i32(y), i32(z)})] = cells[k]
			x += 1
		}
	}
	return t, true
}

template_encode :: proc(w: ^Writer, t: ^Template, reg: ^Registry) {
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
	for p in palette {write_string(w, "void" if p == VOID else state_text(reg, Block(p)))}
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
template_decode :: proc(
	reg: ^Registry,
	data: []u8,
	allocator := context.allocator,
) -> (
	t: Template,
	ok: bool,
) {
	resolve :: proc(user: rawptr, name: string) -> (u16, bool) {
		b, found := registry_block((^Registry)(user), name)
		return u16(b), found
	}
	return template_decode_with(data, resolve, reg, allocator)
}

// template_decode_with: as template_decode, the names resolved by resolve
// (nil: the builtin blocks; a name without a colon is voxiverse:'s).
template_decode_with :: proc(
	data: []u8,
	resolve: proc(user: rawptr, name: string) -> (u16, bool),
	user: rawptr = nil,
	allocator := context.allocator,
) -> (
	t: Template,
	ok: bool,
) {
	r := reader_make(data)
	if read_u32(&r) != TEMPLATE_MAGIC {return}
	for &v in t.size {v = read_i32(&r)}
	if !r.ok {return}
	for v in t.size {if v < 1 || v > MAX_TEMPLATE_SIZE {return}}
	palette := make([dynamic]u16, context.temp_allocator)
	n := read_varint(&r)
	if n > MAX_BLOCK_STATES + 1 {return}
	for _ in 0 ..< n {
		name := read_string(&r, 64)
		if name == "void" {
			append(&palette, VOID)
			continue
		}
		if resolve != nil {
			id, known := resolve(user, name)
			if !known {return}
			append(&palette, id)
			continue
		}
		return // (no resolver: no names are known)
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
