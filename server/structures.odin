package server

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../common/game"
import "../common/worldgen"

// Structures players keep: `structure save` turns a box of the world into
// a template file in the world's structures directory; `structure paste`
// puts one (the world's own, else one shipped with the game) back through
// the bulk edit pipeline, turned any quarter.

STRUCTURES_DIR :: "structures"

structure_name_valid :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > 32 {return false}
	for c in transmute([]u8)name {
		if !((c >= 'a' && c <= 'z') ||
			   (c >= '0' && c <= '9') ||
			   c == '_' ||
			   c == '-') {return false}
	}
	return true
}

// structure_save keeps lo..hi of the world as template name: air as void
// (pasting leaves what is there), or with clear, as air (pasting clears).
structure_save :: proc(w: ^World, name: string, lo, hi: game.Block_Pos, clear: bool) -> string {
	s := w.server
	if s.store.dir ==
	   "" {return "structure save: a scratch world keeps nothing (play a saved world)"}
	box := Box{lo, hi}
	a, b := shape_box(box)
	size := b - a + 1
	for v in size {
		if v >
		   game.MAX_TEMPLATE_SIZE {return fmt.tprintf("structure save: at most %d blocks on a side", game.MAX_TEMPLATE_SIZE)}
	}
	t := game.Template {
		size  = size,
		cells = make([]u16, int(size.x * size.y * size.z), context.temp_allocator),
	}
	for y in i32(0) ..< size.y {
		for z in i32(0) ..< size.z {
			for x in i32(0) ..< size.x {
				blk, loaded := chunks_block(&w.chunks, a + {x, y, z})
				if !loaded {return "structure save: part of it is not loaded"}
				cell := u16(blk)
				if blk == .Air && !clear {cell = game.VOID}
				t.cells[game.template_index(&t, {x, y, z})] = cell
			}
		}
	}
	w: game.Writer
	game.writer_init(&w, context.temp_allocator)
	game.template_encode(&w, &t)
	dir :=
		filepath.join({s.store.dir, STRUCTURES_DIR}, context.temp_allocator) or_else STRUCTURES_DIR
	os.make_directory_all(dir)
	path :=
		filepath.join(
			{dir, strings.concatenate({name, ".vxs"}, context.temp_allocator)},
			context.temp_allocator,
		) or_else name
	if !write_atomically(
		path,
		w.buf[:],
	) {return "structure save: could not write it (see the server log)"}
	return fmt.tprintf("structure %s saved: %d x %d x %d", name, size.x, size.y, size.z)
}

// structure_load finds template name: the world's own, else one shipped
// with the game (temp allocator).
structure_load :: proc(s: ^Server, name: string) -> (t: game.Template, ok: bool) {
	if s.store.dir != "" {
		path :=
			filepath.join(
				{
					s.store.dir,
					STRUCTURES_DIR,
					strings.concatenate({name, ".vxs"}, context.temp_allocator),
				},
				context.temp_allocator,
			) or_else name
		if data, err := os.read_entire_file_from_path(path, context.temp_allocator); err == nil {
			return game.template_decode(data, context.temp_allocator)
		}
	}
	return worldgen.shipped_template(name, context.temp_allocator)
}

// structure_paste puts template name with its lowest corner at at.
structure_paste :: proc(
	w: ^World,
	name: string,
	at: game.Block_Pos,
	rotation: u8,
	act: Act,
) -> string {
	s := w.server
	t, found := structure_load(s, name)
	if !found {return fmt.tprintf("structure paste: no structure %s (structure list)", name)}
	size := game.rotated_size(t.size, rotation)
	e := Bulk_Edit {
		shape    = Box{at, at + size - 1},
		op       = .Paste,
		template = &t,
		rotation = rotation,
	}
	changed, result, protected := bulk_edit(w, e, act)
	switch result {
	case .Done:
		if protected > 0 {
			return fmt.tprintf(
				"structure %s pasted: %d blocks changed, %d protected",
				name,
				changed,
				protected,
			)
		}
		return fmt.tprintf("structure %s pasted: %d blocks changed", name, changed)
	case .Too_Big:
		return "structure paste: too big"
	case .Not_Loaded:
		return "structure paste: part of it is not loaded"
	}
	return ""
}

// structure_list: the names of the world's structures and the shipped ones.
structure_list :: proc(s: ^Server) -> string {
	names := make([dynamic]string, context.temp_allocator)
	if s.store.dir != "" {
		dir :=
			filepath.join(
				{s.store.dir, STRUCTURES_DIR},
				context.temp_allocator,
			) or_else STRUCTURES_DIR
		if entries, err := os.read_all_directory_by_path(dir, context.temp_allocator); err == nil {
			for e in entries {
				if strings.has_suffix(
					e.name,
					".vxs",
				) {append(&names, strings.trim_suffix(e.name, ".vxs"))}
			}
		}
	}
	for n in worldgen.shipped_names(context.temp_allocator) {append(&names, fmt.tprintf("%s (shipped)", n))}
	if len(names) ==
	   0 {return "No structures yet: select a box (pos1, pos2) and `structure save <name>`"}
	return strings.join(names[:], ", ", context.temp_allocator)
}
