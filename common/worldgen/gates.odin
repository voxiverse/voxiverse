package worldgen

import "core:math"

import "common:game"

// Gates (M18): a ring standing on a platform, its 15 chevrons around it (the
// first 7 lit to dial a world in the galaxy; the other 8 dark until a gate
// can reach other galaxies). They are rare (a structure set), and none
// stands within Params.gate_distance of the world's middle: something to
// find late (`locate gate`). Travellers to a world arrive at its gate
// nearest the middle (arrival_gate). The server opens them
// (server/gates.odin): lit chevrons, and horizon blocks inside the ring.

GATE_SIZE :: [2]i32{11, 10} // across, up (the ring's plane), on a platform
GATE_DEPTH :: 3

// GATE_CHEVRONS: where each chevron is on the ring, in the plane (across,
// up from the platform), first at the top, then clockwise. Fixed cells
// (not computed: the same on every platform): a radius of 4.5 about (5,
// 4.5), its lowest row set in the platform (so one walks in level).
@(rodata)
GATE_CHEVRONS := [15][2]i32 {
	{5, 9},
	{7, 9},
	{8, 8},
	{9, 6},
	{9, 4},
	{9, 2},
	{8, 1},
	{6, 0},
	{4, 0},
	{2, 1},
	{1, 2},
	{1, 4},
	{1, 6},
	{2, 8},
	{3, 9},
}

@(private = "file")
GATE_CENTRE :: [2]f32{5, 4.5}
@(private = "file")
GATE_RADIUS :: 4.5

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

// gate_cell: the block at (u, v) of the ring's plane: ring, chevron k,
// inside the ring (the horizon, when open), or outside.
Gate_Cell :: enum u8 {
	Outside,
	Ring,
	Chevron,
	Inside,
}

gate_cell :: proc(u, v: i32) -> (Gate_Cell, int) {
	for c, k in GATE_CHEVRONS {if c == {u, v} {return .Chevron, k}}
	du, dv := f32(u) - GATE_CENTRE.x, f32(v) - GATE_CENTRE.y
	d := math.sqrt(du * du + dv * dv)
	switch {
	case d < GATE_RADIUS - 0.6:
		return .Inside, 0
	case d <= GATE_RADIUS + 0.6:
		return .Ring, 0
	}
	return .Outside, 0
}

// gate_block: what a gate piece puts at l: its platform, ring and dark
// chevrons; the rest of its box cleared.
gate_block :: proc(piece: ^Piece, l, size: [3]i32) -> (game.Block, int) {
	u, v, w := gate_plane(piece.rotation, l)
	cell := Gate_Cell.Outside
	if w == 1 {cell, _ = gate_cell(u, v)}
	switch cell {
	case .Ring:
		return .Gate_Ring, 1
	case .Chevron:
		return .Gate_Chevron, 1
	case .Inside, .Outside:
	}
	if v == 0 {return .Stone_Bricks, 1}
	return .Air, 2
}

// gate_at: a gate's block at (u, v) of its plane.
gate_at :: proc(s: Structure, u, v: i32) -> game.Block_Pos {
	if s.rotation & 1 == 1 {return s.lo + {1, v, u}}
	return s.lo + {u, v, 1}
}

// gate_chevrons: where s's chevrons are.
gate_chevrons :: proc(s: Structure) -> (out: [15]game.Block_Pos) {
	for c, k in GATE_CHEVRONS {out[k] = gate_at(s, c.x, c.y)}
	return
}

// gate_inside appends the cells inside s's ring (its horizon, when open).
gate_inside :: proc(s: Structure, out: ^[dynamic]game.Block_Pos) {
	for v in i32(1) ..< GATE_SIZE.y {
		for u in i32(0) ..< GATE_SIZE.x {
			if cell, _ := gate_cell(u, v); cell == .Inside {append(out, gate_at(s, u, v))}
		}
	}
}

// gate_front: where a traveller arriving through s stands (on the
// platform, on its +z side, or +x turned) and the yaw
// facing away from the ring.
gate_front :: proc(s: Structure) -> (position: [3]f64, yaw: f32) {
	centre := gate_at(s, 5, 1)
	if s.rotation & 1 == 1 {
		return {f64(centre.x) + 1.5, f64(centre.y), f64(centre.z) + 0.5}, -math.PI / 2 // facing +x
	}
	return {f64(centre.x) + 0.5, f64(centre.y), f64(centre.z) + 1.5}, math.PI // facing +z
}

// gate_containing: the gate a block of p belongs to (its ring, a chevron,
// its platform), if any.
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

// arrival_gate: the gate travellers to this world arrive at: the nearest
// its middle (none in a world without gates, or none found).
arrival_gate :: proc(gen: ^Generator) -> (s: Structure, ok: bool) {
	if gen.kind != .Earth || gen.params.gates == 0 {return}
	return locate_structure(gen, .Gate, 0, 0, ARRIVAL_SEARCH)
}
