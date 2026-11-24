package sandbox_server

import "core:fmt"
import "core:log"

import "common:base"
import "common:game"
import "server:core"

// The camps' layouts (settlement.odin places them): each a template SETTLEMENT_SIDE square
// on a foundation, made of the base pack's and the sandbox's blocks, with what every camp
// has: shelters its people sleep in, a fire, lamps, a fabricator with its stores beside it,
// a market stall and a fence or a wall with gaps to walk through. Each layout says where
// its people stand by day and where they shelter at night or in the rain (Layout_Plan, by
// their slot: folk.odin), local columns on the floor.

Layout :: enum u8 {
	Ring_Camp, // tents and a thatched hut round a fire, a fence round them
	Walled_Yard, // two plank huts in a low stone wall
	Scrap_Hamlet, // iron shelters in a grating fence, a lamp mast
	Longhouse, // a long hall of logs and planks, a tent, a fence
}

FOLK_SLOTS :: 4 // the people of a camp (folk.odin: CAMP_ROLES)

// Layout_Plan: where a layout's people stand by day and shelter (slot by slot: the camp's
// own, its trader, its third, its guard), and its fabricator.
Layout_Plan :: struct {
	day:        [FOLK_SLOTS][2]i32,
	night:      [FOLK_SLOTS][2]i32,
	fabricator: [2]i32,
}

F :: SETTLEMENT_DEPTH // the floor's layer in a template
GATE :: [2]i32{SETTLEMENT_MID, 3} // where a guard stands: inside the north gap

@(rodata)
LAYOUT_PLANS := [Layout]Layout_Plan {
	.Ring_Camp = {
		day = {{11, 14}, {6, 18}, {13, 17}, GATE},
		night = {{5, 5}, {18, 6}, {18, 16}, GATE},
		fabricator = {14, 19},
	},
	.Walled_Yard = {
		day = {{10, 13}, {5, 18}, {17, 16}, GATE},
		night = {{6, 5}, {18, 5}, {19, 5}, GATE},
		fabricator = {17, 18},
	},
	.Scrap_Hamlet = {
		day = {{10, 12}, {5, 19}, {16, 9}, GATE},
		night = {{5, 5}, {17, 17}, {5, 6}, GATE},
		fabricator = {17, 7},
	},
	.Longhouse = {
		day = {{10, 15}, {5, 19}, {17, 16}, GATE},
		night = {{6, 6}, {8, 6}, {12, 6}, GATE},
		fabricator = {17, 18},
	},
}

layout_of :: proc(l: Layout) -> Layout_Plan {return LAYOUT_PLANS[l]}

// Camp_Kit: what the camps are built of, in this session's registry.
Camp_Kit :: struct {
	cobblestone, stone_bricks, planks, fence, slab, lamp, chest: game.Block,
	gravel, magma, thatch, clay_roof, slate_roof:                game.Block,
	oak_log, oak_planks, weathered_planks, glass:                game.Block,
	rusted_iron, riveted_iron, iron_plate, grating, dark_steel:  game.Block,
	wool:                                                        [4]game.Block, // red, blue, green, yellow
	fabricator, dry_earth:                                       game.Block,
}

// camp_kit_start: the camps' blocks from the session's registry (the game's start).
camp_kit_start :: proc(s: ^core.Server) -> bool {
	k := &state(s).camp_kit
	reg := s.registry
	block :: proc(reg: ^game.Registry, name: string) -> (game.Block, bool) {
		return game.registry_block(reg, name)
	}
	ours :: proc(reg: ^game.Registry, name: string) -> (game.Block, bool) {
		return game.registry_block(reg, fmt.tprintf("sandbox:%s", name))
	}
	k.cobblestone = block(reg, "cobblestone") or_return
	k.stone_bricks = block(reg, "stone_bricks") or_return
	k.planks = block(reg, "planks") or_return
	k.fence = block(reg, "planks_fence") or_return
	k.slab = block(reg, "planks_slab") or_return
	k.lamp = block(reg, "lamp") or_return
	k.chest = block(reg, "chest") or_return
	k.gravel = block(reg, "gravel") or_return
	k.magma = ours(reg, "magma") or_return
	k.thatch = ours(reg, "thatch") or_return
	k.clay_roof = ours(reg, "clay_roof") or_return
	k.slate_roof = ours(reg, "slate_roof") or_return
	k.oak_log = ours(reg, "oak_log") or_return
	k.oak_planks = ours(reg, "oak_planks") or_return
	k.weathered_planks = ours(reg, "weathered_planks") or_return
	k.glass = block(reg, "glass") or_return
	k.rusted_iron = ours(reg, "rusted_iron") or_return
	k.riveted_iron = ours(reg, "riveted_iron") or_return
	k.iron_plate = ours(reg, "iron_plate") or_return
	k.grating = ours(reg, "iron_grating") or_return
	k.dark_steel = ours(reg, "dark_steel") or_return
	for name, i in ([4]string{"red_wool", "blue_wool", "green_wool", "yellow_wool"}) {
		k.wool[i] = ours(reg, name) or_return
	}
	k.fabricator = ours(reg, "fabricator") or_return
	k.dry_earth = ours(reg, "dry_earth") or_return
	return true
}

// settlement_build: a camp, whole, over whatever stood there, on its levelled ground.
settlement_build :: proc(s: ^core.Server, w: ^core.World, st: ^Settlement) {
	t := camp_template(&state(s).camp_kit, st)
	act := core.game_act(s, w, .Structure)
	site_level(w, settlement_area(st), st.site.floor, act)
	o := st.site.origin
	box := core.Box{o, o + {SETTLEMENT_SIDE, SETTLEMENT_HEIGHT, SETTLEMENT_SIDE} - 1}
	core.bulk_edit(w, {shape = box, op = .Paste, template = &t, partial = true}, act)
	log.infof("settlement %s built at %v", settlement_name(st), o)
}

// camp_template: a camp's blocks (temp memory), the same for its seed every time: a
// foundation, a floor of grass worn to earth and gravel, and its layout.
camp_template :: proc(k: ^Camp_Kit, st: ^Settlement) -> game.Template {
	S :: SETTLEMENT_SIDE
	t := game.template_make({S, SETTLEMENT_HEIGHT, S}, context.temp_allocator)
	rng := base.rng_make(st.seed)
	game.template_fill(&t, {0, 0, 0}, {S - 1, F - 1, S - 1}, k.cobblestone)
	game.template_fill(&t, {0, F, 0}, {S - 1, F, S - 1}, .Grass)
	// The floor is grass but where feet wore it.
	for _ in 0 ..< 30 {
		x, z := base.rng_roll(&rng, i32(2), S - 3), base.rng_roll(&rng, i32(2), S - 3)
		cell(&t, {x, F, z}, k.dry_earth if base.rng_int_max(&rng, 2) == 0 else k.gravel)
	}
	game.template_fill(&t, {SETTLEMENT_MID - 1, F, 1}, {SETTLEMENT_MID + 1, F, S - 2}, k.gravel) // (the path)
	wool := base.rng_int_max(&rng, len(k.wool))
	switch st.layout {
	case .Ring_Camp:
		ring(&t, k.fence, 1, 1)
		hut(&t, k, {3, 3}, {6, 5}, .South, k.weathered_planks, k.oak_log, k.thatch)
		tent(&t, {18, 5}, 4, k.wool[wool])
		tent(&t, {18, 15}, 4, k.wool[(wool + 1) % len(k.wool)])
		fire(&t, k, {12, 12})
		stall(&t, k, {4, 17}, k.wool[(wool + 2) % len(k.wool)])
		for p in ([4][2]i32{{9, 9}, {15, 9}, {9, 15}, {15, 15}}) {lamp_post(&t, k, p)}
	case .Walled_Yard:
		ring(&t, k.cobblestone, 1, 2)
		hut(&t, k, {3, 3}, {7, 5}, .South, k.planks, k.oak_log, k.clay_roof)
		hut(&t, k, {15, 3}, {7, 5}, .South, k.planks, k.oak_log, k.clay_roof)
		fire(&t, k, {12, 13})
		stall(&t, k, {4, 17}, k.wool[wool])
		for p in ([2][2]i32{{4, 11}, {20, 11}}) {lamp_post(&t, k, p)}
	case .Scrap_Hamlet:
		ring(&t, k.grating, 1, 1)
		hut(&t, k, {3, 3}, {6, 6}, .East, k.rusted_iron, k.dark_steel, k.iron_plate)
		hut(&t, k, {15, 15}, {6, 6}, .West, k.riveted_iron, k.dark_steel, k.iron_plate)
		game.template_fill(&t, {19, F + 1, 5}, {19, F + 5, 5}, k.dark_steel) // (the mast)
		cell(&t, {19, F + 6, 5}, k.lamp)
		fire(&t, k, {12, 12})
		stall(&t, k, {4, 18}, k.wool[wool])
		lamp_post(&t, k, {9, 17})
	case .Longhouse:
		ring(&t, k.fence, 1, 1)
		hut(&t, k, {4, 4}, {11, 6}, .South, k.oak_planks, k.oak_log, k.slate_roof)
		tent(&t, {19, 4}, 4, k.wool[wool])
		fire(&t, k, {12, 15})
		stall(&t, k, {4, 18}, k.wool[(wool + 1) % len(k.wool)])
		for p in ([2][2]i32{{8, 13}, {16, 13}}) {lamp_post(&t, k, p)}
	}
	// The fabricator and its stores (no camp's people mind a player using them).
	fab := layout_of(st.layout).fabricator
	cell(&t, {fab.x, F + 1, fab.y}, k.fabricator)
	cell(&t, {fab.x + 1, F + 1, fab.y}, k.chest)
	cell(&t, {fab.x + 2, F + 1, fab.y}, k.chest)
	return t
}

@(private = "file")
cell :: proc(t: ^game.Template, p: [3]i32, b: game.Block) {game.template_fill(t, p, p, b)}

// ring: a fence or a wall round the square, inset from its edge, height blocks high, with a
// gap three wide in the middle of each side.
@(private = "file")
ring :: proc(t: ^game.Template, b: game.Block, inset, height: i32) {
	lo, hi := inset, SETTLEMENT_SIDE - 1 - inset
	for k in lo ..= hi {
		if abs(k - SETTLEMENT_MID) <= 1 {continue}
		for p in ([4][2]i32{{k, lo}, {k, hi}, {lo, k}, {hi, k}}) {
			game.template_fill(t, {p.x, F + 1, p.y}, {p.x, F + height, p.y}, b)
		}
	}
}

Side :: enum u8 {
	North,
	South,
	West,
	East,
}

// hut: a shelter of size (outside) at lo: walls three high of wall with corner posts, a
// doorway two high in the middle of one side, a window each side of it, a lamp inside and a
// roof over all, overhanging by one.
@(private = "file")
hut :: proc(
	t: ^game.Template,
	k: ^Camp_Kit,
	lo, size: [2]i32,
	door: Side,
	wall, corner, roof: game.Block,
) {
	hi := lo + size - 1
	for z in lo.y ..= hi.y {
		for x in lo.x ..= hi.x {
			if x != lo.x && x != hi.x && z != lo.y && z != hi.y {continue}
			edge := (x == lo.x || x == hi.x) && (z == lo.y || z == hi.y)
			game.template_fill(t, {x, F + 1, z}, {x, F + 3, z}, corner if edge else wall)
		}
	}
	mid := (lo + hi) / 2
	gap: [2]i32
	switch door {
	case .North:
		gap = {mid.x, lo.y}
	case .South:
		gap = {mid.x, hi.y}
	case .West:
		gap = {lo.x, mid.y}
	case .East:
		gap = {hi.x, mid.y}
	}
	game.template_fill(t, {gap.x, F + 1, gap.y}, {gap.x, F + 2, gap.y}, .Air)
	// Windows in the sides along the door's, and a lamp in the back wall's middle.
	if door == .North || door == .South {
		cell(t, {lo.x, F + 2, mid.y}, k.glass)
		cell(t, {hi.x, F + 2, mid.y}, k.glass)
		cell(t, {mid.x, F + 3, lo.y if door == .South else hi.y}, k.lamp)
	} else {
		cell(t, {mid.x, F + 2, lo.y}, k.glass)
		cell(t, {mid.x, F + 2, hi.y}, k.glass)
		cell(t, {hi.x if door == .West else lo.x, F + 3, mid.y}, k.lamp)
	}
	game.template_fill(t, {lo.x - 1, F + 4, lo.y - 1}, {hi.x + 1, F + 4, hi.y + 1}, roof)
}

// tent: a ridge tent of wool, length blocks long from at (its middle column) along z, closed
// at its back (north) and open at the front: inside, a column two high to stand in.
@(private = "file")
tent :: proc(t: ^game.Template, at: [2]i32, length: i32, wool: game.Block) {
	for z in at.y ..< at.y + length {
		for d in ([2]i32{-2, 2}) {cell(t, {at.x + d, F + 1, z}, wool)}
		for d in ([2]i32{-1, 1}) {cell(t, {at.x + d, F + 2, z}, wool)}
		cell(t, {at.x, F + 3, z}, wool)
	}
	game.template_fill(t, {at.x - 1, F + 1, at.y - 1}, {at.x + 1, F + 1, at.y - 1}, wool)
	cell(t, {at.x, F + 2, at.y - 1}, wool)
}

// fire: a ring of stones round embers set in the floor, which glow.
@(private = "file")
fire :: proc(t: ^game.Template, k: ^Camp_Kit, at: [2]i32) {
	cell(t, {at.x, F, at.y}, k.magma)
	for d in ([4][2]i32{{-1, 0}, {1, 0}, {0, -1}, {0, 1}}) {
		cell(t, {at.x + d.x, F + 1, at.y + d.y}, k.slab)
	}
}

// stall: a market stall at lo (its counter's west end): a counter three long, posts at its
// ends and an awning of wool over it.
@(private = "file")
stall :: proc(t: ^game.Template, k: ^Camp_Kit, lo: [2]i32, wool: game.Block) {
	game.template_fill(t, {lo.x, F + 1, lo.y}, {lo.x + 2, F + 1, lo.y}, k.slab)
	cell(t, {lo.x - 1, F + 1, lo.y}, k.fence)
	cell(t, {lo.x - 1, F + 2, lo.y}, k.fence)
	cell(t, {lo.x + 3, F + 1, lo.y}, k.fence)
	cell(t, {lo.x + 3, F + 2, lo.y}, k.fence)
	game.template_fill(t, {lo.x - 1, F + 3, lo.y}, {lo.x + 3, F + 3, lo.y + 1}, wool)
	cell(t, {lo.x + 1, F + 2, lo.y}, k.chest) // (wares on the counter)
}

// lamp_post: a post two high with a lamp on it.
@(private = "file")
lamp_post :: proc(t: ^game.Template, k: ^Camp_Kit, at: [2]i32) {
	game.template_fill(t, {at.x, F + 1, at.y}, {at.x, F + 2, at.y}, k.fence)
	cell(t, {at.x, F + 3, at.y}, k.lamp)
}
