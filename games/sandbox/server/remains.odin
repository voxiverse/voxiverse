package sandbox_server

import "core:fmt"
import "core:log"
import "core:math"
import "core:strconv"
import "core:strings"

import "common:base"
import "common:game"
import "common:worldgen"
import "server:core"

// The remains round the home gate: what is left of whoever stood the gate there, so that a
// new world's first minutes have things to see and walk to, and nothing says what they were.
// Everything is placed from the world's seed alone (remains_plan), round the home gate (the
// generator's, which stays as it is, dead):
//
// - the court (Court): the gate's own ground, a worn platform a step up from the land, with
//   steps down (or up) to the land round it, a broken parapet, copper conduits in its floor
//   running to the gate from four pylons (one or two still standing, the others broken and
//   their pieces lying about), standing stones round it, moss and grass through its tiles;
// - the old road (Road): stretches of a paved road with kerbs and posts, leaving the court
//   toward the ruin (ruin.odin) and broken off between, so one who follows it comes there;
// - scattered REMAINS_NEAR to REMAINS_FAR blocks from the gate, each kind once and a few
//   more: a fallen pylon beside its stump (Pylon), a wall half buried with a doorway (Wall),
//   a round tower fallen in on one side, a remains cache inside one in two (Tower), a grassed
//   mound over a sealed chamber holding a relic vault (Vault), a ring of standing stones
//   round a dead plinth (Stones). Each is drawn from its own seed (remains_build.odin): its
//   size, its way, its breaks, what grows on it, and the survival loop's finds (survival.odin:
//   salvage heaps in its rubble, now and then an alloy relic).
//
// Every site stands on dry land that is not too uneven for its kind (site_ground), clear of
// the court, the ruin, the generator's structures and the others. A site is built once, in
// one paste, when a player is near it and its ground is loaded (the court as the first player
// arrives); from then on it is the world's like any block (players may dig it and break its
// finds open: survival.odin's remains_spill), and the world's file (REMAINS_FILE) remembers which are built. A world
// saved before there were remains gets none: nothing is built over what its players made.
// Each built site but the road's is marked for the watchers, and as it is built it sets down
// the machine it keeps, if any (remains_machines.odin: sentries asleep at the vaults and the
// towers with a cache, menders at the rings of stones, the pylons and behind the gate, no
// sentry near the spawn). A player who comes near a built site has it in its logbook
// (remains_noted), so the journal, the compass and the map show it.

MAX_REMAINS :: 32 // sites a world plans, the court and the road's stretches too
REMAINS_NEAR :: 60 // blocks from the gate's middle to a scattered site's middle, at the least
REMAINS_FAR :: 380 // ... at the most
REMAINS_EXTRA :: 5 // scattered sites besides one of each kind, at the most (4 at the least)
REMAINS_TRIES :: 96 // spots tried for each scattered site before it is left out (each third
// lets the land be 2 more uneven than its kind asks)
REMAINS_APART :: 40 // blocks between two scattered sites' footprints, at the least
REMAINS_CLEAR :: 12 // blocks between a site and the court, the ruin's apron or a structure
REMAINS_REACH :: 192 // a player this near a site's middle has it built once its ground is loaded
REMAINS_EVERY :: 15 // ticks between two looks at what is to be built
REMAINS_NOTED :: 32 // a player this near a built site's middle has it in its logbook
ROAD_GAP :: [2]i32{12, 36} // blocks between two stretches of the road, at the least and the most
ROAD_SHORTEST :: 8 // a stretch's length, at the least
ROAD_LONGEST :: 16 // ... and the most
ROAD_DRY :: 0.6 // of a stretch's line on dry ground, at the least (where the water took the rest)

Remain_Kind :: enum u8 {
	Court,
	Road,
	Pylon,
	Wall,
	Tower,
	Vault,
	Stones,
}

// Remain_Shape: what a kind asks of the land under it (the most it may rise and fall, as
// site_ground samples it over remain_stand), how far it reaches from its middle (its measure
// added: a radius's kinds), and how far it stands over and under the land.
Remain_Shape :: struct {
	spread: i32,
	reach:  i32,
	above:  i32,
	below:  i32,
}

@(rodata)
REMAIN_SHAPES := [Remain_Kind]Remain_Shape {
	.Court = {spread = 0, reach = COURT_REACH, above = COURT_CLEAR + 2, below = 6},
	.Road = {spread = 12, reach = 3, above = 4, below = 2},
	.Pylon = {spread = 7, reach = 3, above = 9, below = 2},
	.Wall = {spread = 7, reach = 3, above = 7, below = 2},
	.Tower = {spread = 5, reach = 8, above = 14, below = 2},
	.Vault = {spread = 5, reach = 1, above = 9, below = 3},
	.Stones = {spread = 5, reach = 3, above = 7, below = 2},
}

// Remain: one site of the remains: its kind, the columns it covers and its middle, the land
// under it (site_ground: its middle height, what a level part stands on, and its lowest and
// highest), its way (a road's, toward the ruin; a pylon's fall; where a tower fell in; a
// vault's door), its measure (a road's, a pylon's or a wall's length; a tower's, a mound's or
// a ring's radius) and the seed of the rest.
Remain :: struct {
	kind:   Remain_Kind,
	at:     Footprint,
	middle: [2]i32,
	floor:  i32,
	lo, hi: i32,
	along:  [2]f64,
	size:   i32,
	seed:   u64,
}

// Remains: the home world's remains (its world state's): its plan, which sites are built, and
// whether it is a world from before them.
Remains :: struct {
	sites:       [MAX_REMAINS]Remain,
	count:       int,
	planned:     bool,
	built:       [MAX_REMAINS][2]i32, // the middles of the sites built (its file's, and since)
	built_count: int,
	before:      bool, // saved before there were remains: none is built in it
	dirty:       bool, // changed since its file was staged
}

// Remains_Kit: what the remains are built of and the finds they hold (the survival loop's
// blocks: survival.odin), in this session's registry.
Remains_Kit :: struct {
	slate_tiles, polished_slate, slate, slate_bricks: game.Block,
	basalt_bricks, polished_basalt, basalt_cobble:    game.Block,
	limestone, polished_limestone:                    game.Block,
	mossy_bricks, moss, leaves:                       game.Block,
	steel, rust, copper, grating, riveted:            game.Block,
	salvage_heap, alloy_relic:                        game.Block, // (survival.odin's finds)
	remains_cache, relic_vault:                       game.Block,
}

// remains_start: the names the remains use, from the session's registry (the game's start).
remains_start :: proc(s: ^core.Server) -> bool {
	k := &state(s).remains_kit
	reg := s.registry
	block :: proc(reg: ^game.Registry, name: string) -> (game.Block, bool) {
		return game.registry_block(reg, fmt.tprintf("sandbox:%s", name))
	}
	k.slate_tiles = block(reg, "slate_tiles") or_return
	k.polished_slate = block(reg, "polished_slate") or_return
	k.slate = block(reg, "slate") or_return
	k.slate_bricks = block(reg, "slate_bricks") or_return
	k.basalt_bricks = block(reg, "basalt_bricks") or_return
	k.polished_basalt = block(reg, "polished_basalt") or_return
	k.basalt_cobble = block(reg, "basalt_cobble") or_return
	k.limestone = block(reg, "limestone") or_return
	k.polished_limestone = block(reg, "polished_limestone") or_return
	k.mossy_bricks = block(reg, "mossy_bricks") or_return
	k.moss = block(reg, "moss") or_return
	k.leaves = block(reg, "oak_leaves") or_return
	k.steel = block(reg, "dark_steel") or_return
	k.rust = block(reg, "rusted_iron") or_return
	k.copper = block(reg, "verdigris_copper") or_return
	k.grating = block(reg, "iron_grating") or_return
	k.riveted = block(reg, "riveted_iron") or_return
	k.salvage_heap = block(reg, "salvage_heap") or_return
	k.alloy_relic = block(reg, "alloy_relic") or_return
	k.remains_cache = block(reg, "remains_cache") or_return
	k.relic_vault = block(reg, "relic_vault") or_return
	return true
}

// remains_tick: the home world's remains planned once its ruin is placed (ruin_tick runs
// first), and each site built when a player is near it and its ground is loaded.
remains_tick :: proc(s: ^core.Server) {
	w := s.home
	rm := &world_of(w).remains
	r := ruin_of(s)
	if rm.before || !r.placed {return}
	if !rm.planned {
		gen := worldgen.generator_make(w.generator, terrain_seed(w), s.registry, w.params)
		land := land_of(w)
		remains_plan(rm, &land, &gen, w.seed, ruin_footprint(r.site))
		rm.planned = true
		log.infof("remains planned: %d sites, %d built", rm.count, rm.built_count)
		for site in rm.sites[:rm.count] {
			log.infof(
				"remains site kind=%v middle=%v floor=%d",
				site.kind,
				site.middle,
				site.floor,
			)
			if remains_built(rm, site) {remains_site(s, site)}
		}
	}
	if s.tick % REMAINS_EVERY != 0 {return}
	for &site in rm.sites[:rm.count] {
		if remains_built(rm, site) {
			remains_noted(s, w, site)
			continue
		}
		near := false
		for &c in s.clients {
			if c.state != .Playing || c.world != w {continue}
			d := c.player.position.xz - {f64(site.middle.x) + 0.5, f64(site.middle.y) + 0.5}
			near ||= d.x * d.x + d.y * d.y <= REMAINS_REACH * REMAINS_REACH
		}
		if !near || !core.world_ready(w, remain_area(site)) {continue}
		remains_build(s, w, site)
		remains_site(s, site)
		rm.built[rm.built_count] = site.middle
		rm.built_count += 1
		rm.dirty = true
	}
}

// REMAIN_NAMES: what a site is called in a player's logbook (its journal, compass and map).
@(rodata)
REMAIN_NAMES := [Remain_Kind]string {
	.Court  = "Gate court",
	.Road   = "",
	.Pylon  = "Fallen pylon",
	.Wall   = "Buried wall",
	.Tower  = "Fallen tower",
	.Vault  = "Sealed vault",
	.Stones = "Standing stones",
}

// remains_noted: a built site, but the road's, in the logbook of each player in w within
// REMAINS_NOTED blocks of its middle (across).
remains_noted :: proc(s: ^core.Server, w: ^core.World, site: Remain) {
	if site.kind == .Road {return}
	at := [3]i32{site.middle.x, site.floor + 1, site.middle.y}
	for &c in s.clients {
		if c.state != .Playing || c.world != w {continue}
		d := c.player.position.xz - {f64(site.middle.x) + 0.5, f64(site.middle.y) + 0.5}
		if d.x * d.x + d.y * d.y > REMAINS_NOTED * REMAINS_NOTED {continue}
		core.logbook_place(s, &c, .Remains, at, REMAIN_NAMES[site.kind])
	}
}

// remains_built: the site is built in this world.
remains_built :: proc(rm: ^Remains, site: Remain) -> bool {
	for m in rm.built[:rm.built_count] {if m == site.middle {return true}}
	return false
}

// remain_area: the site's whole box, from under its land to over what it builds: what must be
// loaded for it to be built.
remain_area :: proc(site: Remain) -> core.Box {
	shape := REMAIN_SHAPES[site.kind]
	return {
		{site.at.lo.x, min(site.lo, site.floor) - shape.below, site.at.lo.y},
		{site.at.hi.x, max(site.hi, site.floor) + shape.above, site.at.hi.y},
	}
}

// ruin_footprint: the columns of the ruin and its apron.
ruin_footprint :: proc(site: Site) -> Footprint {
	a := ruin_area(site)
	return {{a.lo.x, a.lo.z}, {a.hi.x, a.hi.z}}
}

// remains_plan: the world's remains, from its seed alone (the universe's, seed; the land's,
// l's), round its home gate (gen's; none without one), clear of its ruin's footprint: the
// court, the road's stretches toward the ruin, then one scattered site of each kind in an
// order of the seed's and REMAINS_EXTRA or one fewer of kinds the seed picks (a vault at most
// twice), each at the first of REMAINS_TRIES spots that suits it, or left out.
remains_plan :: proc(
	rm: ^Remains,
	l: ^Land,
	gen: ^worldgen.Generator,
	seed: i64,
	ruin: Footprint,
) {
	rm.count = 0
	gate, has_gate := gen.home.?
	if !has_gate {return}
	rng := base.rng_make(u64(seed) ~ 0x2e3a_11c5)
	court := court_of(l, gate)
	court.along, _ = remains_way(court.middle, ruin)
	court.seed = base.rng_u64(&rng)
	remains_add(rm, court)
	remains_road(rm, l, gen, &rng, court.middle, ruin)
	kinds := [?]Remain_Kind{.Pylon, .Wall, .Tower, .Vault, .Stones}
	for i := len(kinds) - 1; i > 0; i -= 1 {
		j := base.rng_int_max(&rng, i + 1)
		kinds[i], kinds[j] = kinds[j], kinds[i]
	}
	extra := [?]Remain_Kind{.Pylon, .Wall, .Tower, .Stones, .Pylon, .Wall, .Stones, .Vault}
	n := len(kinds) + base.rng_roll(&rng, REMAINS_EXTRA - 1, REMAINS_EXTRA)
	for i in 0 ..< n {
		kind := kinds[i] if i < len(kinds) else extra[base.rng_int_max(&rng, len(extra))]
		remains_scatter(rm, l, gen, &rng, kind, court.middle, ruin)
	}
}

@(private = "file")
remains_add :: proc(rm: ^Remains, site: Remain) -> bool {
	if rm.count == MAX_REMAINS {return false}
	rm.sites[rm.count] = site
	rm.count += 1
	return true
}

// remains_way: the way from column `from` to the ruin's middle (a unit vector), and how far.
@(private = "file")
remains_way :: proc(from: [2]i32, ruin: Footprint) -> (way: [2]f64, distance: f64) {
	to := (ruin.lo + ruin.hi) / 2
	way = {f64(to.x - from.x), f64(to.y - from.y)}
	distance = math.sqrt(way.x * way.x + way.y * way.y)
	if distance > 0 {way /= distance}
	return
}

// remains_road: the road's stretches from the court toward the ruin's middle, ROAD_SHORTEST to
// ROAD_LONGEST long
// with ROAD_GAP between, from out of the court's footprint to short of the ruin's apron; a
// stretch whose line is mostly wet or steep, or that meets a structure, is gone.
@(private = "file")
remains_road :: proc(
	rm: ^Remains,
	l: ^Land,
	gen: ^worldgen.Generator,
	rng: ^base.Rng,
	from: [2]i32,
	ruin: Footprint,
) {
	way, distance := remains_way(from, ruin)
	if distance < 1 {return}
	t := f64(COURT_REACH + 1) / max(abs(way.x), abs(way.y)) // (out of the court's footprint)
	end := distance - f64(RUIN_MID + RUIN_APRON + REMAINS_CLEAR)
	start := [2]f64{f64(from.x) + 0.5, f64(from.y) + 0.5}
	for t < end {
		length := f64(base.rng_roll(rng, i32(ROAD_SHORTEST), ROAD_LONGEST))
		gap := f64(base.rng_roll(rng, ROAD_GAP[0], ROAD_GAP[1]))
		site_seed := base.rng_u64(rng)
		length = min(length, end - t)
		if length < ROAD_SHORTEST / 2 {break}
		a, b := start + way * t, start + way * (t + length)
		t += length + gap
		site := Remain {
			kind  = .Road,
			along = way,
			size  = i32(length),
			seed  = site_seed,
		}
		mid := (a + b) / 2
		site.middle = {i32(math.floor(mid.x)), i32(math.floor(mid.y))}
		reach := REMAIN_SHAPES[.Road].reach
		site.at = {
			{i32(math.floor(min(a.x, b.x))) - reach, i32(math.floor(min(a.y, b.y))) - reach},
			{i32(math.floor(max(a.x, b.x))) + reach, i32(math.floor(max(a.y, b.y))) + reach},
		}
		heights: [ROAD_LONGEST + 1]i32
		count, dry := 0, 0
		site.lo, site.hi = max(i32), min(i32)
		for s := 0.0; s <= length; s += 1 {
			p := a + way * s
			top, here := land_at(l, i32(math.floor(p.x)), i32(math.floor(p.y)))
			heights[count] = top
			count += 1
			if here {dry += 1}
			site.lo, site.hi = min(site.lo, top), max(site.hi, top)
		}
		site.floor = heights[count / 2]
		if f64(dry) < ROAD_DRY * f64(count) || site.hi - site.lo > REMAIN_SHAPES[.Road].spread {
			continue
		}
		if !remains_clear(rm, gen, site, ruin) {continue}
		remains_add(rm, site)
	}
}

// remains_scatter: one site of kind, its measure and way rolled first, at the first of
// REMAINS_TRIES spots REMAINS_NEAR..REMAINS_FAR blocks from the gate's middle (even over the
// area) whose land suits it and where it stands clear; else none.
@(private = "file")
remains_scatter :: proc(
	rm: ^Remains,
	l: ^Land,
	gen: ^worldgen.Generator,
	rng: ^base.Rng,
	kind: Remain_Kind,
	from: [2]i32,
	ruin: Footprint,
) {
	site := Remain {
		kind = kind,
		seed = base.rng_u64(rng),
	}
	angle := base.rng_f64(rng) * math.TAU
	site.along = {base.cos(angle), base.sin(angle)}
	switch kind {
	case .Court, .Road:
		return
	case .Pylon:
		site.size = base.rng_roll(rng, i32(9), 15)
	case .Wall:
		site.size = base.rng_roll(rng, i32(10), 18)
		site.along = {1, 0} if abs(site.along.x) >= abs(site.along.y) else {0, 1}
	case .Tower:
		site.size = base.rng_roll(rng, i32(3), 4)
	case .Vault:
		site.size = base.rng_roll(rng, i32(5), 7)
		site.along =
			{math.sign(site.along.x), 0} if abs(site.along.x) >= abs(site.along.y) else {0, math.sign(site.along.y)}
	case .Stones:
		site.size = base.rng_roll(rng, i32(5), 7)
	}
	shape := REMAIN_SHAPES[kind]
	for try in 0 ..< REMAINS_TRIES {
		u := base.rng_f64(rng)
		r := math.sqrt(
			REMAINS_NEAR * REMAINS_NEAR +
			u * (REMAINS_FAR * REMAINS_FAR - REMAINS_NEAR * REMAINS_NEAR),
		)
		a := base.rng_f64(rng) * math.TAU
		site.middle = from + {i32(math.floor(base.cos(a) * r)), i32(math.floor(base.sin(a) * r))}
		site.at = remain_footprint(site)
		stand := remain_stand(site)
		edge := stand.hi.x - site.middle.x
		dry: bool
		site.floor, site.lo, site.hi, dry = site_ground(l, site.middle.x, site.middle.y, edge)
		if !dry || site.hi - site.lo > shape.spread + i32(try / (REMAINS_TRIES / 3)) * 2 {continue}
		if !remains_clear(rm, gen, site, ruin) {continue}
		remains_add(rm, site)
		return
	}
}

// remain_footprint: the columns a scattered site covers, from its middle, way and measure.
remain_footprint :: proc(site: Remain) -> Footprint {
	reach := REMAIN_SHAPES[site.kind].reach
	m := site.middle
	#partial switch site.kind {
	case .Pylon:
		half := site.along * f64(site.size) / 2
		a := [2]f64{f64(m.x), f64(m.y)} - half
		b := [2]f64{f64(m.x), f64(m.y)} + half
		return {
			{i32(math.floor(min(a.x, b.x))) - reach, i32(math.floor(min(a.y, b.y))) - reach},
			{i32(math.floor(max(a.x, b.x))) + reach, i32(math.floor(max(a.y, b.y))) + reach},
		}
	case .Wall:
		half := site.size / 2 + reach
		return {m - half, m + half}
	}
	half := site.size + reach
	return {m - half, m + half}
}

// remain_stand: the columns whose land a scattered site asks about (site_ground): its length,
// or a block past its radius (a tower's rubble may spill down a slope).
remain_stand :: proc(site: Remain) -> Footprint {
	edge := site.size / 2 + 1 if site.kind == .Pylon || site.kind == .Wall else site.size + 1
	return {site.middle - edge, site.middle + edge}
}

// remains_clear: site keeps clear of the ruin's apron, the generator's structures (all but the
// home gate, which is the court's) and the sites planned: the court by REMAINS_CLEAR (a road
// starts out of its footprint), scattered sites of each other by REMAINS_APART, and of the
// road by REMAINS_CLEAR.
@(private = "file")
remains_clear :: proc(
	rm: ^Remains,
	gen: ^worldgen.Generator,
	site: Remain,
	ruin: Footprint,
) -> bool {
	if footprint_meets(site.at, ruin, REMAINS_CLEAR) {return false}
	for o in rm.sites[:rm.count] {
		margin: i32 = REMAINS_CLEAR
		switch {
		case site.kind == .Road && o.kind != .Road:
			margin = 0 if o.kind == .Court else REMAINS_CLEAR
		case site.kind == .Road:
			margin = 0
		case o.kind != .Road && o.kind != .Court:
			margin = REMAINS_APART
		}
		if footprint_meets(site.at, o.at, margin) {return false}
	}
	found := make([dynamic]worldgen.Structure, context.temp_allocator)
	lo, hi := site.at.lo - REMAINS_CLEAR, site.at.hi + REMAINS_CLEAR
	worldgen.structures_near(gen, lo, hi, &found)
	home, _ := gen.home.?
	for f in found {if f != home {return false}}
	return true
}

// ---- the world's file ----

// REMAINS_FILE: which remains a world has built (core.World_File: sandbox.remains.txt), as
// text: `before` alone, for a world saved before there were remains (none is ever built in
// it), or a line `built <x> <z>` for each site built, naming its middle column.
REMAINS_FILE :: "remains.txt"

// remains_load: the home world's file read as it opens. A world without one is new (its sites
// are built as players come near; the file is written at its first save) or from before the
// remains (none is built in it). A damaged file is moved aside and nothing more is built.
remains_load :: proc(s: ^core.Server, w: ^core.World) {
	if w != s.home {return}
	rm := &world_of(w).remains
	data, found := core.world_file_read(w, REMAINS_FILE)
	switch {
	case found && !remains_decode(rm, string(data)):
		core.world_file_aside(w, REMAINS_FILE)
		rm^ = {}
		rm.before, rm.dirty = true, true
	case found:
	case core.world_made(w):
		rm.dirty = true
	case:
		rm.before, rm.dirty = true, true
	}
}

// remains_write stages the home world's file when it changed (the save hook calls it).
remains_write :: proc(s: ^core.Server, w: ^core.World) {
	if w != s.home {return}
	rm := &world_of(w).remains
	if !rm.dirty {return}
	b := strings.builder_make(context.temp_allocator)
	if rm.before {strings.write_string(&b, "before\n")}
	for m in rm.built[:rm.built_count] {fmt.sbprintf(&b, "built %d %d\n", m.x, m.y)}
	rm.dirty = !core.world_file_write(w, REMAINS_FILE, transmute([]u8)strings.to_string(b))
}

// remains_decode reads a file into rm (its built sites, or before); false for a line it does
// not know or more sites than a plan has.
remains_decode :: proc(rm: ^Remains, text: string) -> bool {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		fields := strings.fields(line, context.temp_allocator)
		switch {
		case len(fields) == 0:
		case len(fields) == 1 && fields[0] == "before":
			rm.before = true
		case len(fields) == 3 && fields[0] == "built" && rm.built_count < MAX_REMAINS:
			x, x_ok := strconv.parse_i64_of_base(fields[1], 10)
			z, z_ok := strconv.parse_i64_of_base(fields[2], 10)
			if !x_ok || !z_ok || abs(x) > i64(max(i32)) || abs(z) > i64(max(i32)) {return false}
			rm.built[rm.built_count] = {i32(x), i32(z)}
			rm.built_count += 1
		case:
			return false
		}
	}
	return true
}

// remains_check: is the file whole? (--check: core.World_File.check)
remains_check :: proc(data: []u8) -> bool {
	rm: Remains
	return remains_decode(&rm, string(data))
}
