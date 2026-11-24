package sandbox_server

import "core:log"
import "core:math"

import "common:base"
import "common:game"
import "common:worldgen"
import "server:core"

// How each gate world's place is drawn (beyond.odin places them): into a Draft (remains_
// build.odin's: a template over the place's footprint whose cells are void until drawn),
// in the place's own frame (Lay: u along it, v across, y up from its floor; turned by its
// quarter turns), of the class's own blocks and the kit's, then pasted in one bulk edit. A
// landmark stands on its ground levelled (the class's rock under, its ground on top); a site
// follows the land. Each holds a remains cache, a landmark a sealed relic vault too (the
// survival loop's finds: survival.odin, whose CLASS_LOOT they spill on a gate world), and
// the machine its drawing posts is set down (remains_machines.odin's remains_keep: none in a
// world whose creatures do not come by themselves).

// Lay: a place being drawn: its draft, its middle, its floor's layer, its turn, its seed and
// its class's blocks.
Lay :: struct {
	d:     ^Draft,
	mid:   [2]i32,
	floor: i32,
	turn:  u8,
	seed:  u64,
	cb:    worldgen.Class_Blocks,
	reg:   ^game.Registry,
}

// lay_at: the world column of the place's (u, v).
lay_at :: proc(l: ^Lay, u, v: i32) -> [2]i32 {
	switch l.turn & 3 {
	case 1:
		return l.mid + {-v, u}
	case 2:
		return l.mid + {-u, -v}
	case 3:
		return l.mid + {v, -u}
	}
	return l.mid + {u, v}
}

// lay_put: block at the place's (u, y, v), y up from its floor (0 is the floor's layer).
lay_put :: proc(l: ^Lay, u, y, v: i32, b: game.Block) {
	c := lay_at(l, u, v)
	draft_put(l.d, {c.x, l.floor + y, c.y}, b)
}

// lay_box: block over a box of the place's (corners inclusive, in any order).
lay_box :: proc(l: ^Lay, u0, y0, v0, u1, y1, v1: i32, b: game.Block) {
	for u in min(u0, u1) ..= max(u0, u1) {
		for v in min(v0, v1) ..= max(v0, v1) {
			for y in min(y0, y1) ..= max(y0, y1) {lay_put(l, u, y, v, b)}
		}
	}
}

// lay_ground: the land's top at the place's (u, v), up from its floor.
lay_ground :: proc(l: ^Lay, u, v: i32) -> i32 {
	c := lay_at(l, u, v)
	g, _ := draft_ground(l.d, c.x, c.y)
	return g - l.floor
}

// lay_roll: a number in [0, 1) of the place's seed and a cell of it (and a salt).
lay_roll :: proc(l: ^Lay, u, v: i32, salt: u64 = 0) -> f32 {
	return base.unit_f32(base.hash(l.seed, u64(u), u64(v), salt))
}

// lay_block: a block of the registry by id (Air: none; every one the places name is the
// base pack's or the sandbox's).
lay_block :: proc(l: ^Lay, id: string) -> game.Block {
	b, _ := game.registry_block(l.reg, id)
	return b
}

// beyond_build: one place of a gate world, drawn and pasted, its machines kept.
beyond_build :: proc(
	s: ^core.Server,
	w: ^core.World,
	class: worldgen.World_Class,
	p: Beyond_Place,
) {
	land := land_of(w)
	act := core.game_act(s, w, .Structure)
	area := beyond_area(class, p)
	d := draft_make(&land, p.at, area.lo.y, area.hi.y)
	l := Lay {
		d     = &d,
		mid   = p.middle,
		floor = p.floor,
		turn  = p.turn,
		seed  = p.seed,
		cb    = worldgen.class_blocks(s.registry, class),
		reg   = s.registry,
	}
	shape := beyond_shape(class, p.landmark)
	if p.landmark && class != .Ocean {lay_level(&l, shape.half, shape.below)}
	posts: [2]Beyond_Post
	n := 0
	switch class {
	case .None:
	case .Temperate:
		n = ring_draw(&l, &posts) if p.landmark else cairn_draw(&l)
	case .Canyon:
		n = dwelling_draw(&l) if p.landmark else well_draw(&l)
	case .Frozen:
		n = hall_draw(&l, &posts) if p.landmark else iced_cache_draw(&l)
	case .Ocean:
		n = platform_draw(&l) if p.landmark else hull_draw(&l)
	case .Volcanic:
		n = basalt_vault_draw(&l, &posts) if p.landmark else obelisk_draw(&l)
	case .Fungal:
		n = spore_tower_draw(&l) if p.landmark else shrine_draw(&l)
	case .Moon:
		n = relay_draw(&l, &posts) if p.landmark else probe_draw(&l, &posts)
	case .Jungle:
		n = station_draw(&l) if p.landmark else altar_draw(&l)
	}
	box := core.Box{d.origin, d.origin + d.t.size - 1}
	core.bulk_edit(w, {shape = box, op = .Paste, template = &d.t, partial = true}, act)
	for post in posts[:n] {
		c := lay_at(&l, post.u, post.v)
		remains_keep(s, w, post.which, {c.x, l.floor + post.y, c.y})
	}
	log.infof(
		"beyond built class=%v landmark=%v middle=%v finds=%d",
		class,
		p.landmark,
		p.middle,
		d.finds,
	)
}

// Beyond_Post: a machine a place keeps and its post, in the place's frame.
Beyond_Post :: struct {
	which:   Wild,
	u, y, v: i32,
}

// lay_level: the landmark's ground levelled at its floor over its footprint: everything over
// it cleared (to `above`... the draft's top), the land under it filled with the class's rock,
// its floor's layer the class's ground.
@(private = "file")
lay_level :: proc(l: ^Lay, half, below: i32) {
	ground := l.cb.remap[.Grass]
	top := l.d.origin.y + l.d.t.size.y - 1 - l.floor
	for u in -half ..= half {
		for v in -half ..= half {
			g := lay_ground(l, u, v)
			for y in min(g, 0) - below ..< 0 {lay_put(l, u, y, v, l.cb.stone)}
			lay_put(l, u, 0, v, ground)
			for y in 1 ..= top {lay_put(l, u, y, v, .Air)}
		}
	}
}

// lay_cache: a remains cache at the place's (u, y, v); lay_vault: a sealed relic vault.
@(private = "file")
lay_cache :: proc(l: ^Lay, u, y, v: i32) {
	lay_put(l, u, y, v, lay_block(l, "sandbox:remains_cache"))
	l.d.finds += 1
}
@(private = "file")
lay_vault :: proc(l: ^Lay, u, y, v: i32) {
	lay_put(l, u, y, v, lay_block(l, "sandbox:relic_vault"))
	l.d.finds += 1
}

// ---- the landmarks ----

// ring_draw: a temperate world's ring of twelve standing stones round a mossy dais whose
// plinth holds a relic vault under a crystal, a cache at a stone's foot, a mender over it.
@(private = "file")
ring_draw :: proc(l: ^Lay, posts: ^[2]Beyond_Post) -> int {
	stone := lay_block(l, "sandbox:slate_bricks")
	moss := lay_block(l, "sandbox:mossy_bricks")
	rune_stone := lay_block(l, "sandbox:rune_stone")
	polished := lay_block(l, "sandbox:polished_stone")
	crystal := lay_block(l, "sandbox:crystal")
	for u in i32(-3) ..= 3 {
		for v in i32(-3) ..= 3 {
			if u * u + v * v <=
			   10 {lay_put(l, u, 0, v, moss if lay_roll(l, u, v) < 0.5 else stone)}
		}
	}
	lay_box(l, -1, 1, -1, 1, 2, 1, polished)
	lay_vault(l, 0, 1, 0)
	lay_put(l, 0, 3, 0, crystal)
	first := f64(lay_roll(l, 0, 0, 7)) * math.TAU
	for i in 0 ..< 12 {
		a := first + f64(i) * math.TAU / 12
		u, v := i32(math.round(9 * base.cos(a))), i32(math.round(9 * base.sin(a)))
		height := 4 + i32(lay_roll(l, u, v, 1) * 4)
		if lay_roll(l, u, v, 2) < 0.15 {
			// Fallen: lying on the ground, pointing out.
			du, dv := i32(math.round(base.cos(a))), i32(math.round(base.sin(a)))
			for k in i32(0) ..< height - 1 {lay_put(l, u + du * k, 1, v + dv * k, stone)}
			continue
		}
		for y in 1 ..= height {lay_put(l, u, y, v, rune_stone if y == height else (moss if lay_roll(l, u, v, u64(y) + 3) < 0.3 else stone))}
		if i == 0 {
			du, dv :=
				i32(math.round(base.cos(a + math.PI))), i32(math.round(base.sin(a + math.PI)))
			lay_cache(l, u + du, 1, v + dv)
		}
	}
	posts[0] = {.Tender, 2, 1, 0}
	return 1
}

// dwelling_draw: a canyon's dwelling of sandstone in three stepped storeys, each a room with
// a doorway and windows, a stair up its side, a relic vault in the back of the lowest room
// and a cache in the highest.
@(private = "file")
dwelling_draw :: proc(l: ^Lay) -> int {
	bricks := lay_block(l, "sandbox:sandstone_bricks")
	tiles := lay_block(l, "sandbox:sandstone_tiles")
	red := lay_block(l, "voxiverse:red_rock")
	room :: proc(l: ^Lay, u0, v0, u1, v1, y0, y1: i32, wall, roof: game.Block) {
		for u in u0 ..= u1 {
			for v in v0 ..= v1 {
				edge := u == u0 || u == u1 || v == v0 || v == v1
				for y in y0 ..= y1 {lay_put(l, u, y, v, wall if edge else .Air)}
				lay_put(l, u, y1 + 1, v, roof)
			}
		}
		// A doorway on its front (low u), windows along its sides.
		mid := (v0 + v1) / 2
		lay_box(l, u0, y0, mid, u0, y0 + 1, mid, .Air)
		for u := u0 + 2; u < u1 - 1; u += 3 {
			lay_put(l, u, y0 + 1, v0, .Air)
			lay_put(l, u, y0 + 1, v1, .Air)
		}
	}
	room(l, -7, -7, 7, 7, 1, 3, bricks, tiles)
	room(l, -3, -6, 6, 3, 5, 7, bricks, tiles)
	room(l, 0, -5, 5, -1, 9, 11, bricks, tiles)
	// Bands of red rock in the walls, as the mesas have.
	for u in i32(-7) ..= 7 {
		lay_put(l, u, 2, -7, red)
		lay_put(l, u, 2, 7, red)
	}
	// The stair up the side: a step a block, to each roof.
	for k in i32(0) ..< 4 {lay_box(l, -6 + k, 1, 8, -6 + k, 1 + k, 8, bricks)}
	for k in i32(0) ..< 4 {lay_box(l, -2 + k, 5, 4, -2 + k, 5 + k, 4, bricks)}
	lay_vault(l, 6, 1, -6)
	lay_cache(l, 4, 9, -3)
	return 0
}

// hall_draw: a frozen world's long hall of slate under a pitched roof, half bound in packed
// ice, its door open at one end, a relic vault at the far end and a cache by a wall, a
// sentry folded inside the door.
@(private = "file")
hall_draw :: proc(l: ^Lay, posts: ^[2]Beyond_Post) -> int {
	bricks := lay_block(l, "sandbox:slate_bricks")
	roof := lay_block(l, "sandbox:slate_roof")
	ice := lay_block(l, "voxiverse:packed_ice")
	for u in i32(-8) ..= 8 {
		for v in i32(-4) ..= 4 {
			wall := u == -8 || u == 8 || v == -4 || v == 4
			for y in i32(1) ..= 5 {lay_put(l, u, y, v, bricks if wall else .Air)}
			lay_put(l, u, 0, v, bricks)
		}
		// The roof, stepping up to its ridge.
		for k in i32(0) ..= 4 {
			lay_put(l, u, 6 + k, -4 + k, roof)
			lay_put(l, u, 6 + k, 4 - k, roof)
		}
		lay_put(l, u, 10, 0, roof)
	}
	lay_box(l, -8, 1, -1, -8, 3, 1, .Air) // the door
	// The ice: drifts against its north side and over its roof, thick at the far end.
	for u in i32(-9) ..= 9 {
		for v in i32(-6) ..= 6 {
			if v > -4 && v < 4 && u > -9 && u < 9 {continue}
			depth := i32(lay_roll(l, u, v, 4) * 4) + (u + 9) / 5
			if v > 0 {depth /= 2}
			for y in 1 ..= depth {lay_put(l, u, y, v, ice)}
		}
	}
	for u in i32(-8) ..= 8 {
		if lay_roll(l, u, 0, 5) < 0.45 {lay_box(l, u, 9, -2, u, 10, 0, ice)}
	}
	lay_vault(l, 7, 1, 0)
	lay_cache(l, 3, 1, -3)
	posts[0] = {.Sentry, -6, 1, 0}
	return 1
}

// platform_draw: an ocean world's iron platform on legs in the shallows, half sunk (its deck
// slopes down into the sea at one end), with a cabin on its high end holding a relic vault and
// a cache, a rail round it.
@(private = "file")
platform_draw :: proc(l: ^Lay) -> int {
	riveted := lay_block(l, "sandbox:riveted_iron")
	plate := lay_block(l, "sandbox:iron_plate")
	rust := lay_block(l, "sandbox:rusted_iron")
	grating := lay_block(l, "sandbox:iron_grating")
	steel := lay_block(l, "sandbox:dark_steel")
	deck :: proc(u: i32) -> i32 {return 3 - (8 - u) / 3} 	// (3 at the high end, -2 at the low)
	for u in i32(-8) ..= 8 {
		for v in i32(-6) ..= 6 {
			y := deck(u)
			lay_put(l, u, y, v, rust if lay_roll(l, u, v) < 0.3 else plate)
			if (v == -6 || v == 6) && y >= 0 {lay_put(l, u, y + 1, v, grating)}
		}
	}
	for leg in ([4][2]i32{{-6, -5}, {-6, 5}, {6, -5}, {6, 5}}) {
		g := lay_ground(l, leg.x, leg.y)
		for y in g + 1 ..< deck(leg.x) {lay_put(l, leg.x, y, leg.y, riveted)}
	}
	// The cabin on the high end.
	for u in i32(3) ..= 7 {
		for v in i32(-3) ..= 3 {
			wall := u == 3 || u == 7 || v == -3 || v == 3
			for y in deck(u) + 1 ..= deck(u) + 3 {lay_put(l, u, y, v, steel if wall else .Air)}
			lay_put(l, u, deck(u) + 4, v, plate)
		}
	}
	lay_box(l, 3, deck(3) + 1, 0, 3, deck(3) + 2, 0, .Air)
	lay_vault(l, 6, deck(6) + 1, 2)
	lay_cache(l, 6, deck(6) + 1, -2)
	return 0
}

// basalt_vault_draw: a volcanic world's vault of polished basalt with obsidian corners, sealed
// by a dark steel door, ringed by a channel of magma crossed by one bridge; inside a relic
// vault and two caches; a sentry folded by the bridge.
@(private = "file")
basalt_vault_draw :: proc(l: ^Lay, posts: ^[2]Beyond_Post) -> int {
	polished := lay_block(l, "sandbox:polished_basalt")
	bricks := lay_block(l, "sandbox:basalt_bricks")
	obsidian := lay_block(l, "voxiverse:obsidian")
	steel := lay_block(l, "sandbox:dark_steel")
	magma := lay_block(l, "voxiverse:magma")
	for u in i32(-7) ..= 7 {
		for v in i32(-7) ..= 7 {
			ring := max(abs(u), abs(v))
			if ring == 6 && !(u == -6 && abs(v) <= 1) {lay_put(l, u, 0, v, magma)}
			if ring == 6 && u == -6 && abs(v) <= 1 {lay_put(l, u, 0, v, bricks)}
			if ring > 4 {continue}
			lay_put(l, u, 0, v, bricks)
			for y in i32(1) ..= 6 {lay_put(l, u, y, v, polished if ring == 4 else .Air)}
			lay_put(l, u, 7, v, polished)
		}
	}
	for c in ([4][2]i32{{-4, -4}, {-4, 4}, {4, -4}, {4, 4}}) {lay_box(l, c.x, 1, c.y, c.x, 9, c.y, obsidian)}
	lay_box(l, -4, 1, 0, -4, 2, 0, steel)
	lay_vault(l, 0, 1, 0)
	lay_cache(l, 2, 1, 2)
	lay_cache(l, 2, 1, -2)
	posts[0] = {.Sentry, -5, 1, 2}
	return 1
}

// spore_tower_draw: a fungal world's tower of mossy masonry, hollow, overgrown by giant fungi
// whose stems climb past it to caps above, glowing caps among them; a relic vault and a cache
// on its floor.
@(private = "file")
spore_tower_draw :: proc(l: ^Lay) -> int {
	moss := lay_block(l, "sandbox:mossy_bricks")
	stem := l.cb.parts[0]
	cap_block := l.cb.parts[1]
	glow := l.cb.parts[2]
	for u in i32(-3) ..= 3 {
		for v in i32(-3) ..= 3 {
			d := u * u + v * v
			if d > 12 {continue}
			lay_put(l, u, 0, v, moss)
			if d < 5 {continue}
			for y in i32(1) ..= 14 {
				b := moss
				if lay_roll(l, u, v, u64(y)) < 0.12 {b = .Air} 	// (crumbled)
				lay_put(l, u, y, v, b)
			}
		}
	}
	lay_box(l, -3, 1, 0, -3, 2, 0, .Air)
	// The fungi: three stems, each with its cap.
	stems := [3][3]i32{{3, 3, 20}, {-3, 4, 24}, {2, -4, 17}}
	for s in stems {
		for y in 1 ..= s.z {lay_put(l, s.x, y, s.y, stem)}
		for u in i32(-3) ..= 3 {
			for v in i32(-3) ..= 3 {
				if u * u + v * v > 9 {continue}
				lay_put(
					l,
					s.x + u,
					s.z + 1,
					s.y + v,
					glow if lay_roll(l, u + s.x, v + s.y, 9) < 0.15 else cap_block,
				)
			}
		}
	}
	lay_vault(l, 1, 1, 0)
	lay_cache(l, -1, 1, 1)
	return 0
}

// relay_draw: a moon's keepers' relay: a mast of dark steel on a concrete pad, a dish of
// grating near its top and a crystal at its tip, screens and vents round its foot, a relic
// vault in its housing and a cache; two sentries folded on the pad.
@(private = "file")
relay_draw :: proc(l: ^Lay, posts: ^[2]Beyond_Post) -> int {
	pad := lay_block(l, "sandbox:concrete_tiles")
	steel := lay_block(l, "sandbox:dark_steel")
	grating := lay_block(l, "sandbox:iron_grating")
	crystal := lay_block(l, "sandbox:crystal")
	screen := lay_block(l, "sandbox:screen")
	vent := lay_block(l, "sandbox:vent")
	for u in i32(-7) ..= 7 {
		for v in i32(-7) ..= 7 {lay_put(l, u, 0, v, pad)}
	}
	lay_box(l, -1, 1, -1, 1, 3, 1, steel) // the housing
	lay_vault(l, 0, 1, 0)
	lay_box(l, 0, 4, 0, 0, 15, 0, steel) // the mast
	lay_put(l, 0, 16, 0, crystal)
	for u in i32(-3) ..= 3 {
		for v in i32(-3) ..= 3 {
			d := u * u + v * v
			if d < 4 || d > 10 {continue}
			lay_put(l, u, 12 + i32(u > 0) + i32(u > 2), v, grating) // (the dish, tilted)
		}
	}
	// Struts from the pad to the mast.
	for k in i32(1) ..= 4 {
		lay_put(l, k, 5 - k, 0, steel)
		lay_put(l, -k, 5 - k, 0, steel)
	}
	lay_put(l, 3, 1, 3, screen)
	lay_put(l, 3, 1, -3, vent)
	lay_put(l, -3, 1, 3, vent)
	lay_put(l, -3, 1, -3, screen)
	lay_cache(l, 2, 1, 0)
	posts[0] = {.Sentry, 5, 1, 5}
	posts[1] = {.Sentry, -5, 1, -5}
	return 2
}

// station_draw: a jungle's station up in the canopy: a deck of planks on four log stilts
// fourteen blocks up, a thatched hut on it holding a relic vault and a cache, leaves over
// its rail, and a stair winding up round one stilt.
@(private = "file")
station_draw :: proc(l: ^Lay) -> int {
	log_block := lay_block(l, "sandbox:redwood_log")
	planks := lay_block(l, "sandbox:weathered_planks")
	panel := lay_block(l, "sandbox:weathered_panel")
	thatch := lay_block(l, "sandbox:thatch")
	leaves := lay_block(l, "sandbox:oak_leaves")
	DECK :: 15
	for c in ([5][2]i32{{-4, -4}, {-4, 4}, {4, -4}, {4, 4}, {6, 6}}) {lay_box(l, c.x, 1, c.y, c.x, DECK - 1, c.y, log_block)}
	for u in i32(-5) ..= 5 {
		for v in i32(-5) ..= 5 {
			lay_put(l, u, DECK, v, planks)
			if (abs(u) == 5 || abs(v) == 5) &&
			   lay_roll(l, u, v, 3) < 0.4 {lay_put(l, u, DECK + 1, v, leaves)}
		}
	}
	for u in i32(-2) ..= 2 {
		for v in i32(-2) ..= 2 {
			wall := abs(u) == 2 || abs(v) == 2
			for y in i32(DECK + 1) ..= DECK + 3 {lay_put(l, u, y, v, panel if wall else .Air)}
			lay_put(l, u, DECK + 4, v, thatch)
		}
	}
	lay_box(l, -2, DECK + 1, 0, -2, DECK + 2, 0, .Air)
	lay_vault(l, 1, DECK + 1, 1)
	lay_cache(l, 1, DECK + 1, -1)
	// The stair: a step a block, winding round a post off the deck's corner, up to it (its
	// last turn opens the corner of the deck).
	ring := [8][2]i32{{7, 6}, {7, 7}, {6, 7}, {5, 7}, {5, 6}, {5, 5}, {6, 5}, {7, 5}}
	for y in i32(1) ..< DECK {
		at := ring[y % 8]
		lay_put(l, at.x, y, at.y, planks)
		lay_box(l, at.x, y + 1, at.y, at.x, y + 3, at.y, .Air)
	}
	return 0
}

// ---- the sites ----

// cairn_draw: a temperate world's cairn of mossy stones with a cache in its heart and a
// standing stone beside it.
@(private = "file")
cairn_draw :: proc(l: ^Lay) -> int {
	cobble := lay_block(l, "sandbox:cobblestone")
	moss := lay_block(l, "sandbox:moss")
	stone := lay_block(l, "sandbox:slate_bricks")
	for u in i32(-2) ..= 2 {
		for v in i32(-2) ..= 2 {
			g := lay_ground(l, u, v)
			height := 3 - max(abs(u), abs(v))
			for y in 1 ..= height {lay_put(l, u, g + y, v, moss if lay_roll(l, u, v, u64(y)) < 0.35 else cobble)}
		}
	}
	lay_cache(l, 0, lay_ground(l, 0, 0) + 1, 0)
	g := lay_ground(l, 3, 2)
	lay_box(l, 3, g + 1, 2, 3, g + 4, 2, stone)
	return 0
}

// well_draw: a canyon's dry well: a square sandstone kerb round a shaft six blocks deep
// with a cache at its bottom, two posts and a beam over it.
@(private = "file")
well_draw :: proc(l: ^Lay) -> int {
	bricks := lay_block(l, "sandbox:sandstone_bricks")
	beam := lay_block(l, "sandbox:weathered_log")
	g := lay_ground(l, 0, 0)
	for u in i32(-2) ..= 2 {
		for v in i32(-2) ..= 2 {
			if abs(u) == 2 || abs(v) == 2 {
				lay_box(l, u, g - 6, v, u, g + 1, v, bricks)
			} else {
				lay_box(l, u, g - 5, v, u, g + 3, v, .Air)
				lay_put(l, u, g - 6, v, bricks)
			}
		}
	}
	lay_cache(l, 0, g - 5, 0)
	lay_box(l, -2, g + 2, 0, -2, g + 3, 0, beam)
	lay_box(l, 2, g + 2, 0, 2, g + 3, 0, beam)
	lay_box(l, -2, g + 4, 0, 2, g + 4, 0, beam)
	return 0
}

// iced_cache_draw: a frozen world's mound of packed ice with a cache frozen in its heart and
// a slate marker beside it.
@(private = "file")
iced_cache_draw :: proc(l: ^Lay) -> int {
	ice := lay_block(l, "voxiverse:packed_ice")
	slate := lay_block(l, "sandbox:slate_bricks")
	for u in i32(-3) ..= 3 {
		for v in i32(-3) ..= 3 {
			d := u * u + v * v
			if d > 10 {continue}
			g := lay_ground(l, u, v)
			height := i32(3 - d / 4)
			for y in 1 ..= height {lay_put(l, u, g + y, v, ice)}
		}
	}
	lay_cache(l, 0, lay_ground(l, 0, 0) + 1, 0)
	g := lay_ground(l, 4, 0)
	lay_box(l, 4, g + 1, 0, 4, g + 3, 0, slate)
	return 0
}

// hull_draw: an ocean world's hull of rusted iron beached on an island, broken open along
// one side, ribs showing, a cache in its belly.
@(private = "file")
hull_draw :: proc(l: ^Lay) -> int {
	rust := lay_block(l, "sandbox:rusted_iron")
	riveted := lay_block(l, "sandbox:riveted_iron")
	for u in i32(-5) ..= 5 {
		width := i32(3) - abs(u) / 3
		g := lay_ground(l, u, 0)
		for v in -width ..= width {
			lay_put(l, u, g + 1, v, riveted) // (its keel and bottom)
			if abs(v) == width {
				for y in g + 2 ..= g + 3 {
					if v > 0 && lay_roll(l, u, v, u64(y)) < 0.5 {continue} 	// (broken open)
					lay_put(l, u, y, v, rust)
				}
			}
		}
		if u % 3 == 0 {lay_put(l, u, g + 4, -width, rust)} 	// (a rib)
	}
	lay_cache(l, 0, lay_ground(l, 0, 0) + 2, 0)
	return 0
}

// obelisk_draw: a volcanic world's obelisk of obsidian on a basalt pad, a cache at its foot.
@(private = "file")
obelisk_draw :: proc(l: ^Lay) -> int {
	obsidian := lay_block(l, "voxiverse:obsidian")
	tiles := lay_block(l, "sandbox:basalt_tiles")
	crystal := lay_block(l, "sandbox:crystal")
	g := lay_ground(l, 0, 0)
	for u in i32(-2) ..= 2 {
		for v in i32(-2) ..= 2 {lay_put(l, u, g, v, tiles)}
	}
	lay_box(l, 0, g + 1, 0, 1, g + 6, 1, obsidian)
	lay_box(l, 0, g + 7, 0, 0, g + 8, 0, obsidian)
	lay_put(l, 1, g + 7, 1, crystal)
	lay_cache(l, -1, g + 1, 0)
	return 0
}

// shrine_draw: a fungal world's shrine: a dais of mossy bricks ringed by glowing caps on
// short stems, a cache on the dais.
@(private = "file")
shrine_draw :: proc(l: ^Lay) -> int {
	moss := lay_block(l, "sandbox:mossy_bricks")
	stem := l.cb.parts[0]
	glow := l.cb.parts[2]
	g := lay_ground(l, 0, 0)
	lay_box(l, -1, g + 1, -1, 1, g + 1, 1, moss)
	for i in 0 ..< 8 {
		a := f64(i) * math.TAU / 8
		u, v := i32(math.round(3 * base.cos(a))), i32(math.round(3 * base.sin(a)))
		gu := lay_ground(l, u, v)
		height := 1 + i32(lay_roll(l, u, v) * 2)
		lay_box(l, u, gu + 1, v, u, gu + height, v, stem)
		lay_put(l, u, gu + height + 1, v, glow)
	}
	lay_cache(l, 0, g + 2, 0)
	return 0
}

// probe_draw: a moon's fallen probe: a capsule of dark steel half sunk in the dust, tilted,
// its fins of grating, a cache inside, a sentry folded beside it.
@(private = "file")
probe_draw :: proc(l: ^Lay, posts: ^[2]Beyond_Post) -> int {
	steel := lay_block(l, "sandbox:dark_steel")
	grating := lay_block(l, "sandbox:iron_grating")
	g := lay_ground(l, 0, 0)
	for u in i32(-3) ..= 2 {
		lift := (u + 3) / 2 // (the capsule tilts up out of the dust)
		for v in i32(-1) ..= 1 {
			for y in i32(-1) ..= 1 {
				edge := abs(v) == 1 || abs(y) == 1 || u == -3 || u == 2
				lay_put(l, u, g + y + lift, v, steel if edge else .Air)
			}
		}
	}
	lay_put(l, 3, g + 3, 0, grating)
	lay_put(l, 2, g + 3, 2, grating)
	lay_put(l, 2, g + 3, -2, grating)
	lay_cache(l, 0, g + 1, 0)
	posts[0] = {.Sentry, -1, lay_ground(l, -1, 3) + 1, 3}
	return 1
}

// altar_draw: a jungle's overgrown altar: three steps of mossy bricks to a rune stone top, a
// cache on it, leaves spilling over it.
@(private = "file")
altar_draw :: proc(l: ^Lay) -> int {
	moss := lay_block(l, "sandbox:mossy_bricks")
	rune_stone := lay_block(l, "sandbox:rune_stone")
	leaves := lay_block(l, "sandbox:oak_leaves")
	g := lay_ground(l, 0, 0)
	for k in i32(0) ..< 3 {
		r := 3 - k
		lay_box(l, -r, g + 1 + k, -r, r, g + 1 + k, r, moss)
	}
	lay_put(l, 0, g + 4, 0, rune_stone)
	lay_cache(l, 1, g + 4, 0)
	for u in i32(-3) ..= 3 {
		for v in i32(-3) ..= 3 {
			if lay_roll(l, u, v, 6) <
			   0.2 {lay_put(l, u, g + 2 + i32(lay_roll(l, u, v, 7) * 2), v, leaves)}
		}
	}
	return 0
}
