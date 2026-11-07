package worldgen

import "core:math"

import "common:game"

// Trees and plants. Trees are placed per chunk column from a hash of its
// position (where they stand comes from the land's smooth height: they
// grow only where there are no overhangs), so any chunk can work out the
// trees of its neighbours and write the parts that reach into it.

Tree_Kind :: enum u8 {
	Oak,
	Spruce,
	Cactus,
	Acacia, // flat-topped: the savanna's tree
	Shrub, // a leaf blob on a 1-block stem
	Evergreen_Shrub, // the same in spruce blocks
}

Tree :: struct {
	ground: game.Block_Pos, // the block it stands on
	kind:   Tree_Kind,
	height: i32, // of its trunk
}

// TREE_TRIES: chances per chunk column, by biome (each taken with
// TREE_ODDS times the tree density).
@(private = "file", rodata)
TREE_TRIES := #partial [Biome]i32 {
	.Plains             = 3,
	.Forest             = 12,
	.Taiga              = 10,
	.Tundra             = 3,
	.Mountains          = 4,
	.Desert             = 4,
	// The planet's biomes (Tundra and Desert there grow shrubs: see `place_trees`).
	.Rainforest         = 12,
	.Subtropical_Forest = 12,
	.Mixed_Forest       = 12,
	.Savanna            = 4,
	.Steppe             = 2,
	.Mediterranean      = 5,
	.Cold_Desert        = 2,
}
@(private)
MOST_TREE_TRIES :: 12 // TREE_TRIES' largest

@(private = "file", rodata)
TREE_ODDS := #partial [Biome]f32 {
	.Plains             = 0.2,
	.Forest             = 0.7,
	.Taiga              = 0.6,
	.Tundra             = 0.25,
	.Mountains          = 0.3,
	.Desert             = 0.35,
	.Rainforest         = 0.9,
	.Subtropical_Forest = 0.7,
	.Mixed_Forest       = 0.7,
	.Savanna            = 0.3,
	.Steppe             = 0.2,
	.Mediterranean      = 0.3,
	.Cold_Desert        = 0.3,
}

// OAK_LAND: biomes whose grass grows oaks.
@(private = "file")
OAK_LAND :: bit_set[Biome] {
	.Plains,
	.Forest,
	.Rainforest,
	.Savanna,
	.Steppe,
	.Mediterranean,
	.Subtropical_Forest,
	.Mixed_Forest,
}

// place_trees appends the trees of a chunk column.
place_trees :: proc(gen: ^Generator, column: [2]i32, out: ^[dynamic]Tree) {
	p := &gen.params
	if p.tree_density <= 0 {return}
	origin := column * game.CHUNK_SIZE
	// Blending: every chunk column tries as often as a forest's, and each
	// tree keeps itself by its own ground's biome (so densities blend at
	// borders instead of changing at chunk lines). Before blending (old
	// worlds): the column's middle sets how many tries.
	blend := p.biome_blend > 0
	tries := i32(MOST_TREE_TRIES)
	if !blend {tries = TREE_TRIES[column_at(p, gen.seed, origin.x + 8, origin.y + 8).biome]}
	pieces := make([dynamic]Piece, context.temp_allocator)
	if tries > 0 {pieces_in(gen, origin, &pieces)}
	for k in 0 ..< tries {
		h := hash(gen.seed ~ i64(Earth_Layer.Tree), column.x, column.y, k)
		x, z := origin.x + i32(h & 15), origin.y + i32(h >> 4 & 15)
		c := column_at(p, gen.seed, x, z)
		odds := TREE_ODDS[c.biome] * p.tree_density
		if blend {odds *= f32(TREE_TRIES[c.biome]) / MOST_TREE_TRIES}
		if p.planet != 0 && c.biome == .Desert {odds *= 0.25} 	// rare shrubs
		if chance(hash(gen.seed ~ i64(Earth_Layer.Tree) + 1, x, z)) >= odds {continue}
		if c.rough > 0 {continue}
		ground := i32(math.floor(c.height))
		if ground <= p.sea_level {continue}
		if near_piece(pieces[:], x, ground, z, 3) {continue} 	// clear of structures
		top := surface_block(p, c.biome, 0, ground)
		size := i32(h >> 12 & 3)
		if p.planet != 0 {
			planet_vegetation(c.biome, top, {x, ground, z}, size, h, out)
			continue
		}
		switch {
		case c.biome == .Desert && top == .Sand:
			append(out, Tree{{x, ground, z}, .Cactus, 1 + size % 3})
		case top == .Grass && c.biome in OAK_LAND:
			append(out, Tree{{x, ground, z}, .Oak, 4 + size % 3})
		case top == .Grass || top == .Snow:
			append(out, Tree{{x, ground, z}, .Spruce, 6 + size})
		}
	}
}

// planet_vegetation appends the plant of planet world biome b standing on `top`
// (if it grows one there).
@(private = "file")
planet_vegetation :: proc(
	b: Biome,
	top: game.Block,
	ground: game.Block_Pos,
	size: i32,
	h: u32,
	out: ^[dynamic]Tree,
) {
	grows := top == .Grass || top == .Sand || top == .Gravel || top == .Snow || top == .Dirt
	t: Tree
	switch b {
	case .Rainforest:
		if top != .Grass {return}
		t = {
			kind   = .Oak,
			height = 8 + size,
		} // tall broadleaf
	case .Savanna:
		if top != .Grass {return}
		t = {
			kind   = .Acacia,
			height = 4 + size % 2,
		}
	case .Subtropical_Forest, .Forest:
		if top != .Grass {return}
		t = {
			kind   = .Oak,
			height = 4 + size % 3,
		}
	case .Mixed_Forest:
		if top != .Grass {return}
		if h >> 14 & 3 == 0 {
			t = {
				kind   = .Spruce,
				height = 6 + size,
			}
		} else {
			t = {
				kind   = .Oak,
				height = 4 + size % 3,
			}
		}
	case .Mediterranean:
		if top != .Grass {return}
		if h >> 14 & 3 == 0 {
			t = {
				kind   = .Oak,
				height = 4 + size % 2,
			}
		} else {
			t = {
				kind   = .Evergreen_Shrub,
				height = 1,
			}
		}
	case .Steppe, .Cold_Desert, .Desert:
		if !grows {return}
		t = {
			kind   = .Shrub,
			height = 1,
		}
	case .Tundra:
		if !grows {return}
		t = {
			kind   = .Evergreen_Shrub,
			height = 1,
		} // dwarf shrubs, no trees
	case .Taiga:
		if top != .Grass && top != .Snow {return}
		t = {
			kind   = .Spruce,
			height = 6 + size,
		}
	case .Plains, .Mountains:
		if top == .Grass {
			t =
				{kind = .Oak, height = 4 + size % 3} if b == .Plains else {kind = .Spruce, height = 6 + size}
		} else if top == .Snow {
			t = {
				kind   = .Spruce,
				height = 6 + size,
			}
		} else {
			return
		}
	case .Ocean, .Frozen_Ocean, .Beach, .River, .Ice_Sheet:
		return
	}
	t.ground = ground
	append(out, t)
}

// Put: where a tree's blocks go (a chunk's array, or the column tops).
Put :: proc(data: rawptr, p: game.Block_Pos, b: game.Block)

// tree_write writes the parts of t inside the chunk at origin: trunks over
// anything but the land, leaves only into air (and over plants).
tree_write :: proc(seed: i64, t: Tree, origin: game.Block_Pos, dst: ^game.Block_Array) {
	Chunk :: struct {
		origin: game.Block_Pos,
		dst:    ^game.Block_Array,
	}
	chunk := Chunk{origin, dst}
	tree_shape(seed, t, &chunk, proc(data: rawptr, p: game.Block_Pos, b: game.Block) {
		c := (^Chunk)(data)
		l := p - c.origin
		if l.x < 0 ||
		   l.y < 0 ||
		   l.z < 0 ||
		   l.x >= game.CHUNK_SIZE ||
		   l.y >= game.CHUNK_SIZE ||
		   l.z >= game.CHUNK_SIZE {return}
		i := game.local_index(l)
		current := c.dst[i]
		ok :=
			current == .Air || current == .Tall_Grass || current == .Poppy || current == .Dandelion
		if b == .Log ||
		   b == .Spruce_Log ||
		   b == .Cactus {ok ||= current == .Leaves || current == .Spruce_Leaves}
		if ok {c.dst[i] = b}
	})
}

// tree_shape gives every block of t to put.
tree_shape :: proc(seed: i64, t: Tree, data: rawptr, put: Put) {
	g := t.ground
	switch t.kind {
	case .Cactus:
		for y in 1 ..= t.height {put(data, g + {0, y, 0}, .Cactus)}
	case .Acacia:
		// A bare trunk under a wide flat canopy.
		top := g.y + t.height
		for y in top ..= top + 1 {
			r: i32 = 3 if y == top else 1
			for dz in -r ..= r {
				for dx in -r ..= r {
					if abs(dx) + abs(dz) > r + 1 {continue} 	// rounded corners
					put(data, {g.x + dx, y, g.z + dz}, .Leaves)
				}
			}
		}
		for y in 1 ..= t.height {put(data, g + {0, y, 0}, .Log)}
	case .Shrub:
		put(data, g + {0, 1, 0}, .Log)
		shrub_leaves(g, .Leaves, put, data)
	case .Evergreen_Shrub:
		put(data, g + {0, 1, 0}, .Spruce_Log)
		shrub_leaves(g, .Spruce_Leaves, put, data)
	case .Oak:
		// A rounded crown: two wide layers, two narrow, corners ragged.
		top := g.y + t.height
		for y in top - 2 ..= top + 1 {
			r: i32 = 2 if y < top else 1
			for dz in -r ..= r {
				for dx in -r ..= r {
					corner := abs(dx) == r && abs(dz) == r
					if corner &&
					   (y == top + 1 || chance(hash(seed, g.x + dx, y, g.z + dz)) < 0.5) {continue}
					put(data, {g.x + dx, y, g.z + dz}, .Leaves)
				}
			}
		}
		for y in 1 ..= t.height {put(data, g + {0, y, 0}, .Log)}
	case .Spruce:
		// Tiers narrowing to a point: a single leaf on top, then rings
		// of radius 1 and 2 by turns, the lowest widest.
		top := g.y + t.height
		for y in g.y + 3 ..= top + 1 {
			from_top := top + 1 - y
			r: i32
			switch {
			case from_top == 0:
				r = 0
			case from_top < 3, from_top % 2 == 0:
				r = 1
			case:
				r = 2 if from_top < 7 else 3
			}
			for dz in -r ..= r {
				for dx in -r ..= r {
					if abs(dx) + abs(dz) > r {continue} 	// a diamond: corners cut
					put(data, {g.x + dx, y, g.z + dz}, .Spruce_Leaves)
				}
			}
		}
		for y in 1 ..= t.height {put(data, g + {0, y, 0}, .Spruce_Log)}
	}
}

// shrub_leaves: the leaf blob of a shrub (a plus on the stem's level, one on top).
@(private = "file")
shrub_leaves :: proc(g: game.Block_Pos, leaves: game.Block, put: Put, data: rawptr) {
	for d in ([4][2]i32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
		put(data, {g.x + d.x, g.y + 1, g.z + d.y}, leaves)
	}
	put(data, g + {0, 2, 0}, leaves)
}

// plant: tall grass or a flower on a grassy top (the block above it, if in
// this chunk and empty).
plant :: proc(
	p: ^Params,
	seed: i64,
	c: ^Column,
	origin: game.Block_Pos,
	dst: ^game.Block_Array,
	x, top, z: i32,
) {
	y := top + 1 - origin.y
	if y < 0 || y >= game.CHUNK_SIZE || p.plant_density <= 0 {return}
	if surface_block(p, c.biome, 0, top) != .Grass {return}
	if top - origin.y >= 0 && dst[game.local_index({x, top - origin.y, z})] != .Grass {return} 	// a cave mouth
	grass, flowers: f32
	#partial switch c.biome {
	case .Plains:
		grass, flowers = 0.3, 0.04
	case .Forest:
		grass, flowers = 0.18, 0.03
	case .Taiga, .Mountains:
		grass = 0.08
	case .Rainforest:
		grass, flowers = 0.4, 0.02
	case .Subtropical_Forest:
		grass, flowers = 0.32, 0.03
	case .Mixed_Forest:
		grass, flowers = 0.26, 0.03
	case .Savanna:
		grass, flowers = 0.2, 0.01
	case .Steppe:
		grass, flowers = 0.12, 0.01
	case .Mediterranean:
		grass, flowers = 0.06, 0.04
	}
	r := chance(hash(seed ~ i64(Earth_Layer.Plant), origin.x + x, origin.z + z)) / p.plant_density
	b: game.Block
	switch {
	case r < flowers:
		b = .Poppy if r < flowers / 2 else .Dandelion
	case r < flowers + grass:
		b = .Tall_Grass
	case:
		return
	}
	i := game.local_index({x, y, z})
	if dst[i] == .Air {dst[i] = b}
}
