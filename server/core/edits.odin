package core

import "core:log"
import "core:math"

import "common:game"
import "common:voxel"

// Bulk edits: a shape (sphere, box, any set of cells as a voxel.Mask) and an
// operation applied to every block in it, chunk by chunk and in each a row of
// cells at a time, each touched column's top found again once; the touched
// chunks are sent whole at the end of the tick (changes.odin) instead of a
// message per block. However many cells, a bulk edit is one cause in the
// journal, one change told to the game and one wake of the simulation.

MAX_BULK_VOLUME :: 64 * 64 * 64 // blocks in the shape's box

Bulk_Shape :: union {
	Sphere,
	Box,
	voxel.Mask, // its cells (world_mask reads one from the world)
}

// Sphere: the blocks whose centres lie within radius of center.
Sphere :: struct {
	center: [3]f64,
	radius: f64,
}

// Box: lo..hi inclusive.
Box :: struct {
	lo, hi: game.Block_Pos,
}

Bulk_Op :: enum u8 {
	Set, // every block becomes block
	Replace, // blocks that are `from` become block
	Carve, // everything becomes air (an explosion; bedrock stays)
	Paste, // a template's cells (its void cells leave what is there)
	Unpaste, // a template's cells that are still as it made them become air: what Paste built, taken down
}

// Bulk_Edit: an operation on every block of a shape (bulk_edit).
Bulk_Edit :: struct {
	shape:    Bulk_Shape,
	op:       Bulk_Op,
	block:    game.Block,
	from:     game.Block, // Replace
	partial:  bool, // apply to the loaded part only (else: refuse unless all is loaded)
	// Paste: the template, turned rotation quarter turns, its corner at the
	// shape's (a Box of rotated_size).
	template: ^game.Template,
	rotation: u8,
}

Bulk_Result :: enum u8 {
	Done,
	Too_Big,
	Not_Loaded,
}

// bulk_edit applies e, by act; changed: how many blocks it changed,
// protected: how many more it skipped for being in a protected region.
bulk_edit :: proc(
	w: ^World,
	e: Bulk_Edit,
	act: Act,
) -> (
	changed: int,
	result: Bulk_Result,
	protected: int,
) {
	cause := act_current(w, act)
	lo, hi := shape_box(e.shape)
	lo.y, hi.y = max(lo.y, game.WORLD_MIN_Y), min(hi.y, game.WORLD_MAX_Y - 1)
	if lo.x > hi.x || lo.y > hi.y || lo.z > hi.z {return 0, .Done, 0}
	size := hi - lo + 1
	if i64(size.x) * i64(size.y) * i64(size.z) > MAX_BULK_VOLUME {return 0, .Too_Big, 0}
	clo, chi := game.chunk_of(lo), game.chunk_of(hi)
	if !e.partial {
		for cy in clo.y ..= chi.y {
			for cz in clo.z ..= chi.z {
				for cx in clo.x ..= chi.x {
					c := chunks_get(&w.chunks, {cx, cy, cz})
					if c == nil || c.state != .Ready {return 0, .Not_Loaded, 0}
				}
			}
		}
	}

	refused := admit_box(w, cause, lo, hi)
	mask, is_mask := e.shape.(voxel.Mask)
	for cy in clo.y ..= chi.y {
		for cz in clo.z ..= chi.z {
			for cx in clo.x ..= chi.x {
				pos := game.Chunk_Pos{cx, cy, cz}
				c := chunks_get(&w.chunks, pos)
				if c == nil || c.state != .Ready {continue}
				spans := mask_rows(mask, pos) if is_mask else box_rows(pos, lo, hi)
				n, skipped := edit_chunk(w, c, e, spans, cause, refused)
				protected += skipped
				if n > 0 {
					changed += n
					c.modified = true
					changes_chunk(w, pos)
				}
			}
		}
	}
	if changed == 0 {return 0, .Done, protected}
	walkers_changed(w, lo, hi)
	block_change_note(w, {area = {lo, hi}, bulk = true})

	sim_wake_box(w, lo, hi, cause.action)
	supports_check_box(w, lo, hi, cause.action)
	shapes_update_box(w, lo, hi, cause)
	for z in lo.z ..= hi.z {
		for x in lo.x ..= hi.x {
			if column_rescan(w, x, z, hi.y) {
				changes_column(w, {x >> game.CHUNK_SHIFT, z >> game.CHUNK_SHIFT})
			}
		}
	}
	return changed, .Done, protected
}

// Span: the cells lo, lo + {1, 0, 0} ... lo + {length - 1, 0, 0} of a row, within one chunk.
@(private = "file")
Span :: struct {
	lo:     game.Block_Pos,
	length: i32,
}

// box_rows: the rows of the part of chunk pos inside lo..hi, by y, then z (temp).
@(private = "file")
box_rows :: proc(pos: game.Chunk_Pos, lo, hi: game.Block_Pos) -> []Span {
	origin := game.chunk_origin(pos)
	from := [3]i32{max(lo.x, origin.x), max(lo.y, origin.y), max(lo.z, origin.z)}
	to := [3]i32 {
		min(hi.x, origin.x + game.CHUNK_SIZE - 1),
		min(hi.y, origin.y + game.CHUNK_SIZE - 1),
		min(hi.z, origin.z + game.CHUNK_SIZE - 1),
	}
	rows := make([dynamic]Span, 0, game.CHUNK_SIZE * game.CHUNK_SIZE, context.temp_allocator)
	for y in from.y ..= to.y {
		for z in from.z ..= to.z {append(&rows, Span{{from.x, y, z}, to.x - from.x + 1})}
	}
	return rows[:]
}

// mask_rows: the mask's runs within chunk pos (voxel.runs_next), by y, then z, then x, as
// box_rows gives a box's (temp).
@(private = "file")
mask_rows :: proc(m: voxel.Mask, pos: game.Chunk_Pos) -> []Span {
	origin := game.chunk_origin(pos)
	rows := make([dynamic]Span, context.temp_allocator)
	cursor := 0
	for lo, length in voxel.runs_next(m, &cursor, voxel.Bounds{origin, origin + game.CHUNK_SIZE}) {
		append(&rows, Span{lo, length})
	}
	return rows[:]
}

// edit_chunk applies e to the cells of spans, all in chunk c.
@(private = "file")
edit_chunk :: proc(
	w: ^World,
	c: ^Chunk,
	e: Bulk_Edit,
	spans: []Span,
	act: Act,
	refused: []Box, // protected boxes the actor may not edit
) -> (
	changed, protected: int,
) {
	origin := game.chunk_origin(c.pos)
	_, is_mask := e.shape.(voxel.Mask) // (a mask's spans are its cells)
	entries := make([dynamic]game.Journal_Entry, 0, 256, context.temp_allocator)
	defer journal_batch(w, act, entries[:])
	for span in spans {
		for x in span.lo.x ..< span.lo.x + span.length {
			p := game.Block_Pos{x, span.lo.y, span.lo.z}
			l := p - origin
			if !is_mask && !shape_has(e.shape, p) {continue}
			old := game.chunk_get(&c.blocks, l)
			if !game.can_change(&w.server.registry.blocks, old) {continue} 	// the world's floor stays
			new := old
			switch e.op {
			case .Set:
				new = e.block
			case .Replace:
				if old == e.from {new = e.block}
			case .Carve:
				new = .Air
			case .Paste:
				corner, _ := shape_box(e.shape)
				cell := game.template_cell(e.template, p - corner, e.rotation)
				if cell == game.VOID {continue}
				new = game.Block(cell)
			case .Unpaste:
				corner, _ := shape_box(e.shape)
				cell := game.template_cell(e.template, p - corner, e.rotation)
				if cell == game.VOID || game.Block(cell) != old {continue}
				new = .Air
			}
			if new == old {continue}
			if len(refused) > 0 {
				blocked := false
				for b in refused {if box_has(b, p) {blocked = true}}
				if blocked {
					protected += 1
					continue
				}
			}
			chunk_cow(&w.chunks, c)
			if err := game.chunk_set(&c.blocks, &w.chunks.arrays, l, new); err != nil {
				log.errorf("server bulk edit stopped chunk=%v error=%v", c.pos, err)
				return
			}
			if block_has_rules(&w.chunks, new) {c.restless = true}
			if block_has_random(&w.chunks, old) {c.random_blocks -= 1}
			if block_has_random(&w.chunks, new) {c.random_blocks += 1}
			channels_reset_cell(w, p, false)
			entity_lifecycle(w, p, old, new, act)
			append(&entries, game.Journal_Entry{pos = p, old = old, new = new})
			changed += 1
		}
	}
	return
}

// shape_box: the blocks a shape can touch.
shape_box :: proc(shape: Bulk_Shape) -> (lo, hi: game.Block_Pos) {
	switch v in shape {
	case Sphere:
		r := v.radius
		lo = {
			i32(math.floor(v.center.x - r)),
			i32(math.floor(v.center.y - r)),
			i32(math.floor(v.center.z - r)),
		}
		hi = {
			i32(math.floor(v.center.x + r)),
			i32(math.floor(v.center.y + r)),
			i32(math.floor(v.center.z + r)),
		}
	case Box:
		lo = {min(v.lo.x, v.hi.x), min(v.lo.y, v.hi.y), min(v.lo.z, v.hi.z)}
		hi = {max(v.lo.x, v.hi.x), max(v.lo.y, v.hi.y), max(v.lo.z, v.hi.z)}
	case voxel.Mask:
		lo, hi = v.bounds.lo, v.bounds.hi - 1 // (empty bounds: hi below lo)
	}
	return
}

// shape_has: the block at p is in the shape (a sphere holds the blocks
// whose centres are inside it).
shape_has :: proc(shape: Bulk_Shape, p: game.Block_Pos) -> bool {
	switch v in shape {
	case Sphere:
		d := [3]f64{f64(p.x) + 0.5, f64(p.y) + 0.5, f64(p.z) + 0.5} - v.center
		return d.x * d.x + d.y * d.y + d.z * d.z <= v.radius * v.radius
	case Box:
		lo, hi := shape_box(v)
		return(
			p.x >= lo.x &&
			p.x <= hi.x &&
			p.y >= lo.y &&
			p.y <= hi.y &&
			p.z >= lo.z &&
			p.z <= hi.z \
		)
	case voxel.Mask:
		return voxel.mask_get(v, p)
	}
	return false
}
