package server

import "core:log"
import "core:math"

import "../game"

// Bulk edits: a shape (sphere, box) and an operation applied to every
// block in it, chunk by chunk, each touched column's top found again once;
// the touched chunks are sent whole at the end of the tick (changes.odin)
// instead of a message per block.

MAX_BULK_VOLUME :: 64 * 64 * 64 // blocks in the shape's box

Bulk_Shape :: union {
	Sphere,
	Box,
}

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
}

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

// bulk_edit applies e; changed: how many blocks it changed.
bulk_edit :: proc(w: ^World, e: Bulk_Edit) -> (changed: int, result: Bulk_Result) {
	lo, hi := shape_box(e.shape)
	lo.y, hi.y = max(lo.y, game.WORLD_MIN_Y), min(hi.y, game.WORLD_MAX_Y - 1)
	if lo.x > hi.x || lo.y > hi.y || lo.z > hi.z {return 0, .Done}
	size := hi - lo + 1
	if i64(size.x) * i64(size.y) * i64(size.z) > MAX_BULK_VOLUME {return 0, .Too_Big}
	clo, chi := game.chunk_of(lo), game.chunk_of(hi)
	if !e.partial {
		for cy in clo.y ..= chi.y {
			for cz in clo.z ..= chi.z {
				for cx in clo.x ..= chi.x {
					c := chunks_get(&w.chunks, {cx, cy, cz})
					if c == nil || c.state != .Ready {return 0, .Not_Loaded}
				}
			}
		}
	}

	for cy in clo.y ..= chi.y {
		for cz in clo.z ..= chi.z {
			for cx in clo.x ..= chi.x {
				pos := game.Chunk_Pos{cx, cy, cz}
				c := chunks_get(&w.chunks, pos)
				if c == nil || c.state != .Ready {continue}
				n := edit_chunk(w, c, e, lo, hi)
				if n > 0 {
					changed += n
					c.modified = true
					changes_chunk(w, pos)
				}
			}
		}
	}
	if changed == 0 {return 0, .Done}

	wake_water_box(w, lo, hi)
	for z in lo.z ..= hi.z {
		for x in lo.x ..= hi.x {
			if column_rescan(w, x, z, hi.y) {
				changes_column(w, {x >> game.CHUNK_SHIFT, z >> game.CHUNK_SHIFT})
			}
		}
	}
	return changed, .Done
}

// edit_chunk applies e to the part of chunk c inside lo..hi.
@(private = "file")
edit_chunk :: proc(w: ^World, c: ^Chunk, e: Bulk_Edit, lo, hi: game.Block_Pos) -> (changed: int) {
	origin := game.chunk_origin(c.pos)
	from := [3]i32{max(lo.x - origin.x, 0), max(lo.y - origin.y, 0), max(lo.z - origin.z, 0)}
	to := [3]i32 {
		min(hi.x - origin.x, game.CHUNK_SIZE - 1),
		min(hi.y - origin.y, game.CHUNK_SIZE - 1),
		min(hi.z - origin.z, game.CHUNK_SIZE - 1),
	}
	for y in from.y ..= to.y {
		for z in from.z ..= to.z {
			for x in from.x ..= to.x {
				l := [3]i32{x, y, z}
				p := origin + l
				if !shape_has(e.shape, p) {continue}
				old := game.chunk_get(&c.blocks, l)
				if !game.can_change(old) {continue} 	// the world's floor stays
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
				}
				if new == old {continue}
				if err := game.chunk_set(&c.blocks, &w.chunks.arrays, l, new); err != nil {
					log.errorf("server bulk edit stopped chunk=%v error=%v", c.pos, err)
					return
				}
				if _, water := game.water_level(new); water {c.water = true}
				changed += 1
			}
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
	}
	return false
}
