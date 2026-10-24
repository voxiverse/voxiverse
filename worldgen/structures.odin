package worldgen

import "base:runtime"
import "core:math"
import "core:sync"

import "../game"

// Structures in the world: a ruin and a well (templates shipped with the
// game, built in-game), towers and dungeons (procedural). Each kind has a
// set: the world is cut into square cells of its spacing, and each cell
// decides by a hash of its position whether it has one, where, and turned
// which way, so a structure's box is known before any of its chunks is
// made. A chunk writes every piece of every structure that reaches into
// it (after the land and plants, before trees, which keep clear); surface
// structures stand on flat land (no overhangs), on cobblestone foundations
// down to the ground. Where structures of two sets would overlap, the
// earlier set's stands.

Structure_Kind :: enum u8 {
	Tower,
	Ruin,
	Well,
	Dungeon,
}

STRUCTURE_NAMES := [Structure_Kind]string {
	.Tower   = "tower",
	.Ruin    = "ruin",
	.Well    = "well",
	.Dungeon = "dungeon",
}

@(private = "file")
Structure_Set :: struct {
	kind:    Structure_Kind,
	spacing: i32, // blocks: one cell
	chance:  f32, // that a cell has one
	biomes:  bit_set[Biome],
}

// LAND: biomes structures may stand in.
@(private = "file")
LAND :: bit_set[Biome]{.Plains, .Forest, .Taiga, .Tundra, .Desert, .Mountains}

@(private = "file", rodata)
SETS := [?]Structure_Set {
	{.Tower, 448, 0.55, {.Plains, .Forest, .Taiga, .Tundra}},
	{.Ruin, 288, 0.6, {.Plains, .Forest, .Taiga, .Desert}},
	{.Well, 352, 0.5, {.Plains, .Desert}},
	{.Dungeon, 224, 0.7, LAND},
}

// SINK: how far below the ground a kind's bottom is (a well's shaft).
@(private = "file", rodata)
SINK := [Structure_Kind]i32 {
	.Tower   = 0,
	.Ruin    = 0,
	.Well    = 4,
	.Dungeon = 0,
}

// MAX_STRUCTURE: no structure is wider than this (cells look this far).
MAX_STRUCTURE :: 48

Structure :: struct {
	kind:     Structure_Kind,
	lo, hi:   game.Block_Pos, // its box, inclusive
	rotation: u8,
	seed:     u32,
	top:      i32, // a dungeon's: the land at its stair shaft
}

Piece_Kind :: enum u8 {
	Template,
	Tower,
	Room,
	Corridor,
	Shaft, // a dungeon's way in: a spiral stair up to the land
}

Piece :: struct {
	kind:       Piece_Kind,
	lo, hi:     game.Block_Pos,
	template:   ^game.Template,
	rotation:   u8,
	foundation: bool, // cobblestone under its solid bottom, down to the ground
}

// structure_in_cell: the structure of set k in cell, if it has one.
@(private = "file")
structure_in_cell :: proc(gen: ^Generator, k: int, cell: [2]i32) -> (s: Structure, ok: bool) {
	set := SETS[k]
	p := &gen.params
	h := hash(gen.seed ~ i64(Earth_Layer.Structure) + i64(k), cell.x, cell.y)
	if chance(h) >= set.chance {return}
	h2 := hash(gen.seed ~ i64(Earth_Layer.Structure) + i64(k) + 100, cell.x, cell.y)
	room := set.spacing - MAX_STRUCTURE
	x := cell.x * set.spacing + i32(h2 % u32(room))
	z := cell.y * set.spacing + i32((h2 >> 16) % u32(room))
	s.kind, s.rotation, s.seed = set.kind, u8(h >> 4) & 3, h2
	size: [3]i32
	switch set.kind {
	case .Tower:
		size = {7, 13 + i32(h2 >> 8) % 12, 7}
	case .Ruin, .Well:
		t := shipped(set.kind) or_return
		size = game.rotated_size(t.size, s.rotation)
	case .Dungeon:
		size = {40, 7, 40}
	}
	// The land under it: its biome, and (on the surface) flat and dry.
	corners := [5][2]i32 {
		{x, z},
		{x + size.x - 1, z},
		{x, z + size.z - 1},
		{x + size.x - 1, z + size.z - 1},
		{x + size.x / 2, z + size.z / 2},
	}
	lowest := f32(math.F32_MAX)
	for c, i in corners {
		col := column_at(p, gen.seed, c.x, c.y)
		if i == 4 && col.biome not_in set.biomes {return}
		if set.kind != .Dungeon && col.rough > 0 {return}
		if col.height < f32(p.sea_level) + 2 {return}
		lowest = min(lowest, col.height)
	}
	ground := i32(math.floor(column_at(p, gen.seed, corners[4].x, corners[4].y).height))
	y := ground - SINK[set.kind]
	if set.kind == .Dungeon {y = i32(math.floor(lowest)) - 10 - size.y} 	// well under the surface
	s.lo = {x, y, z}
	s.hi = s.lo + size - 1
	if set.kind == .Dungeon {
		// Its stair shaft, in its first 5 x 5, up to the land (which must
		// have no overhangs there).
		shaft := column_at(p, gen.seed, x + 2, z + 2)
		if shaft.rough > 0 || shaft.height < f32(p.sea_level) + 2 {return}
		s.top = i32(math.floor(shaft.height))
		s.hi.y = max(s.hi.y, s.top + 1)
	}
	return s, true
}

// structures_near appends the structures whose boxes reach (x, z) lo..hi.
structures_near :: proc(gen: ^Generator, lo, hi: [2]i32, out: ^[dynamic]Structure) {
	if gen.kind != .Earth {return}
	for set, k in SETS {
		c0 := [2]i32 {
			floor_div(lo.x - MAX_STRUCTURE, set.spacing),
			floor_div(lo.y - MAX_STRUCTURE, set.spacing),
		}
		c1 := [2]i32{floor_div(hi.x, set.spacing), floor_div(hi.y, set.spacing)}
		for cz in c0.y ..= c1.y {
			for cx in c0.x ..= c1.x {
				s, ok := structure_in_cell(gen, k, {cx, cz})
				if !ok ||
				   s.hi.x < lo.x ||
				   s.lo.x > hi.x ||
				   s.hi.z < lo.y ||
				   s.lo.z > hi.y {continue}
				if !overlaps_earlier(gen, k, s) {append(out, s)}
			}
		}
	}
}

// overlaps_earlier: s (of set k) would overlap a structure of an earlier set.
@(private = "file")
overlaps_earlier :: proc(gen: ^Generator, k: int, s: Structure) -> bool {
	for j in 0 ..< k {
		set := SETS[j]
		c0 := [2]i32 {
			floor_div(s.lo.x - MAX_STRUCTURE, set.spacing),
			floor_div(s.lo.z - MAX_STRUCTURE, set.spacing),
		}
		c1 := [2]i32{floor_div(s.hi.x, set.spacing), floor_div(s.hi.z, set.spacing)}
		for cz in c0.y ..= c1.y {
			for cx in c0.x ..= c1.x {
				o, ok := structure_in_cell(gen, j, {cx, cz})
				if !ok {continue}
				if o.hi.x >= s.lo.x &&
				   o.lo.x <= s.hi.x &&
				   o.hi.y >= s.lo.y &&
				   o.lo.y <= s.hi.y &&
				   o.hi.z >= s.lo.z &&
				   o.lo.z <= s.hi.z {
					if !overlaps_earlier(gen, j, o) {return true}
				}
			}
		}
	}
	return false
}

// structure_pieces appends what s is made of.
structure_pieces :: proc(s: Structure, out: ^[dynamic]Piece) {
	switch s.kind {
	case .Tower:
		append(
			out,
			Piece{kind = .Tower, lo = s.lo, hi = s.hi, rotation = s.rotation, foundation = true},
		)
	case .Ruin, .Well:
		t, _ := shipped(s.kind)
		append(
			out,
			Piece {
				kind = .Template,
				lo = s.lo,
				hi = s.hi,
				template = t,
				rotation = s.rotation,
				foundation = true,
			},
		)
	case .Dungeon:
		dungeon_pieces(s, out)
	}
}

// dungeon_pieces: three to six rooms on one level, joined in turn by
// corridors (each an L: along x, then along z).
@(private = "file")
dungeon_pieces :: proc(s: Structure, out: ^[dynamic]Piece) {
	h := s.seed
	next :: proc(h: ^u32) -> u32 {
		h^ = (h^ ~ h^ >> 15) * 0x2c1b_3c6d
		h^ = (h^ ~ h^ >> 12) * 0x297a_2d39
		h^ ~= h^ >> 15
		return h^
	}
	// The way in, then rooms, each joined to the one before (the first to
	// the shaft's foot).
	append(out, Piece{kind = .Shaft, lo = s.lo, hi = {s.lo.x + 4, s.top + 1, s.lo.z + 4}})
	rooms := 3 + int(next(&h) % 4)
	prev := s.lo + {2, 0, 2}
	for _ in 0 ..< rooms {
		size := [3]i32{5 + i32(next(&h) % 5), 5 + i32(next(&h) % 2), 5 + i32(next(&h) % 5)}
		at := s.lo + {i32(next(&h) % u32(40 - size.x)), 0, i32(next(&h) % u32(40 - size.z))}
		append(out, Piece{kind = .Room, lo = at, hi = at + size - 1})
		middle := at + {size.x / 2, 0, size.z / 2}
		{
			// An L of corridors, three wide inside (five with walls).
			a, b := prev, middle
			append(
				out,
				Piece {
					kind = .Corridor,
					lo = {min(a.x, b.x) - 2, s.lo.y, a.z - 2},
					hi = {max(a.x, b.x) + 2, s.lo.y + 4, a.z + 2},
				},
			)
			append(
				out,
				Piece {
					kind = .Corridor,
					lo = {b.x - 2, s.lo.y, min(a.z, b.z) - 2},
					hi = {b.x + 2, s.lo.y + 4, max(a.z, b.z) + 2},
				},
			)
		}
		prev = middle
	}
}

// piece_block: what piece puts at p (inside its box), and how much it
// counts: 0 nothing (void), 1 a wall or a block, 2 an inside cleared (an
// inside wins over another piece's wall: corridors open into rooms), 3 a
// stair step (no corridor clears it).
piece_block :: proc(piece: ^Piece, p: game.Block_Pos) -> (b: game.Block, weight: int) {
	l := p - piece.lo
	size := piece.hi - piece.lo + 1
	edge := l.x == 0 || l.z == 0 || l.x == size.x - 1 || l.z == size.z - 1
	switch piece.kind {
	case .Template:
		cell := game.template_cell(piece.template, l, piece.rotation)
		if cell == game.VOID {return .Air, 0}
		return game.Block(cell), 1
	case .Room, .Corridor:
		wall: game.Block = .Cobblestone if piece.kind == .Room else .Stone_Bricks
		if l.y == 0 || l.y == size.y - 1 || edge {
			if piece.kind == .Room &&
			   l.y == size.y - 1 &&
			   l.x == size.x / 2 &&
			   l.z == size.z / 2 {return .Lamp, 1}
			return wall, 1
		}
		return .Air, 2
	case .Tower:
		return tower_block(piece, l, size)
	case .Shaft:
		return shaft_block(l, size)
	}
	return .Air, 0
}

// shaft_block: a 5 x 5 shaft of stone bricks round a cobblestone pillar,
// a step one higher every block round it (each a jump), corner posts on
// the land.
@(private = "file")
shaft_block :: proc(l, size: [3]i32) -> (game.Block, int) {
	RING :: [8][2]i32{{1, 1}, {2, 1}, {3, 1}, {3, 2}, {3, 3}, {2, 3}, {1, 3}, {1, 2}}
	top := size.y - 1
	edge := l.x == 0 || l.z == 0 || l.x == 4 || l.z == 4
	if l.y == top {
		// Above the land: posts at the corners, open between (a jump
		// from the last step).
		if (l.x == 0 || l.x == 4) && (l.z == 0 || l.z == 4) {return .Stone_Bricks, 1}
		return .Air, 2
	}
	if edge {return .Stone_Bricks, 1}
	if l.y == 0 {return .Cobblestone, 1}
	if l.y == top {return .Air, 2} 	// the opening, inside the rim
	if l.x == 2 && l.z == 2 {return .Cobblestone, 1}
	for r, i in RING {
		if l.x == r.x &&
		   l.z == r.y &&
		   (l.y - 1) % 8 == i32(i) &&
		   l.y < top - 1 {return .Cobblestone, 3}
	}
	return .Air, 2
}

// tower_block: a square tower of stone bricks: floors every six blocks
// (planks, a hole in a corner), a lamp under each, glass windows halfway
// up each storey, a door, battlements on top.
@(private = "file")
tower_block :: proc(piece: ^Piece, l, size: [3]i32) -> (game.Block, int) {
	top := size.y - 1
	edge := l.x == 0 || l.z == 0 || l.x == size.x - 1 || l.z == size.z - 1
	middle := size.x / 2
	if l.y == 0 {return .Cobblestone, 1}
	if l.y == top {
		if edge && (l.x + l.z) % 2 == 0 {return .Stone_Bricks, 1}
		return .Air, 2
	}
	if edge {
		// The door, on the side the rotation picks.
		door :=
			[4][2]i32{{middle, 0}, {size.x - 1, middle}, {middle, size.z - 1}, {0, middle}}[piece.rotation & 3]
		if l.y <= 2 && l.x == door.x && l.z == door.y {return .Air, 2}
		if l.y % 6 == 3 && (l.x == middle || l.z == middle) {return .Glass, 1}
		return .Stone_Bricks, 1
	}
	if l.y % 6 == 0 || l.y == top - 1 {
		if l.x == 1 && l.z == 1 && l.y != top - 1 {return .Air, 2} 	// a way up
		return .Planks, 1
	}
	if l.y % 6 == 5 && l.x == middle && l.z == middle {return .Lamp, 1}
	return .Air, 2
}

// pieces_in: the pieces of the structures reaching the chunk column at
// origin (x, z of its first block).
pieces_in :: proc(gen: ^Generator, origin: [2]i32, out: ^[dynamic]Piece) {
	structures := make([dynamic]Structure, context.temp_allocator)
	structures_near(gen, origin, origin + game.CHUNK_SIZE - 1, &structures)
	for s in structures {structure_pieces(s, out)}
}

// piece_at: the block the pieces put at p (the heaviest wins; ties: the
// first), if any.
piece_at :: proc(pieces: []Piece, p: game.Block_Pos) -> (b: game.Block, ok: bool) {
	best := 0
	for &piece in pieces {
		if p.x < piece.lo.x ||
		   p.y < piece.lo.y ||
		   p.z < piece.lo.z ||
		   p.x > piece.hi.x ||
		   p.y > piece.hi.y ||
		   p.z > piece.hi.z {continue}
		block, weight := piece_block(&piece, p)
		if weight > best {b, best = block, weight}
	}
	return b, best > 0
}

// near_piece: (x, z) is within margin blocks of a surface piece (trees
// keep away).
near_piece :: proc(pieces: []Piece, x, y, z: i32, margin: i32) -> bool {
	for piece in pieces {
		if piece.kind == .Room || piece.kind == .Corridor {continue}
		if x >= piece.lo.x - margin &&
		   x <= piece.hi.x + margin &&
		   z >= piece.lo.z - margin &&
		   z <= piece.hi.z + margin &&
		   y <= piece.hi.y + 2 {return true}
	}
	return false
}

// foundation_under: the pieces want a foundation under (x, z) from
// below their bottom; the y it starts below (false: none).
foundation_under :: proc(pieces: []Piece, x, z: i32) -> (bottom: i32, ok: bool) {
	for &piece in pieces {
		if !piece.foundation ||
		   x < piece.lo.x ||
		   z < piece.lo.z ||
		   x > piece.hi.x ||
		   z > piece.hi.z {continue}
		b, w := piece_block(&piece, {x, piece.lo.y, z})
		if w > 0 && game.block_collides(b) {return piece.lo.y, true}
	}
	return
}

// The shipped templates the sets use, decoded the first time any is
// needed (by whichever thread: Once).
@(private = "file")
templates: [Structure_Kind]Maybe(game.Template)
@(private = "file")
templates_once: sync.Once

@(private = "file")
shipped :: proc(kind: Structure_Kind) -> (^game.Template, bool) {
	sync.once_do(
		&templates_once,
		proc() {
			for kind in Structure_Kind {
				// Kept for good: on the heap, whichever thread asks first.
				t, ok := shipped_template(STRUCTURE_NAMES[kind], runtime.heap_allocator())
				if ok {templates[kind] = t}
			}
		},
	)
	if _, ok := templates[kind].?; !ok {return nil, false}
	return &templates[kind].?, true
}

structure_by_name :: proc(name: string) -> (Structure_Kind, bool) {
	for n, k in STRUCTURE_NAMES {if n == name {return k, true}}
	return {}, false
}

// locate_structure: the nearest structure of kind to (x, z) (ring by ring
// of 256 blocks, out to within), or false.
locate_structure :: proc(
	gen: ^Generator,
	kind: Structure_Kind,
	x, z: i32,
	within: i32 = 4096,
) -> (
	s: Structure,
	found: bool,
) {
	if gen.kind != .Earth {return}
	STEP :: 256
	found_list := make([dynamic]Structure, context.temp_allocator)
	for r in i32(0) ..= within / STEP {
		clear(&found_list)
		lo := [2]i32{x - r * STEP, z - r * STEP}
		structures_near(gen, lo, lo + 2 * r * STEP + STEP, &found_list)
		best := i64(max(i64))
		for c in found_list {
			if c.kind != kind {continue}
			d := [2]i64{i64(c.lo.x - x), i64(c.lo.z - z)}
			if d.x * d.x + d.y * d.y < best {s, best, found = c, d.x * d.x + d.y * d.y, true}
		}
		if found {return}
	}
	return
}
