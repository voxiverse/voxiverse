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
import "server:play"

// Settlements: the survivors' camps of the home world, SETTLEMENTS of them, a journey from
// the spawn, each with its people (folk.odin) to talk to (talk.odin). Everything is placed
// from the world's seed alone (settlements_plan): on SETTLEMENT_RINGS rings round the spawn
// from SETTLEMENT_NEAR out, SETTLEMENT_PER_RING spots each starting in a direction of the
// seed's, the first spots whose ground is dry and level (site_ground), clear of the ruin's
// apron, the remains and the generator's structures by SETTLEMENT_CLEAR and of each other by
// SETTLEMENT_APART; when fewer are found, the land may be more uneven, then wet. They are
// numbered nearest first, and each is one of the layouts (settlement_build.odin), no two
// alike, named by the seed (folk.odin's names).
//
// A settlement is built whole, in one paste over levelled ground, when a player is within
// SETTLEMENT_REACH blocks of it and its ground is loaded, unless an outpost's beacon stands
// on it; the world's file (SETTLEMENTS_FILE) remembers which are built, and a world saved
// before there were settlements gets none (nothing is built over what its players made).
// Once built it keeps its people (folk_keep), is a place in the logbook of each player who
// comes within SETTLEMENT_NOTED blocks (the journal, the compass and the map show it), its
// fabricator hums, and no creature that fights comes by itself within SETTLEMENT_GUARDED
// blocks of it, as round an outpost's beacon (settlement_spawned).

SETTLEMENTS :: 3 // camps a home world has
MAX_SETTLEMENTS :: 8 // ... and those /settlement sets down besides, in a session
SETTLEMENT_NEAR :: 300 // blocks from the spawn to the first ring
SETTLEMENT_RINGS :: 14
SETTLEMENT_RING_STEP :: 40
SETTLEMENT_PER_RING :: 24
SETTLEMENT_SIDE :: 25 // the square a camp's template covers (x and z)
SETTLEMENT_MID :: SETTLEMENT_SIDE / 2
SETTLEMENT_DEPTH :: 2 // layers of foundation under the floor
SETTLEMENT_HEIGHT :: 12 // the template's height: the foundation, the floor and the air over it
SETTLEMENT_APRON :: 3 // blocks of levelled ground round it
SETTLEMENT_LEVEL :: 6 // blocks between the land's highest and lowest under a level camp
SETTLEMENT_CLEAR :: 24 // blocks between a camp and the ruin's apron, the remains or a structure
SETTLEMENT_APART :: 200 // blocks between two camps' middles, at the least
SETTLEMENT_REACH :: 192 // a player this near a camp's middle has it built once its ground is loaded
SETTLEMENT_NOTED :: 40 // ... this near a built one has it in its logbook
SETTLEMENT_GUARDED :: 48 // no creature that fights comes by itself this near a camp
SETTLEMENT_EVERY :: 15 // ticks between two looks at the camps
SETTLEMENT_HUM :: 0.25 // how loud a camp's fabricator hums
MAX_CAMP_NAME :: 32

// Settlement: a camp of the home world: where it stands (its site: the template's lowest
// corner and the floor), its middle column, its layout, its seed and its name.
Settlement :: struct {
	site:     Site,
	middle:   [2]i32,
	layout:   Layout,
	roles:    u8, // whose people it has (CAMP_ROLES: its number in the plan)
	seed:     u64,
	name:     [MAX_CAMP_NAME]u8,
	name_len: u8,
}

settlement_name :: proc(st: ^Settlement) -> string {return string(st.name[:st.name_len])}

// Settlements: the home world's camps (its world state's): the plan, which are built, and
// whether it is a world from before them; and those /settlement set down this session.
Settlements :: struct {
	list:            [MAX_SETTLEMENTS]Settlement, // the plan's, then the command's
	count:           int,
	plan_count:      int, // the plan's (the rest the command's, kept for the session alone)
	planned:         bool,
	built:           [MAX_SETTLEMENTS]bool,
	before:          bool, // saved before there were settlements: none is built in it
	dirty:           bool, // changed since its file was staged
	markets:         [MAX_SETTLEMENTS]Camp_Market, // what each camp's trader holds (talk.odin; not saved)
	// The middles of the camps its file says are built, until the plan is made.
	unplanned:       [SETTLEMENTS][2]i32,
	unplanned_count: int,
}

settlements_of :: proc(s: ^core.Server) -> ^Settlements {return &world_of(s.home).settlements}

// settlement_middle: a camp's middle, on its floor.
settlement_middle :: proc(st: ^Settlement) -> [3]f64 {
	return {f64(st.middle.x) + 0.5, f64(st.site.floor + 1), f64(st.middle.y) + 0.5}
}

// settlement_point: where one stands on a camp's floor at local column l.
settlement_point :: proc(st: ^Settlement, l: [2]i32) -> [3]f64 {
	o := st.site.origin
	return {f64(o.x + l.x) + 0.5, f64(st.site.floor + 1), f64(o.z + l.y) + 0.5}
}

// settlement_footprint: the columns a camp and its apron cover.
settlement_footprint :: proc(middle: [2]i32) -> Footprint {
	r :: SETTLEMENT_MID + SETTLEMENT_APRON
	return {middle - r, middle + r}
}

// settlement_area: a camp's whole box, from under its land to over its roofs: what must be
// loaded for it to be built, and what is levelled.
settlement_area :: proc(st: ^Settlement) -> core.Box {
	f := settlement_footprint(st.middle)
	return {
		{f.lo.x, min(st.site.origin.y, st.site.lo) - 2, f.lo.y},
		{f.hi.x, max(st.site.origin.y + SETTLEMENT_HEIGHT - 1, st.site.hi + 8), f.hi.y},
	}
}

// settlement_kept: a built camp's blocks as built (its foundation, its floor, its fences,
// huts, tents and machines) are not to be changed by a player or a blast (game.odin's kept);
// what a player set down in its air is its own.
settlement_kept :: proc(
	s: ^core.Server,
	w: ^core.World,
	at: game.Block_Pos,
	old: game.Block,
) -> string {
	if w != s.home || old == .Air {return ""}
	ss := settlements_of(s)
	cells := &state(s).camp_cells
	for i in 0 ..< ss.count {
		if !ss.built[i] {continue}
		st := &ss.list[i]
		l := at - st.site.origin
		if l.x < 0 ||
		   l.y < 0 ||
		   l.z < 0 ||
		   l.x >= SETTLEMENT_SIDE ||
		   l.y >= SETTLEMENT_HEIGHT ||
		   l.z >= SETTLEMENT_SIDE {continue}
		if len(cells[i]) == 0 {
			t := camp_template(&state(s).camp_kit, st)
			cells[i] = make([dynamic]u16, len(t.cells))
			copy(cells[i][:], t.cells)
		}
		t := game.Template{{SETTLEMENT_SIDE, SETTLEMENT_HEIGHT, SETTLEMENT_SIDE}, cells[i][:]}
		cell := game.template_cell(&t, l, 0)
		if cell != game.VOID &&
		   cell != u16(game.Block.Air) {return "The camp's people would not have it"}
	}
	return ""
}

// settlement_stop: what the camps keep for the session (their blocks as built).
settlement_stop :: proc(s: ^core.Server) {
	for &cells in state(s).camp_cells {
		delete(cells)
		cells = nil
	}
}

// settlement_inside: p (feet) is within the camp's square.
settlement_inside :: proc(st: ^Settlement, p: [3]f64) -> bool {
	o := st.site.origin
	return(
		p.x >= f64(o.x) &&
		p.z >= f64(o.z) &&
		p.x < f64(o.x + SETTLEMENT_SIDE) &&
		p.z < f64(o.z + SETTLEMENT_SIDE) \
	)
}

// settlement_at: the built camp p stands in (its index; -1: none) in w.
settlement_at :: proc(s: ^core.Server, w: ^core.World, p: [3]f64) -> int {
	if w != s.home {return -1}
	ss := settlements_of(s)
	for i in 0 ..< ss.count {
		if ss.built[i] && settlement_inside(&ss.list[i], p) {return i}
	}
	return -1
}

// settlements_plan: the home world's camps from its seed alone (seed; the land's, l's)
// round spawn, clear of the ruin's footprint, the remains and the generator's structures
// (gen's), nearest first. Pass by pass, the land asked of a spot is let be more uneven, and
// at last wet, until SETTLEMENTS are found.
settlements_plan :: proc(
	ss: ^Settlements,
	l: ^Land,
	gen: ^worldgen.Generator,
	seed: i64,
	spawn: [3]f64,
	ruin: Footprint,
	rm: ^Remains,
) {
	ss.count = 0
	rng := base.rng_make(u64(seed) ~ 0x5e77_1e5c)
	angle := base.rng_f64(&rng) * math.TAU
	layouts := [len(Layout)]Layout{}
	for &k, i in layouts {k = Layout(i)}
	for i := len(layouts) - 1; i > 0; i -= 1 {
		j := base.rng_int_max(&rng, i + 1)
		layouts[i], layouts[j] = layouts[j], layouts[i]
	}
	Pass :: struct {
		spread: i32,
		wet:    bool,
	}
	passes := [?]Pass {
		{SETTLEMENT_LEVEL, false},
		{SETTLEMENT_LEVEL * 2, false},
		{24, false},
		{max(i32), true},
	}
	for pass in passes {
		for ring in 0 ..< SETTLEMENT_RINGS {
			d := f64(SETTLEMENT_NEAR + ring * SETTLEMENT_RING_STEP)
			for k in 0 ..< SETTLEMENT_PER_RING {
				if ss.count == SETTLEMENTS {break}
				a := angle + (f64(k) + 0.5 * f64(ring % 2)) * math.TAU / SETTLEMENT_PER_RING
				m := [2]i32 {
					i32(math.floor(spawn.x + base.cos(a) * d)),
					i32(math.floor(spawn.z + base.sin(a) * d)),
				}
				if !settlement_clear(ss, gen, m, ruin, rm) {continue}
				floor, lo, hi, dry := site_ground(l, m.x, m.y, SETTLEMENT_MID + SETTLEMENT_APRON)
				if (!dry && !pass.wet) || hi - lo > pass.spread {continue}
				st := &ss.list[ss.count]
				st^ = {
					site   = {
						{m.x - SETTLEMENT_MID, floor - SETTLEMENT_DEPTH, m.y - SETTLEMENT_MID},
						floor,
						lo,
						hi,
						dry && hi - lo <= SETTLEMENT_LEVEL,
					},
					middle = m,
					seed   = base.rng_u64(&rng),
				}
				st.name_len = u8(copy(st.name[:], camp_name(st.seed)))
				ss.count += 1
			}
		}
	}
	// Nearest first; each its layout and its people by its number.
	near :: proc(a: Settlement, spawn: [3]f64) -> f64 {
		a := a
		d := settlement_middle(&a) - spawn
		return d.x * d.x + d.z * d.z
	}
	for i in 1 ..< ss.count {
		for j := i; j > 0 && near(ss.list[j], spawn) < near(ss.list[j - 1], spawn); j -= 1 {
			ss.list[j], ss.list[j - 1] = ss.list[j - 1], ss.list[j]
		}
	}
	for i in 0 ..< ss.count {ss.list[i].layout, ss.list[i].roles = layouts[i], u8(i)}
	ss.plan_count = ss.count
}

// settlement_clear: a camp at middle m keeps clear of the ruin's apron, the remains (but the
// road's stretches, which it may cut), the generator's structures and the camps planned.
@(private = "file")
settlement_clear :: proc(
	ss: ^Settlements,
	gen: ^worldgen.Generator,
	m: [2]i32,
	ruin: Footprint,
	rm: ^Remains,
) -> bool {
	at := settlement_footprint(m)
	if footprint_meets(at, ruin, SETTLEMENT_CLEAR) {return false}
	for site in rm.sites[:rm.count] {
		if site.kind != .Road && footprint_meets(at, site.at, SETTLEMENT_CLEAR) {return false}
	}
	for &o in ss.list[:ss.count] {
		d := o.middle - m
		if d.x * d.x + d.y * d.y < SETTLEMENT_APART * SETTLEMENT_APART {return false}
	}
	found := make([dynamic]worldgen.Structure, context.temp_allocator)
	worldgen.structures_near(gen, at.lo - SETTLEMENT_CLEAR, at.hi + SETTLEMENT_CLEAR, &found)
	return len(found) == 0
}

// settlements_tick: the home world's camps planned once its remains are (remains_tick runs
// first), each built when a player is near it and its ground is loaded, and while one is,
// noted in the logbooks of those near and kept with its people, and the way to the nearest shown to whoever
// is led there (settlement_lead).
settlements_tick :: proc(s: ^core.Server) {
	w := s.home
	ss := &world_of(w).settlements
	rm := &world_of(w).remains
	if ss.before || !ruin_of(s).placed || !(rm.planned || rm.before) {return}
	if !ss.planned {
		gen := worldgen.generator_make(w.generator, terrain_seed(w), s.registry, w.params)
		land := land_of(w)
		settlements_plan(
			ss,
			&land,
			&gen,
			w.seed,
			w.spawn.position,
			ruin_footprint(ruin_of(s).site),
			rm,
		)
		ss.planned = true
		for m in ss.unplanned[:ss.unplanned_count] {
			for i in 0 ..< ss.count {if ss.list[i].middle == m {ss.built[i] = true}}
		}
		ss.unplanned_count = 0
		log.infof("settlements planned: %d (land sampled %d times)", ss.count, land.samples)
		for i in 0 ..< ss.count {
			st := &ss.list[i]
			log.infof(
				"settlement %s layout=%v middle=%v floor=%d",
				settlement_name(st),
				st.layout,
				st.middle,
				st.site.floor,
			)
			market_stock(&ss.markets[i], st.seed)
			if ss.built[i] {settlement_hum(s, st)}
		}
	}
	if s.tick % SETTLEMENT_EVERY != 0 {return}
	for i in 0 ..< ss.count {
		st := &ss.list[i]
		near := false
		for &c in s.clients {
			if c.state != .Playing || c.world != w {continue}
			near ||= play.distance_to(c.player.position, settlement_middle(st)) <= SETTLEMENT_REACH
		}
		if !near || !core.world_ready(w, settlement_area(st)) {continue}
		if !ss.built[i] {
			if settlement_beaconed(w, st) {continue}
			settlement_build(s, w, st)
			ss.built[i], ss.dirty = true, true
			settlement_hum(s, st)
		}
		settlement_noted(s, w, st)
		folk_keep(s, w, ss, i)
	}
	settlement_lead(s, w, ss)
}

// settlement_beaconed: an outpost's beacon stands where the camp would be built (it is
// not, while it does).
@(private = "file")
settlement_beaconed :: proc(w: ^core.World, st: ^Settlement) -> bool {
	o := outposts_of(w)
	f := settlement_footprint(st.middle)
	for p in o.list[:o.count] {
		if p.at.x >= f.lo.x &&
		   p.at.x <= f.hi.x &&
		   p.at.z >= f.lo.y &&
		   p.at.z <= f.hi.y {return true}
	}
	return false
}

// settlement_hum: a built camp's fabricator hums.
settlement_hum :: proc(s: ^core.Server, st: ^Settlement) {
	at := layout_of(st.layout).fabricator
	o := st.site.origin
	core.world_hum(s.home, {o.x + at.x, st.site.floor + 1, o.z + at.y}, SETTLEMENT_HUM)
}

// settlement_noted: a built camp in the logbook of each player in w within
// SETTLEMENT_NOTED blocks of its middle (across), by its name.
@(private = "file")
settlement_noted :: proc(s: ^core.Server, w: ^core.World, st: ^Settlement) {
	for &c in s.clients {
		if c.state != .Playing || c.world != w {continue}
		if play.distance_to(c.player.position, settlement_middle(st)) > SETTLEMENT_NOTED {continue}
		core.logbook_place(s, &c, .Settlement, settlement_place(st), settlement_name(st))
	}
}

// settlement_place: where a camp is in a logbook (its middle, on its floor).
settlement_place :: proc(st: ^Settlement) -> [3]i32 {return {
		st.middle.x,
		st.site.floor + 1,
		st.middle.y,
	}}

// LEAD_QUEST: the first hour's quest that sends a survivor to the nearest camp: while it is
// under way the camp is in the survivor's logbook (its beacon heard the camp's call), so the
// compass and the map point at it.
LEAD_QUEST :: "sandbox:smoke_on_the_horizon"

// settlement_lead: whoever has LEAD_QUEST under way and no camp in its logbook is told of
// the nearest (by the world's spawn), which goes into its logbook.
@(private = "file")
settlement_lead :: proc(s: ^core.Server, w: ^core.World, ss: ^Settlements) {
	q, has := game.quest_by_id(s.registry, LEAD_QUEST)
	if !has || ss.count == 0 {return}
	for &c in s.clients {
		if c.state != .Playing ||
		   c.world != w ||
		   !game.quest_open(s.registry, &c.quests, q) {continue}
		known := false
		for &p in c.logbook.places[:c.logbook.place_count] {known ||= p.kind == .Settlement}
		if known {continue}
		st := &ss.list[0]
		core.logbook_place(s, &c, .Settlement, settlement_place(st), settlement_name(st))
		d := settlement_middle(st) - c.player.position
		core.notice(
			s,
			&c,
			fmt.tprintf(
				"Your beacon picks up a call: survivors at %s, %.0f blocks %s",
				settlement_name(st),
				math.sqrt(d.x * d.x + d.z * d.z),
				compass_word(d),
			),
		)
	}
}

// compass_word: the way a flat offset points (north is -z).
compass_word :: proc(d: [3]f64) -> string {
	WORDS :: [8]string {
		"east",
		"south-east",
		"south",
		"south-west",
		"west",
		"north-west",
		"north",
		"north-east",
	}
	a := math.atan2(d.z, d.x) // (0: east, +pi/2: south)
	i := int(math.round(a / (math.PI / 4))) %% 8
	words := WORDS
	return words[i]
}

// settlement_spawned: a creature that fights coming by itself within SETTLEMENT_GUARDED
// blocks of a camp of the home world is refused (the spawned hook), as round a beacon.
settlement_spawned :: proc(s: ^core.Server, w: ^core.World, h: game.Entity_Handle) -> bool {
	if w != s.home {return true}
	kind := core.entity_kind(w, h)
	if kind == 0 || int(kind) > len(s.registry.kinds) {return true}
	if _, fights := s.registry.kinds[kind - 1].attack.?; !fights {return true}
	ss := settlements_of(s)
	p := core.entity_pos(w, h)
	for i in 0 ..< ss.count {
		if play.distance_to(p, settlement_middle(&ss.list[i])) < SETTLEMENT_GUARDED {return false}
	}
	return true
}

// settlement_command: `/settlement <ring|yard|hamlet|longhouse> [1|2|3]` sets a camp of that
// layout down at the player's feet with the people of the plan's camp of that number (the
// first when none is named), built at once and kept for the session (its blocks and people
// stay; after a restart its people stand still); `/settlement` alone says where the world's
// camps are. Setting one down asks the bulk edit permission (world.edit.bulk).
settlement_command :: proc(s: ^core.Server, c: ^core.Client, args: []string) -> bool {
	USAGE :: "Usage: settlement [ring|yard|hamlet|longhouse [1|2|3]]"
	ss := settlements_of(s)
	if len(args) == 0 {
		if ss.count == 0 {core.notice(s, c, "This world has no camps")}
		for i in 0 ..< ss.count {
			st := &ss.list[i]
			p := settlement_place(st)
			built := "built" if ss.built[i] else "not built yet"
			core.notice(
				s,
				c,
				fmt.tprintf(
					"%s at %d %d %d (%v, %s)",
					settlement_name(st),
					p.x,
					p.y,
					p.z,
					st.layout,
					built,
				),
			)
		}
		return true
	}
	if !core.allowed(s, c, "world.edit.bulk") {
		core.notice(s, c, "You may not build here")
		return true
	}
	NAMES :: [Layout]string {
		.Ring_Camp    = "ring",
		.Walled_Yard  = "yard",
		.Scrap_Hamlet = "hamlet",
		.Longhouse    = "longhouse",
	}
	layout, found := Layout(0), false
	names := NAMES
	for name, l in names {if name == args[0] {layout, found = l, true}}
	roles := 1
	if len(args) == 2 {roles, _ = strconv.parse_int(args[1])}
	if !found || len(args) > 2 || roles < 1 || roles > SETTLEMENTS || c.world != s.home {
		core.notice(s, c, USAGE)
		return true
	}
	if !ss.planned && !ss.before {
		core.notice(s, c, "The camps are still being planned: try again in a moment")
		return true
	}
	if ss.count == MAX_SETTLEMENTS {
		core.notice(s, c, "This world has as many camps as it may")
		return true
	}
	p := play.block_of(c.player.position)
	floor := p.y - 1
	st := &ss.list[ss.count]
	st^ = {
		site   = {
			{p.x - SETTLEMENT_MID, floor - SETTLEMENT_DEPTH, p.z - SETTLEMENT_MID},
			floor,
			floor,
			floor,
			true,
		},
		middle = {p.x, p.z},
		layout = layout,
		roles  = u8(roles - 1),
		seed   = u64(s.config.seed) ~ (u64(ss.count) * 0x9e37_79b9),
	}
	st.name_len = u8(copy(st.name[:], camp_name(st.seed)))
	market_stock(&ss.markets[ss.count], st.seed)
	ss.built[ss.count] = true
	ss.count += 1
	settlement_build(s, s.home, st)
	settlement_hum(s, st)
	folk_keep(s, s.home, ss, ss.count - 1)
	core.notice(s, c, fmt.tprintf("%s set down", settlement_name(st)))
	return true
}

// ---- the world's file ----

// SETTLEMENTS_FILE: which camps a world has built (sandbox.settlements.txt), as text:
// `before` alone for a world saved before there were settlements (none is ever built in
// it), or a line `built <x> <z>` for each camp built, naming its middle column.
SETTLEMENTS_FILE :: "settlements.txt"

// settlements_load: the home world's file read as it opens. A world without one is new (or
// from before the settlements: none is built in it); a damaged one is moved aside and
// nothing more is built. The built camps are matched to the plan as it is made.
settlements_load :: proc(s: ^core.Server, w: ^core.World) {
	if w != s.home {return}
	ss := &world_of(w).settlements
	data, found := core.world_file_read(w, SETTLEMENTS_FILE)
	switch {
	case found:
		if !settlements_decode(ss, string(data)) {
			core.world_file_aside(w, SETTLEMENTS_FILE)
			ss^ = {}
			ss.before, ss.dirty = true, true
		}
	case core.world_made(w):
		ss.dirty = true
	case:
		ss.before, ss.dirty = true, true
	}
}

// settlements_write stages the home world's file when it changed.
settlements_write :: proc(s: ^core.Server, w: ^core.World) {
	if w != s.home {return}
	ss := &world_of(w).settlements
	if !ss.dirty {return}
	b := strings.builder_make(context.temp_allocator)
	if ss.before {strings.write_string(&b, "before\n")}
	for i in 0 ..< ss.plan_count {
		if ss.built[i] {fmt.sbprintf(&b, "built %d %d\n", ss.list[i].middle.x, ss.list[i].middle.y)}
	}
	for m in ss.unplanned[:ss.unplanned_count] {fmt.sbprintf(&b, "built %d %d\n", m.x, m.y)}
	ss.dirty = !core.world_file_write(w, SETTLEMENTS_FILE, transmute([]u8)strings.to_string(b))
}

// settlements_decode reads a file into ss: before, or the middles of the camps built (kept
// until the plan is made, which marks them built); false for a line it does not know.
settlements_decode :: proc(ss: ^Settlements, text: string) -> bool {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		fields := strings.fields(line, context.temp_allocator)
		switch {
		case len(fields) == 0:
		case len(fields) == 1 && fields[0] == "before":
			ss.before = true
		case len(fields) == 3 && fields[0] == "built" && ss.unplanned_count < SETTLEMENTS:
			x, x_ok := strconv.parse_i64_of_base(fields[1], 10)
			z, z_ok := strconv.parse_i64_of_base(fields[2], 10)
			if !x_ok || !z_ok || abs(x) > i64(max(i32)) || abs(z) > i64(max(i32)) {return false}
			ss.unplanned[ss.unplanned_count] = {i32(x), i32(z)}
			ss.unplanned_count += 1
		case:
			return false
		}
	}
	return true
}

// settlements_check: is the file whole? (--check: core.World_File.check)
settlements_check :: proc(data: []u8) -> bool {
	ss: Settlements
	return settlements_decode(&ss, string(data))
}
