package worldgen

import "core:math"

import "common:game"

// Gates: a heavy doorway of slabs standing on a platform, a tall narrow
// opening in it under a stepped head. They are rare (a structure set), and
// none stands within Params.gate_distance of the world's middle: something
// to find late (`locate gate`). A world may also have a home gate, standing
// a few blocks in front of its spawn (Params.home_gate: a new sandbox
// universe's home world; home_gate_place). Travellers to a world arrive at
// its home gate, or else at its gate nearest the middle (arrival_gate).
// The server opens them (server/core/gates.odin): horizon blocks fill the
// opening. Nothing on the frame lights.
//
// The box, the platform and the front are those of the ring gates the
// frame replaced, and the opening lies wholly inside the ring's: a world
// saved with the old ring still opens a horizon only where it had air.

GATE_SIZE :: [2]i32{11, 10} // across, up (the frame's plane), on a platform
GATE_DEPTH :: 3

// gate_size: the box of a gate turned rotation quarters (its plane along x
// for 0 and 2, along z for 1 and 3).
gate_size :: proc(rotation: u8) -> [3]i32 {
	if rotation & 1 == 1 {return {GATE_DEPTH, GATE_SIZE.y, GATE_SIZE.x}}
	return {GATE_SIZE.x, GATE_SIZE.y, GATE_DEPTH}
}

// gate_plane: (across, up, depth) of l (in the box).
@(private = "file")
gate_plane :: proc(rotation: u8, l: [3]i32) -> (u, v, w: i32) {
	if rotation & 1 == 1 {return l.z, l.y, l.x}
	return l.x, l.y, l.z
}

// gate_cell: the block at (u, v) of the frame's plane: the frame, the
// opening (the horizon, when open), or outside. The opening is three wide
// and seven high, one more cell in its head; the frame stands two thick
// round it (a slab's width each side, a lintel above), its top corners cut.
Gate_Cell :: enum u8 {
	Outside,
	Frame,
	Inside,
}

gate_cell :: proc(u, v: i32) -> Gate_Cell {
	switch {
	case u >= 4 && u <= 6 && v >= 1 && v <= 7, u == 5 && v == 8:
		return .Inside
	case u >= 2 && u <= 8 && v >= 1 && v <= 9 && !(v == 9 && (u == 2 || u == 8)):
		return .Frame
	}
	return .Outside
}

// gate_block: what a gate piece puts at l: its platform and frame; the
// rest of its box cleared.
gate_block :: proc(piece: ^Piece, l, size: [3]i32) -> (game.Block, int) {
	u, v, w := gate_plane(piece.rotation, l)
	if w == 1 && gate_cell(u, v) == .Frame {return .Gate_Ring, 1}
	if v == 0 {return .Stone_Bricks, 1}
	return .Air, 2
}

// gate_at: a gate's block at (u, v) of its plane.
gate_at :: proc(s: Structure, u, v: i32) -> game.Block_Pos {
	if s.rotation & 1 == 1 {return s.lo + {1, v, u}}
	return s.lo + {u, v, 1}
}

// gate_inside appends the cells of s's opening (its horizon, when open).
gate_inside :: proc(s: Structure, out: ^[dynamic]game.Block_Pos) {
	for v in i32(1) ..< GATE_SIZE.y {
		for u in i32(0) ..< GATE_SIZE.x {
			if gate_cell(u, v) == .Inside {append(out, gate_at(s, u, v))}
		}
	}
}

// gate_front: where a traveller arriving through s stands (on the
// platform, on its +z side, or +x turned) and the yaw
// facing away from the frame.
gate_front :: proc(s: Structure) -> (position: [3]f64, yaw: f32) {
	centre := gate_at(s, 5, 1)
	if s.rotation & 1 == 1 {
		return {f64(centre.x) + 1.5, f64(centre.y), f64(centre.z) + 0.5}, -math.PI / 2 // facing +x
	}
	return {f64(centre.x) + 0.5, f64(centre.y), f64(centre.z) + 1.5}, math.PI // facing +z
}

// gate_containing: the gate a block of p belongs to (its frame, its
// platform), if any.
gate_containing :: proc(gen: ^Generator, p: game.Block_Pos) -> (s: Structure, ok: bool) {
	found := make([dynamic]Structure, context.temp_allocator)
	structures_near(gen, {p.x, p.z}, {p.x, p.z}, &found)
	for f in found {
		if f.kind == .Gate &&
		   p.x >= f.lo.x &&
		   p.y >= f.lo.y &&
		   p.z >= f.lo.z &&
		   p.x <= f.hi.x &&
		   p.y <= f.hi.y &&
		   p.z <= f.hi.z {return f, true}
	}
	return
}

// ARRIVAL_SEARCH: how far from the world's middle arrival_gate looks.
ARRIVAL_SEARCH :: 16384

// arrival_gate: the gate travellers to this world arrive at: its home gate,
// else the nearest its middle (none in a world without gates, or none
// found).
arrival_gate :: proc(gen: ^Generator) -> (s: Structure, ok: bool) {
	if home, has_home := gen.home.?; has_home {return home, true}
	if gen.kind != .Earth || gen.params.gates == 0 {return}
	return locate_structure(gen, .Gate, 0, 0, ARRIVAL_SEARCH)
}

// HOME_GATE_STEPS: how far in front of the spawn the home gate's frame may
// stand (blocks along -z, where a newcomer looks: yaw 0), nearest first.
@(private = "file", rodata)
HOME_GATE_STEPS := [?]i32{8, 10, 12, 14, 16}

// home_gate_place: the home gate in front of spawn (where the generator
// put it, before the gate stood), facing it: the nearest of
// HOME_GATE_STEPS whose foot is on dry land without overhangs and whose box
// meets no other structure, else the nearest (its foundation and its
// cleared box make room). A pure function of the generator, like every
// structure.
home_gate_place :: proc(gen: ^Generator, spawn: [3]f64) -> Structure {
	p := &gen.params
	size := gate_size(0)
	x, z := i32(math.floor(spawn.x)), i32(math.floor(spawn.z))
	found := make([dynamic]Structure, context.temp_allocator)
	place :: proc(gen: ^Generator, x, z, step: i32, size: [3]i32) -> Structure {
		lo := [2]i32{x - size.x / 2, z - step - 1} // (its frame one block into its box)
		ground := column_at(&gen.params, gen.seed, x, lo.y + 1).height
		s := Structure {
			kind = .Gate,
			lo   = {lo.x, i32(math.floor(ground)), lo.y},
		}
		s.hi = s.lo + size - 1
		return s
	}
	steps: for step in HOME_GATE_STEPS {
		s := place(gen, x, z, step, size)
		for c in ([4][2]i32{{s.lo.x, s.lo.z}, {s.hi.x, s.lo.z}, {s.lo.x, s.hi.z}, {s.hi.x, s.hi.z}}) {
			col := column_at(p, gen.seed, c.x, c.y)
			if col.rough > 0 || col.height < f32(p.sea_level) + 2 {continue steps}
		}
		clear(&found)
		structures_near(gen, {s.lo.x, s.lo.z}, {s.hi.x, s.hi.z}, &found)
		if len(found) == 0 {return s}
	}
	return place(gen, x, z, HOME_GATE_STEPS[0], size)
}
