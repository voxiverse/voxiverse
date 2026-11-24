package sandbox_server

import "core:fmt"
import "core:log"
import "core:math"
import "core:strconv"
import "core:strings"

import "common:base"
import "common:game"
import "common:starmap"
import "common:worldgen"
import "server:core"
import "server:play"

// The gate worlds' places: on a world of a class (common/worldgen/classes.odin; not the home
// world, not Earth) the sandbox plans, from the world's address and its land, one landmark of
// the class's own kind and BEYOND_SITES small sites round the gate travellers arrive at
// (beyond_plan): a ring of standing stones on a temperate world, a terraced dwelling in a
// canyon, an ice-bound hall on a frozen world, a half-sunk platform in an ocean world's
// shallows, a basalt-locked vault on a volcanic world, a spore-grown tower on a fungal world,
// a keepers' relay on a moon and a station in a jungle's canopy; and a cairn, a dry well, an
// iced cache, a beached hull, an obsidian obelisk, a spore shrine, a fallen probe or an
// overgrown altar (beyond_build.odin draws them in the class's materials). Each holds a
// remains cache (the landmarks a sealed relic vault too) whose loot is the class's
// (survival.odin's CLASS_LOOT beside the remains' own), hums, and keeps the machine its
// drawing posts (dormant sentries at a moon's relay and probe, a volcanic vault and a
// frozen hall; a mender at a ring of stones). A player who comes near a built place has it in
// its logbook (the landmark as a `landmark`, a site as `remains`, by name), so the journal,
// the compass and the map show it.
//
// Every place stands on land that suits its kind (dry and not too uneven; the platform in
// shallow sea), BEYOND_CLEAR blocks clear of the arrival gate and its platform, of the
// generator's structures, of the world's spawn and of each other. A place is built once, in
// one paste, when a player comes within BEYOND_REACH blocks of it and its ground is loaded;
// the world's file (BEYOND_FILE) remembers which are built, and a world saved before there
// were places gets none.

BEYOND_SITES :: 2 // small sites a world plans beside its landmark
BEYOND_MOST :: 1 + BEYOND_SITES
BEYOND_LANDMARK_FROM :: 110 // blocks from the arrival gate's middle to the landmark's, at the least
BEYOND_LANDMARK_TO :: 260 // ... at the most
BEYOND_SITE_FROM :: 50 // and to a site's
BEYOND_SITE_TO :: 300
BEYOND_TRIES :: 120 // spots tried for a place before it is left out (each third lets the land be 2 more uneven)
BEYOND_CLEAR :: 24 // blocks between a place and the arrival gate's platform, a structure or the spawn
BEYOND_APART :: 40 // blocks between two places' footprints
BEYOND_REACH :: 192 // a player this near a place's middle has it built once its ground is loaded
BEYOND_EVERY :: 15 // ticks between two looks at what is to be built
BEYOND_NOTED_LANDMARK :: 64 // a player this near a built landmark's middle has it in its logbook
BEYOND_NOTED_SITE :: 32 // ... a site's
LANDMARK_HUM :: 0.8
SITE_HUM :: 0.4

// Beyond_Place: one place of a gate world: whether it is its landmark, the columns it
// covers and its middle, its floor's layer (who stands on it stands at floor + 1; a
// platform's is the sea's top), the land's lowest and highest under it, the way it is turned
// (quarter turns) and the seed of the rest.
Beyond_Place :: struct {
	landmark: bool,
	at:       Footprint,
	middle:   [2]i32,
	floor:    i32,
	lo, hi:   i32,
	turn:     u8,
	seed:     u64,
}

// Beyond: a gate world's places (its world state's): its class, its plan, which are built,
// and whether it is a world from before them.
Beyond :: struct {
	class:       worldgen.World_Class,
	places:      [BEYOND_MOST]Beyond_Place,
	count:       int,
	planned:     bool,
	samples:     int, // land columns the plan asked about (what it cost)
	gate:        Maybe(worldgen.Structure), // the arrival gate the plan found (its costly search, made once)
	built:       [BEYOND_MOST][2]i32, // the middles of the places built (its file's, and since)
	built_count: int,
	before:      bool, // saved before there were places: none is built in it
	dirty:       bool, // changed since its file was staged
}

// Beyond_Shape: what a kind of place asks of the land and how big it is: the most the land
// under it may rise and fall (site_ground's samples over its half), its half width (its
// footprint is 2 * half + 1 square, whatever its turn), and how far it stands over its floor
// and under it.
Beyond_Shape :: struct {
	spread: i32,
	half:   i32,
	above:  i32,
	below:  i32,
}

// BEYOND_LANDMARKS, BEYOND_SITE_SHAPES: each class's landmark and site.
@(rodata)
BEYOND_LANDMARKS := [worldgen.World_Class]Beyond_Shape {
	.None = {},
	.Temperate = {spread = 6, half = 10, above = 9, below = 3},
	.Canyon = {spread = 8, half = 8, above = 15, below = 3},
	.Frozen = {spread = 6, half = 9, above = 12, below = 3},
	.Ocean = {spread = 7, half = 8, above = 10, below = 14},
	.Volcanic = {spread = 6, half = 7, above = 11, below = 3},
	.Fungal = {spread = 6, half = 6, above = 26, below = 3},
	.Moon = {spread = 6, half = 8, above = 18, below = 3},
	.Jungle = {spread = 8, half = 8, above = 22, below = 3},
}
@(rodata)
BEYOND_SITE_SHAPES := [worldgen.World_Class]Beyond_Shape {
	.None = {},
	.Temperate = {spread = 4, half = 3, above = 6, below = 2},
	.Canyon = {spread = 4, half = 3, above = 5, below = 8},
	.Frozen = {spread = 4, half = 4, above = 6, below = 2},
	.Ocean = {spread = 4, half = 5, above = 6, below = 2},
	.Volcanic = {spread = 4, half = 3, above = 9, below = 2},
	.Fungal = {spread = 4, half = 4, above = 6, below = 2},
	.Moon = {spread = 4, half = 4, above = 6, below = 3},
	.Jungle = {spread = 4, half = 3, above = 6, below = 2},
}

// BEYOND_NAMES: what a class's landmark and site are called in a player's logbook.
@(rodata)
BEYOND_NAMES := [worldgen.World_Class][2]string {
	.None      = {"", ""},
	.Temperate = {"Standing ring", "Mossy cairn"},
	.Canyon    = {"Cliff dwelling", "Dry well"},
	.Frozen    = {"Ice-bound hall", "Iced cache"},
	.Ocean     = {"Sunken platform", "Beached hull"},
	.Volcanic  = {"Basalt vault", "Obsidian obelisk"},
	.Fungal    = {"Spore tower", "Spore shrine"},
	.Moon      = {"Keepers' relay", "Fallen probe"},
	.Jungle    = {"Canopy station", "Overgrown altar"},
}

// beyond_shape: what a place's kind asks.
beyond_shape :: proc(class: worldgen.World_Class, landmark: bool) -> Beyond_Shape {
	return BEYOND_LANDMARKS[class] if landmark else BEYOND_SITE_SHAPES[class]
}

// beyond_name: what a place is called in a logbook.
beyond_name :: proc(class: worldgen.World_Class, landmark: bool) -> string {
	return BEYOND_NAMES[class][0 if landmark else 1]
}

beyond_of :: proc(w: ^core.World) -> ^Beyond {return &world_of(w).beyond}

// beyond_class: the class of a world whose places the sandbox keeps (.None: none; the home
// world never, whatever its generator says).
beyond_class :: proc(s: ^core.Server, w: ^core.World) -> worldgen.World_Class {
	if w == s.home || w.generator != .Earth {return .None}
	return worldgen.world_class_of(&w.params)
}

// beyond_tick: each gate world's places planned once it is open, and each built when a
// player is near it and its ground is loaded.
beyond_tick :: proc(s: ^core.Server) {
	for w in s.worlds {
		class := beyond_class(s, w)
		b := beyond_of(w)
		if class == .None || b.before {continue}
		if !b.planned {
			gen := worldgen.generator_make(w.generator, terrain_seed(w), s.registry, w.params)
			land := land_of(w)
			beyond_plan(b, &land, &gen, class, w.address, w.spawn.position)
			b.planned = true
			log.infof(
				"beyond planned class=%v places=%d built=%d samples=%d",
				class,
				b.count,
				b.built_count,
				b.samples,
			)
			for p in b.places[:b.count] {
				log.infof(
					"beyond place landmark=%v middle=%v floor=%d",
					p.landmark,
					p.middle,
					p.floor,
				)
				if beyond_built(b, p) {beyond_hum(w, b, p)}
			}
		}
		if s.tick % BEYOND_EVERY != 0 {continue}
		for &p in b.places[:b.count] {
			if beyond_built(b, p) {
				beyond_noted(s, w, b, p)
				continue
			}
			near := false
			for &c in s.clients {
				if c.state != .Playing || c.world != w {continue}
				d := c.player.position.xz - {f64(p.middle.x) + 0.5, f64(p.middle.y) + 0.5}
				near ||= d.x * d.x + d.y * d.y <= BEYOND_REACH * BEYOND_REACH
			}
			if !near || !core.world_ready(w, beyond_area(b.class, p)) {continue}
			beyond_build(s, w, b.class, p)
			beyond_hum(w, b, p)
			b.built[b.built_count] = p.middle
			b.built_count += 1
			b.dirty = true
		}
	}
}

// beyond_hum: a built place hums at its middle (not saved: marked again as the plan is made).
beyond_hum :: proc(w: ^core.World, b: ^Beyond, p: Beyond_Place) {
	core.world_hum(
		w,
		{p.middle.x, p.floor + 1, p.middle.y},
		LANDMARK_HUM if p.landmark else SITE_HUM,
	)
}

// beyond_noted: a built place in the logbook of each player in w near it (across).
beyond_noted :: proc(s: ^core.Server, w: ^core.World, b: ^Beyond, p: Beyond_Place) {
	reach := f64(BEYOND_NOTED_LANDMARK if p.landmark else BEYOND_NOTED_SITE)
	at := [3]i32{p.middle.x, p.floor + 1, p.middle.y}
	kind := game.Logbook_Place_Kind.Landmark if p.landmark else .Remains
	for &c in s.clients {
		if c.state != .Playing || c.world != w {continue}
		d := c.player.position.xz - {f64(p.middle.x) + 0.5, f64(p.middle.y) + 0.5}
		if d.x * d.x + d.y * d.y > reach * reach {continue}
		core.logbook_place(s, &c, kind, at, beyond_name(b.class, p.landmark))
	}
}

// beyond_built: the place is built in this world.
beyond_built :: proc(b: ^Beyond, p: Beyond_Place) -> bool {
	for m in b.built[:b.built_count] {if m == p.middle {return true}}
	return false
}

// beyond_area: a place's whole box, from under its land to over what it builds: what must be
// loaded for it to be built.
beyond_area :: proc(class: worldgen.World_Class, p: Beyond_Place) -> core.Box {
	shape := beyond_shape(class, p.landmark)
	return {
		{p.at.lo.x, min(p.lo, p.floor) - shape.below, p.at.lo.y},
		{p.at.hi.x, max(p.hi, p.floor) + shape.above, p.at.hi.y},
	}
}

// beyond_plan: a gate world's places, from its address (the rolls) and its land (l's, gen's:
// where they may stand), round its arrival gate (none without one): the landmark first, then
// BEYOND_SITES sites, each at the first of BEYOND_TRIES spots that suits it, or left out.
// spawn: the world's spawn, kept clear too.
beyond_plan :: proc(
	b: ^Beyond,
	l: ^Land,
	gen: ^worldgen.Generator,
	class: worldgen.World_Class,
	address: starmap.Address,
	spawn: [3]f64,
) {
	b.class, b.count, b.gate = class, 0, nil
	defer b.samples = l.samples
	gate, has_gate := worldgen.arrival_gate(gen)
	if !has_gate || class == .None {return}
	b.gate = gate
	lo, hi := worldgen.structure_reach(gen, gate)
	from := [2]i32{(lo.x + hi.x) / 2, (lo.z + hi.z) / 2}
	// What every place keeps clear of: the arrival gate with its platform, the spawn, and
	// the generator's structures round the gate as far as a place may reach (found once).
	keep := make([dynamic]Footprint, context.temp_allocator)
	append(&keep, Footprint{{lo.x, lo.z}, {hi.x, hi.z}})
	append(&keep, Footprint{{i32(spawn.x), i32(spawn.z)}, {i32(spawn.x), i32(spawn.z)}})
	reach := i32(BEYOND_SITE_TO + 2 * BEYOND_CLEAR) + 16
	found := make([dynamic]worldgen.Structure, context.temp_allocator)
	worldgen.structures_near(gen, from - reach, from + reach, &found)
	for f in found {
		a, z := worldgen.structure_reach(gen, f)
		append(&keep, Footprint{{a.x, a.z}, {z.x, z.z}})
	}
	rng := base.rng_make(starmap.address_hash(address) ~ 0x6b65_6570_6572_73)
	beyond_place(b, l, &rng, true, from, keep[:])
	for _ in 0 ..< BEYOND_SITES {beyond_place(b, l, &rng, false, from, keep[:])}
}

// beyond_place: one place (the landmark or a site), its turn and seed rolled first, at the
// first spot of BEYOND_TRIES that suits it.
@(private = "file")
beyond_place :: proc(
	b: ^Beyond,
	l: ^Land,
	rng: ^base.Rng,
	landmark: bool,
	from: [2]i32,
	keep: []Footprint,
) {
	shape := beyond_shape(b.class, landmark)
	p := Beyond_Place {
		landmark = landmark,
		turn     = u8(base.rng_int_max(rng, 4)),
		seed     = base.rng_u64(rng),
	}
	near := f64(BEYOND_LANDMARK_FROM if landmark else BEYOND_SITE_FROM)
	far := f64(BEYOND_LANDMARK_TO if landmark else BEYOND_SITE_TO)
	wet := landmark && b.class == .Ocean // (the platform stands in the shallows)
	for try in 0 ..< BEYOND_TRIES {
		u := base.rng_f64(rng)
		r := math.sqrt(near * near + u * (far * far - near * near))
		a := base.rng_f64(rng) * math.TAU
		p.middle = from + {i32(math.floor(base.cos(a) * r)), i32(math.floor(base.sin(a) * r))}
		p.at = {p.middle - shape.half, p.middle + shape.half}
		slack := shape.spread + i32(try / (BEYOND_TRIES / 3)) * 2
		if wet {
			ok: bool
			p.floor, p.lo, p.hi, ok = beyond_shallows(l, p.middle.x, p.middle.y, shape.half)
			if !ok || p.hi - p.lo > slack {continue}
		} else {
			dry: bool
			p.floor, p.lo, p.hi, dry = site_ground(l, p.middle.x, p.middle.y, shape.half)
			if !dry || p.hi - p.lo > slack {continue}
		}
		if !beyond_clear(b, p, keep) {continue}
		b.places[b.count] = p
		b.count += 1
		return
	}
}

// BEYOND_SHALLOWS: how far under the sea's top a platform's sea floor may lie, from and to.
BEYOND_SHALLOWS :: [2]i32{2, 10}

// beyond_shallows: for a platform whose middle is column (x, z) and which reaches edge blocks
// from it, sampled on a grid of 5 by 5: its floor (the sea's top), the sea floor's lowest and
// highest, and whether all of it is sea BEYOND_SHALLOWS deep.
beyond_shallows :: proc(l: ^Land, x, z, edge: i32) -> (floor, lo, hi: i32, ok: bool) {
	steps := [5]i32{-edge, -edge / 2, 0, edge / 2, edge}
	sea := l.params.sea_level
	floor, lo, hi, ok = sea, max(i32), min(i32), true
	for dz in steps {
		for dx in steps {
			top, _ := land_at(l, x + dx, z + dz)
			lo, hi = min(lo, top), max(hi, top)
			ok &&= top <= sea - BEYOND_SHALLOWS[0] && top >= sea - BEYOND_SHALLOWS[1]
		}
	}
	return
}

// beyond_clear: p keeps clear of the places planned (BEYOND_APART) and of what keep holds
// (the arrival gate with its platform, the spawn, the generator's structures: BEYOND_CLEAR).
@(private = "file")
beyond_clear :: proc(b: ^Beyond, p: Beyond_Place, keep: []Footprint) -> bool {
	for k in keep {if footprint_meets(p.at, k, BEYOND_CLEAR) {return false}}
	for o in b.places[:b.count] {if footprint_meets(p.at, o.at, BEYOND_APART) {return false}}
	return true
}

// beyond_command: `/places` says where the world's places are (each planned, built or not);
// `/places view landmark|site` takes the player (flying, the teleport permission) to a point
// over the landmark or the first site, looking down at it, for a picture or a test.
beyond_command :: proc(s: ^core.Server, c: ^core.Client, args: []string) -> bool {
	USAGE :: "Usage: places [view landmark|site]"
	w := c.world
	b := beyond_of(w)
	class := beyond_class(s, w)
	if class == .None || !b.planned || b.count == 0 {
		core.notice(s, c, "This world has no places")
		return true
	}
	if len(args) == 0 {
		for p in b.places[:b.count] {
			built := "built" if beyond_built(b, p) else "not built yet"
			core.notice(
				s,
				c,
				fmt.tprintf(
					"%s at %d %d %d (%s)",
					beyond_name(class, p.landmark),
					p.middle.x,
					p.floor + 1,
					p.middle.y,
					built,
				),
			)
		}
		return true
	}
	if len(args) != 2 || args[0] != "view" || (args[1] != "landmark" && args[1] != "site") {
		core.notice(s, c, USAGE)
		return true
	}
	if !core.allowed(s, c, "teleport.tp") {
		core.notice(s, c, "You may not teleport here")
		return true
	}
	for p in b.places[:b.count] {
		if p.landmark != (args[1] == "landmark") {continue}
		shape := beyond_shape(class, p.landmark)
		middle := [3]f64 {
			f64(p.middle.x) + 0.5,
			f64(p.floor + 1 + shape.above / 3),
			f64(p.middle.y) + 0.5,
		}
		off := f64(shape.half) * 2 + 6
		at := middle + {off, f64(shape.above) / 2 + 4, off}
		core.teleport(s, c, at, play.look_at(at, middle), flying = true)
		return true
	}
	core.notice(s, c, "This world has no such place")
	return true
}

// ---- the world's file ----

// BEYOND_FILE: which places a gate world has built (core.World_File: sandbox.places.txt), as
// text: `before` alone, for a world saved before there were places (none is ever built in
// it), or a line `built <x> <z>` for each place built, naming its middle column.
BEYOND_FILE :: "places.txt"

// beyond_load: a gate world's file read as it opens. A world without one is new (its places
// are built as players come near; the file is written at its first save) or from before the
// places (none is built in it). A damaged file is moved aside and nothing more is built.
beyond_load :: proc(s: ^core.Server, w: ^core.World) {
	if beyond_class(s, w) == .None {return}
	b := beyond_of(w)
	data, found := core.world_file_read(w, BEYOND_FILE)
	switch {
	case found && !beyond_decode(b, string(data)):
		core.world_file_aside(w, BEYOND_FILE)
		b^ = {}
		b.before, b.dirty = true, true
	case found:
	case core.world_made(w):
		b.dirty = true
	case:
		b.before, b.dirty = true, true
	}
}

// beyond_write stages a gate world's file when it changed (the save hook calls it).
beyond_write :: proc(s: ^core.Server, w: ^core.World) {
	if beyond_class(s, w) == .None {return}
	b := beyond_of(w)
	if !b.dirty {return}
	text := strings.builder_make(context.temp_allocator)
	if b.before {strings.write_string(&text, "before\n")}
	for m in b.built[:b.built_count] {fmt.sbprintf(&text, "built %d %d\n", m.x, m.y)}
	b.dirty = !core.world_file_write(w, BEYOND_FILE, transmute([]u8)strings.to_string(text))
}

// beyond_decode reads a file into b (its built places, or before); false for a line it does
// not know or more places than a plan has.
beyond_decode :: proc(b: ^Beyond, text: string) -> bool {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		fields := strings.fields(line, context.temp_allocator)
		switch {
		case len(fields) == 0:
		case len(fields) == 1 && fields[0] == "before":
			b.before = true
		case len(fields) == 3 && fields[0] == "built" && b.built_count < BEYOND_MOST:
			x, x_ok := strconv.parse_i64_of_base(fields[1], 10)
			z, z_ok := strconv.parse_i64_of_base(fields[2], 10)
			if !x_ok || !z_ok || abs(x) > i64(max(i32)) || abs(z) > i64(max(i32)) {return false}
			b.built[b.built_count] = {i32(x), i32(z)}
			b.built_count += 1
		case:
			return false
		}
	}
	return true
}

// beyond_check: is the file whole? (--check: core.World_File.check)
beyond_check :: proc(data: []u8) -> bool {
	b: Beyond
	return beyond_decode(&b, string(data))
}
