package sandbox_server

import "core:fmt"
import "core:log"
import "core:math"
import "core:strconv"
import "core:strings"

import "common:base"
import "common:game"
import "common:worldgen"
import "games:sandbox"
import "server:core"
import "server:play"

// The delves: the keepers' works under the home world, the sandbox's second encounter. Two or
// three a world, placed from its seed alone (delve_sites) a journey out from the spawn
// (DELVE_NEAR to DELVE_FAR blocks, past the ruin and the remains, leaving the land between to
// whatever settles it), each in its own third of the compass, on dry, even land clear of the
// ruin, the remains, the generator's structures and each other (site.odin's footprints). A
// delve shows on the land as a stair head (a platform of slate round a shaft, posts and a
// frame of iron over it) that hums; a player who comes near has it in its logbook as a
// "Sunken stair" (the compass and the map show it).
//
// Under it lie three depths of rooms (delve_plan.odin: the layout from the delve's seed). It
// is built once, in one paste, when a player comes within DELVE_REACH of its stair head and
// its ground is loaded (kept loaded while one is near), and the world's file (DELVE_FILE)
// remembers which are built; a world saved before there were delves gets none. What it posts
// as it is built (the machines asleep in its rooms: wild.odin's scuttlers, spires and
// carapaces) is kept with the world. Its blocks are not the players' to break (delve_kept)
// but its caches, which spill what their depth holds (survival.odin's DELVE_LOOT); its locked
// doors open to a keeper's key (delve_door_use); its trip plates and charged gratings hurt who
// steps on them (delve_traps). Each session, as a built delve is first loaded, it is made
// ready (delve_ready): its boss's chamber open, its vault shut, the custodian whole at its
// post (delve_boss.odin runs the fight). A player who reaches the third depth has it in its
// logbook as "Deep works".

MAX_DELVES :: 3
MAX_DELVES_HELD :: MAX_DELVES + 2 // ... and those /delve here sets down besides, in a session
DELVE_FEWEST :: 2 // delves a world plans, at the least (when its land allows)
DELVE_NEAR :: 560 // blocks from the spawn to a stair head, at the least
DELVE_FAR :: 880 // ... and the most
DELVE_TRIES :: 96 // spots tried for each delve before it is left out
DELVE_LEVEL :: 4 // blocks the land round a stair head may rise and fall
DELVE_SINK :: 8 // blocks under the stair head's floor the land over the delve may fall, at most
DELVE_APART :: 160 // blocks between two delves' footprints, at the least
DELVE_CLEAR :: 24 // blocks between a delve and the ruin's apron, the remains or a structure
DELVE_REACH :: 96 // a player this near a stair head has the delve built, kept loaded and ready
DELVE_NOTED :: 24 // a player this near a built stair head has it in its logbook
DELVE_EVERY :: 10 // ticks between two looks at what is to be built, noted and made ready
DELVE_HUM :: 0.6 // how strongly a stair head hums
DELVE_LEVELLED :: DELVE_HEAD + 2 // blocks round a stair head's middle levelled to its floor
DELVE_STAIR :: "Sunken stair" // a stair head's name in a logbook (kind Delve)
DELVE_DEEP :: "Deep works" // the third depth's (kind Delve: a place away from the stair)
DELVE_KEY :: "sandbox:keeper_key"

// The traps (the delve's blocks in its corridors' floors): a trip plate clicks under a foot
// and PLATE_DELAY ticks later darts take PLATE_HARM from whoever is within a block and a half
// of it, then it is quiet PLATE_REARM ticks. A charged grating is data alone: its block's
// `harm` (pack/data/blocks/delve.json), which the engine takes from who stands on it.
PLATE_DELAY :: 8
PLATE_HARM :: 3
PLATE_REARM :: 45
MAX_PLATES :: 16

// Delve_Site: where a delve is: its stair head's middle column and floor, and the seed its
// layout is drawn from.
Delve_Site :: struct {
	middle: [2]i32,
	floor:  i32,
	seed:   u64,
}

// Delve: a delve of the home world in this session: its site and layout, the world block of
// its layout's corner, its blocks as drawn (heap, while built: what its editing is judged
// by), whether it is built, made ready and kept loaded, and its boss's fight.
Delve :: struct {
	site:   Delve_Site,
	plan:   Delve_Plan,
	origin: game.Block_Pos,
	cells:  [dynamic]u16, // (it keeps the allocator it was made with, which stop frees it by)
	built:  bool,
	ready:  bool,
	kept:   bool,
	made:   bool, // set down by /delve here: the session's alone (not in the world's file)
	still:  bool, // ... still: its custodian stands still for a picture, its fight on but idle
	fight:  Boss_Fight,
}

// Plate: a trip plate that clicked: when its darts fly, and when it is armed again.
Plate :: struct {
	at:           game.Block_Pos,
	fires, rearm: u64,
}

// Delves: the home world's delves (the session's state), what they are built of, the key
// their doors take and the plates that clicked.
Delves :: struct {
	all:         [MAX_DELVES_HELD]Delve, // the plan's, then the command's
	count:       int,
	planned:     bool,
	kit:         Delve_Kit,
	key:         game.Item,
	plates:      [MAX_PLATES]Plate,
	plate_count: int,
}

// Delve_Record: which delves the home world has built (its world state's; DELVE_FILE).
Delve_Record :: struct {
	built:  [MAX_DELVES][2]i32, // their stair heads' middles
	count:  int,
	before: bool, // saved before there were delves: none is built in it
	dirty:  bool,
}

delves_of :: proc(s: ^core.Server) -> ^Delves {return &state(s).delves}

// delve_start: what the delves are built of and the key, from the session's registry.
delve_start :: proc(s: ^core.Server) -> bool {
	dv := delves_of(s)
	k := &dv.kit
	reg := s.registry
	block :: proc(reg: ^game.Registry, name: string) -> (game.Block, bool) {
		return game.registry_block(reg, fmt.tprintf("sandbox:%s", name))
	}
	k.slate_bricks = block(reg, "slate_bricks") or_return
	k.slate_tiles = block(reg, "slate_tiles") or_return
	k.slate_cobble = block(reg, "slate_cobble") or_return
	k.basalt_bricks = block(reg, "basalt_bricks") or_return
	k.basalt_tiles = block(reg, "basalt_tiles") or_return
	k.basalt_cobble = block(reg, "basalt_cobble") or_return
	k.dark_bricks = block(reg, "dark_bricks") or_return
	k.polished_slate = block(reg, "polished_slate") or_return
	k.mossy_bricks = block(reg, "mossy_bricks") or_return
	k.moss = block(reg, "moss") or_return
	k.steel = block(reg, "dark_steel") or_return
	k.riveted = block(reg, "riveted_iron") or_return
	k.rust = block(reg, "rusted_iron") or_return
	k.copper = block(reg, "verdigris_copper") or_return
	k.grating = block(reg, "iron_grating") or_return
	k.rune = block(reg, "rune_stone") or_return
	k.salvage_heap = block(reg, "salvage_heap") or_return
	k.alloy_relic = block(reg, "alloy_relic") or_return
	k.relic_vault = block(reg, "relic_vault") or_return
	k.cache = block(reg, "delve_cache") or_return
	k.door = block(reg, "delve_door") or_return
	k.plate = block(reg, "trip_plate") or_return
	k.grid = block(reg, "arc_grid") or_return
	k.ward = game.registry_block(reg, sandbox.WARD_BLOCK) or_return
	dv.key = game.registry_item(reg, DELVE_KEY) or_return
	return true
}

// delve_stop: the drawings kept of built delves.
delve_stop :: proc(s: ^core.Server) {
	dv := delves_of(s)
	for &d in dv.all[:dv.count] {
		delete(d.cells)
		d.cells = nil
	}
}

// delve_tick: the home world's delves planned once its ruin and remains are (ruin_tick and
// remains_tick run first), each kept loaded, built and made ready as players come near, the
// places noted, the traps sprung and the boss's fights run.
delve_tick :: proc(s: ^core.Server) {
	w := s.home
	dv := delves_of(s)
	rec := &world_of(w).delves
	rm := &world_of(w).remains
	r := ruin_of(s)
	ss := &world_of(w).settlements
	if rec.before || !r.placed || (!rm.planned && !rm.before) || (!ss.planned && !ss.before) {
		return
	}
	if !dv.planned {
		gen := worldgen.generator_make(w.generator, terrain_seed(w), s.registry, w.params)
		land := land_of(w)
		sites: [MAX_DELVES]Delve_Site
		camps: [MAX_SETTLEMENTS]Footprint
		for st, i in ss.list[:ss.plan_count] {camps[i] = settlement_footprint(st.middle)}
		n := delve_sites(
			&sites,
			&land,
			&gen,
			w.seed,
			w.spawn.position,
			ruin_footprint(r.site),
			rm,
			camps[:ss.plan_count],
		)
		for site in sites[:n] {
			d := &dv.all[dv.count]
			dv.count += 1
			d.site = site
			d.plan = delve_plan(site.seed)
			d.origin = {
				site.middle.x - d.plan.entry.x,
				site.floor - DELVE_SURFACE,
				site.middle.y - d.plan.entry.y,
			}
			for m in rec.built[:rec.count] {d.built ||= m == site.middle}
			log.infof("delve site middle=%v floor=%d built=%v", site.middle, site.floor, d.built)
		}
		dv.planned = true
	}
	for &d in dv.all[:dv.count] {
		if d.built {
			delve_traps(s, w, &d)
			boss_tick(s, w, &d)
		}
	}
	delve_plates(s, w)
	if s.tick % DELVE_EVERY != 0 {return}
	for &d in dv.all[:dv.count] {
		near := d.fight.on
		for &c in s.clients {
			if c.state != .Playing || c.world != w {continue}
			off := c.player.position.xz - {f64(d.site.middle.x) + 0.5, f64(d.site.middle.y) + 0.5}
			near ||= off.x * off.x + off.y * off.y <= DELVE_REACH * DELVE_REACH
		}
		d.kept = near
		if !near || !core.world_ready(w, delve_area(&d)) {continue}
		if !d.built {
			delve_build(s, w, &d)
			if !d.made {
				rec.built[rec.count] = d.site.middle
				rec.count += 1
				rec.dirty = true
			}
		}
		if !d.ready {delve_ready(s, w, &d)}
		delve_noted(s, w, &d)
	}
}

// delve_area: a delve's whole box, its stair head's levelled ground and the air over it too:
// what must be loaded for it to be built and is kept loaded while a player is near.
delve_area :: proc(d: ^Delve) -> core.Box {
	lo := d.origin
	hi := d.origin + {DELVE_SIDE, DELVE_HEIGHT, DELVE_SIDE} - 1
	hi.y += DELVE_LEVELLED + 2
	return {lo, hi}
}

// delve_build: a delve, whole: the stair head's ground levelled, its layout pasted over what
// was there (the rock between its shells left as it is), its machines posted (none in a world
// whose creatures do not come by themselves: scenes, benchmarks), its stair head humming.
delve_build :: proc(s: ^core.Server, w: ^core.World, d: ^Delve) {
	dv := delves_of(s)
	act := core.game_act(s, w, .Structure)
	m, f := d.site.middle, d.site.floor
	R :: DELVE_LEVELLED
	level := core.Box{{m.x - R, f - 3, m.y - R}, {m.x + R, f + DELVE_HEAD_AIR + R, m.y + R}}
	site_level(w, level, f, act)
	dr := delve_draw(&d.plan, &dv.kit)
	box := core.Box{d.origin, d.origin + dr.t.size - 1}
	core.bulk_edit(w, {shape = box, op = .Paste, template = &dr.t, partial = true}, act)
	if !s.config.no_natural_spawns {
		for p in dr.posts[:dr.post_count] {
			h := core.entity_spawn(
				w,
				state(s).wild[p.which],
				play.place_point(d.origin + p.at),
				false,
			)
			if h != 0 {wild_begin(s, w, p.which, h)}
		}
	}
	d.built = true
	log.infof("delve built middle=%v machines=%d", d.site.middle, dr.post_count)
}

// delve_cells: the delve's blocks as drawn (kept while the session lasts once asked).
delve_cells :: proc(s: ^core.Server, d: ^Delve) -> game.Template {
	size := [3]i32{DELVE_SIDE, DELVE_HEIGHT, DELVE_SIDE}
	if d.cells == nil {
		dr := delve_draw(&d.plan, &delves_of(s).kit)
		d.cells = make([dynamic]u16, len(dr.t.cells))
		copy(d.cells[:], dr.t.cells)
	}
	return {size, d.cells[:]}
}

// delve_ready: a built delve as a session first finds it: anyone standing in its boss's
// chamber or vault (one who was there when the server stopped) set down outside the chamber's
// door, the chamber open, its vault shut, the custodian whole at its post, what a fight left
// there gone, its stair head humming.
delve_ready :: proc(s: ^core.Server, w: ^core.World, d: ^Delve) {
	for &c in s.clients {
		if c.state != .Playing || c.world != w {continue}
		if boss_in_hall(d, c.player.position) || boss_in_vault(d, c.player.position) {
			boss_put_out(s, d, &c)
		}
	}
	boss_reset(s, w, d)
	core.world_hum(w, {d.site.middle.x, d.site.floor + 1, d.site.middle.y}, DELVE_HUM)
	d.ready = true
}

// delve_local: a world block's place in a delve's layout.
delve_local :: proc(d: ^Delve, at: game.Block_Pos) -> [3]i32 {return at - d.origin}

// delve_within: a world block is within a delve's box.
delve_within :: proc(d: ^Delve, at: game.Block_Pos) -> bool {
	l := delve_local(d, at)
	return(
		l.x >= 0 &&
		l.y >= 0 &&
		l.z >= 0 &&
		l.x < DELVE_SIDE &&
		l.y < DELVE_HEIGHT &&
		l.z < DELVE_SIDE \
	)
}

// delve_depth_at: the depth a world block of a delve is in (by its layer; -1: none).
delve_depth_at :: proc(d: ^Delve, at: game.Block_Pos) -> int {
	l := delve_local(d, at)
	for &depth, k in d.plan.depths {
		if l.y >= depth.floor && l.y <= depth.floor + DELVE_BOSS_AIR + 1 {return k}
	}
	return -1
}

// delve_noted: each player within DELVE_NOTED of a built stair head has it in its logbook,
// and each in its third depth has that.
@(private = "file")
delve_noted :: proc(s: ^core.Server, w: ^core.World, d: ^Delve) {
	m := d.site.middle
	deep := &d.plan.depths[DELVE_DEPTHS - 1]
	l := delve_cell(deep.start) * DELVE_CELL + DELVE_MID
	landing := d.origin + {l.x, deep.floor + 1, l.y}
	for &c in s.clients {
		if c.state != .Playing || c.world != w || c.dead {continue}
		off := c.player.position.xz - {f64(m.x) + 0.5, f64(m.y) + 0.5}
		if off.x * off.x + off.y * off.y <= DELVE_NOTED * DELVE_NOTED {
			core.logbook_place(s, &c, .Delve, {m.x, d.site.floor + 1, m.y}, DELVE_STAIR)
		}
		at := play.block_of(c.player.position)
		if delve_within(d, at) && delve_depth_at(d, at) == DELVE_DEPTHS - 1 {
			core.logbook_place(s, &c, .Delve, {landing.x, landing.y, landing.z}, DELVE_DEEP)
		}
	}
}

// delve_holding: which built delve holds a world block in its blocks as drawn, and whether
// it is one of them (not the rock between its shells, not the air in its rooms).
@(private = "file")
delve_holding :: proc(s: ^core.Server, w: ^core.World, at: game.Block_Pos) -> (^Delve, bool) {
	if w != s.home {return nil, false}
	dv := delves_of(s)
	for &d in dv.all[:dv.count] {
		if !d.built || !delve_within(&d, at) {continue}
		t := delve_cells(s, &d)
		cell := cell_at(&t, delve_local(&d, at))
		return &d, cell != game.VOID && cell != u16(game.Block.Air)
	}
	return nil, false
}

// delve_kept: a delve's blocks are not to be broken by a player or a blast (nor its doors,
// its seal and its vault's ward, wherever they stand), but its caches by a hand (a blast
// keeps them: game.odin's kept); what is set down in its air, and taken up again, is.
delve_kept :: proc(
	s: ^core.Server,
	w: ^core.World,
	at: game.Block_Pos,
	old: game.Block,
	blast := false,
) -> string {
	k := &delves_of(s).kit
	d, drawn := delve_holding(s, w, at)
	if d == nil {return ""}
	switch {
	case old == k.ward || old == k.door:
		return "The keepers' work holds"
	case old == k.cache:
		return "The keepers' work holds" if blast else ""
	case old == .Air:
		return ""
	case drawn:
		return "The keepers' work holds"
	}
	return ""
}

// delve_door_use: a locked door used (machine_use): with a keeper's key carried, the key is
// spent and the door (every block of it) opens; else it says what it takes.
delve_door_use :: proc(s: ^core.Server, c: ^core.Client, at: game.Block_Pos) -> string {
	dv := delves_of(s)
	if core.item_count(c, dv.key) == 0 {return "Locked: a keeper's key opens it"}
	core.item_take(s, c, dv.key, 1)
	act := core.game_act(s, c.world, .Structure)
	NEXT :: [6][3]i32{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
	queue: [16]game.Block_Pos
	queue[0] = at
	n := 1
	for i := 0; i < n; i += 1 {
		core.set_block(c.world, queue[i], .Air, act)
		for o in NEXT {
			p := queue[i] + o
			b, _ := core.block_at(c.world, p)
			if b != dv.kit.door || n == len(queue) {continue}
			seen := false
			for q in queue[:n] {seen ||= q == p}
			if !seen {
				queue[n] = p
				n += 1
			}
		}
	}
	core.notice(s, c, "The key turns, and is spent; the door grinds open")
	return ""
}

// delve_spill: a delve's cache broken open at `at` spills what its depth holds (DELVE_LOOT:
// the first depth's outside a delve).
delve_spill :: proc(s: ^core.Server, w: ^core.World, at: game.Block_Pos) {
	depth := 0
	dv := delves_of(s)
	for &d in dv.all[:dv.count] {
		if w == s.home && delve_within(&d, at) {depth = max(delve_depth_at(&d, at), 0)}
	}
	tables := DELVE_LOOT
	rolls := DELVE_ROLLS
	loot: [MAX_LOOT]game.Stack
	n := loot_roll(survival_of(s), &state(s).rng, tables[depth], rolls[depth], &loot, 0)
	centre := [3]f64{f64(at.x) + 0.5, f64(at.y) + 0.5, f64(at.z) + 0.5}
	for st in loot[:n] {core.item_drop(s, w, centre, st)}
}

// delve_traps: each player in the delve's box standing on a trip plate sets it off (once,
// until it is armed again).
@(private = "file")
delve_traps :: proc(s: ^core.Server, w: ^core.World, d: ^Delve) {
	dv := delves_of(s)
	for &c in s.clients {
		if c.state != .Playing || c.world != w || c.dead {continue}
		feet := play.block_of(c.player.position)
		if !delve_within(d, feet) {continue}
		under, _ := core.block_at(w, feet - {0, 1, 0})
		if under == dv.kit.plate {
			at := feet - {0, 1, 0}
			armed := true
			for p in dv.plates[:dv.plate_count] {armed &&= p.at != at}
			if armed && dv.plate_count < MAX_PLATES {
				dv.plates[dv.plate_count] = {
					at,
					s.tick + PLATE_DELAY,
					s.tick + PLATE_DELAY + PLATE_REARM,
				}
				dv.plate_count += 1
				core.notice(s, &c, "Click.")
			}
		}
	}
}

// delve_plates: the plates that clicked fire their darts at whoever is still by them, and are
// armed again in their time.
@(private = "file")
delve_plates :: proc(s: ^core.Server, w: ^core.World) {
	dv := delves_of(s)
	for i := 0; i < dv.plate_count; i += 1 {
		p := &dv.plates[i]
		if s.tick == p.fires {
			from := play.place_point(p.at) + {0, 1.5, 0}
			for &c in s.clients {
				if c.state != .Playing || c.world != w || c.dead {continue}
				off := c.player.position - (play.place_point(p.at) + {0, 1, 0})
				if off.x * off.x + off.z * off.z <= 1.5 * 1.5 && abs(off.y) <= 2 {
					core.player_harm(s, &c, PLATE_HARM, 0, from)
				}
			}
		}
		if s.tick >= p.rearm {
			dv.plates[i] = dv.plates[dv.plate_count - 1]
			dv.plate_count -= 1
			i -= 1
		}
	}
}

// delve_joined: one who joins standing in a boss's chamber with no fight on, or in a shut
// vault, is set down outside the chamber's door (delve_boss.odin: boss_put_out).
delve_joined :: proc(s: ^core.Server, c: ^core.Client) {
	delve_logbook_mend(c)
	if c.world != s.home {return}
	dv := delves_of(s)
	for &d in dv.all[:dv.count] {
		if !d.built || d.fight.on {continue}
		if boss_in_hall(&d, c.player.position) || boss_in_vault(&d, c.player.position) {
			boss_put_out(s, &d, c)
		}
	}
}

// delve_logbook_mend: a logbook kept before delves had a place kind of their own (a stair
// head noted as remains, the third depth as a ruin, each by its name) has them as delves.
delve_logbook_mend :: proc(c: ^core.Client) {
	for &p in c.logbook.places[:c.logbook.place_count] {
		name := game.place_name(&p)
		if p.kind == .Remains && name == DELVE_STAIR || p.kind == .Ruin && name == DELVE_DEEP {
			p.kind = .Delve
		}
	}
}

// unknown_delve: the delve nearest c whose stair head its logbook lacks (what a camp's scout
// sells: talk.odin's mark_delve).
unknown_delve :: proc(s: ^core.Server, c: ^core.Client) -> (^Delve, bool) {
	if c.world != s.home {return nil, false}
	dv := delves_of(s)
	best: ^Delve
	nearest := max(f64)
	for &d in dv.all[:dv.count] {
		at := [3]i32{d.site.middle.x, d.site.floor + 1, d.site.middle.y}
		known := false
		for &p in c.logbook.places[:c.logbook.place_count] {
			off := p.at - at
			known ||=
				p.kind == .Delve &&
				p.world == c.world.address &&
				off.x * off.x + off.z * off.z <= game.PLACE_SAME * game.PLACE_SAME
		}
		far := play.distance_to({f64(at.x), 0, f64(at.z)}, c.player.position)
		if !known && far < nearest {best, nearest = &d, far}
	}
	return best, best != nil
}

// ---- where the delves are ----

// delve_sites: the home world's delves, from its seed alone (the universe's, seed; the land's,
// l's), round its spawn: DELVE_FEWEST or more (as many as MAX_DELVES), each in its own share of
// the compass from a direction of the seed's, at the first of DELVE_TRIES spots DELVE_NEAR to
// DELVE_FAR blocks out whose land suits it (dry and even round the stair head, dry over the
// whole delve and nowhere under its first depth's roof) and where it stands clear of the
// ruin's footprint, the remains, the camps, the generator's structures and the delves before
// it; one
// left out there is tried again anywhere round. How many.
delve_sites :: proc(
	out: ^[MAX_DELVES]Delve_Site,
	l: ^Land,
	gen: ^worldgen.Generator,
	seed: i64,
	spawn: [3]f64,
	ruin: Footprint,
	rm: ^Remains,
	camps: []Footprint,
) -> int {
	rng := base.rng_make(u64(seed) ~ 0xde1e_5175)
	want := base.rng_roll(&rng, DELVE_FEWEST, MAX_DELVES)
	angle := base.rng_f64(&rng) * math.TAU
	share := math.TAU / f64(want)
	n := 0
	for i in 0 ..< want * 2 {
		if n == want {break}
		// First each in its own share of the compass, then (for those left out) anywhere.
		from, width := angle + f64(i) * share, share
		if i >= want {from, width = 0, math.TAU}
		site_seed := base.rng_u64(&rng)
		plan := delve_plan(site_seed)
		for _ in 0 ..< DELVE_TRIES {
			a := from + base.rng_f64(&rng) * width
			d := DELVE_NEAR + base.rng_f64(&rng) * (DELVE_FAR - DELVE_NEAR)
			m := [2]i32 {
				i32(math.floor(spawn.x + base.cos(a) * d)),
				i32(math.floor(spawn.z + base.sin(a) * d)),
			}
			floor, lo, hi, dry := site_ground(l, m.x, m.y, DELVE_LEVELLED)
			if !dry || hi - lo > DELVE_LEVEL {continue}
			at := delve_footprint(m, plan.entry)
			middle := (at.lo + at.hi) / 2
			_, under_lo, _, under_dry := site_ground(l, middle.x, middle.y, DELVE_SIDE / 2)
			if !under_dry || under_lo < floor - DELVE_SINK {continue}
			if !delve_clear(out[:n], gen, at, ruin, rm, camps) {continue}
			out[n] = {m, floor, site_seed}
			n += 1
			break
		}
	}
	return n
}

// delve_footprint: the columns a delve covers whose stair head's middle is m.
delve_footprint :: proc(m, entry: [2]i32) -> Footprint {
	lo := m - entry
	return {lo, lo + DELVE_SIDE - 1}
}

// delve_clear: a delve's footprint keeps DELVE_CLEAR from the ruin's, the remains', the camps'
// and the generator's structures, DELVE_APART from the delves placed before it.
@(private = "file")
delve_clear :: proc(
	before: []Delve_Site,
	gen: ^worldgen.Generator,
	at: Footprint,
	ruin: Footprint,
	rm: ^Remains,
	camps: []Footprint,
) -> bool {
	if footprint_meets(at, ruin, DELVE_CLEAR) {return false}
	for camp in camps {
		if footprint_meets(at, camp, DELVE_CLEAR) {return false}
	}
	for site in rm.sites[:rm.count] {
		if footprint_meets(at, site.at, DELVE_CLEAR) {return false}
	}
	for o in before {
		if footprint_meets(at, delve_footprint(o.middle, delve_plan(o.seed).entry), DELVE_APART) {
			return false
		}
	}
	found := make([dynamic]worldgen.Structure, context.temp_allocator)
	worldgen.structures_near(gen, at.lo - DELVE_CLEAR, at.hi + DELVE_CLEAR, &found)
	return len(found) == 0
}

// ---- the world's file ----

// DELVE_FILE: which delves a world has built (core.World_File: sandbox.delves.txt), as text:
// `before` alone, for a world saved before there were delves (none is ever built in it), or
// a line `built <x> <z>` for each delve built, naming its stair head's middle column.
DELVE_FILE :: "delves.txt"

// delves_load: the home world's file read as it opens. A world without one is new (its delves
// are built as players come near; the file is written at its first save) or from before the
// delves (none is built in it). A damaged file is moved aside and nothing more is built.
delves_load :: proc(s: ^core.Server, w: ^core.World) {
	if w != s.home {return}
	rec := &world_of(w).delves
	data, found := core.world_file_read(w, DELVE_FILE)
	switch {
	case found && !delves_decode(rec, string(data)):
		core.world_file_aside(w, DELVE_FILE)
		rec^ = {}
		rec.before, rec.dirty = true, true
	case found:
	case core.world_made(w):
		rec.dirty = true
	case:
		rec.before, rec.dirty = true, true
	}
}

// delves_write stages the home world's file when it changed (the save hook calls it).
delves_write :: proc(s: ^core.Server, w: ^core.World) {
	if w != s.home {return}
	rec := &world_of(w).delves
	if !rec.dirty {return}
	b := strings.builder_make(context.temp_allocator)
	if rec.before {strings.write_string(&b, "before\n")}
	for m in rec.built[:rec.count] {fmt.sbprintf(&b, "built %d %d\n", m.x, m.y)}
	rec.dirty = !core.world_file_write(w, DELVE_FILE, transmute([]u8)strings.to_string(b))
}

// delves_decode reads a file into rec; false for a line it does not know or more delves than
// a world has.
delves_decode :: proc(rec: ^Delve_Record, text: string) -> bool {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		fields := strings.fields(line, context.temp_allocator)
		switch {
		case len(fields) == 0:
		case len(fields) == 1 && fields[0] == "before":
			rec.before = true
		case len(fields) == 3 && fields[0] == "built" && rec.count < MAX_DELVES:
			x, x_ok := strconv.parse_i64_of_base(fields[1], 10)
			z, z_ok := strconv.parse_i64_of_base(fields[2], 10)
			if !x_ok || !z_ok || abs(x) > i64(max(i32)) || abs(z) > i64(max(i32)) {return false}
			rec.built[rec.count] = {i32(x), i32(z)}
			rec.count += 1
		case:
			return false
		}
	}
	return true
}

// delves_check: is the file whole? (--check: core.World_File.check)
delves_check :: proc(data: []u8) -> bool {
	rec: Delve_Record
	return delves_decode(&rec, string(data))
}

// ---- the command ----

// delve_command: `/delve` lists the home world's delves; `/delve go <n> [landing|deep|hall]`
// takes the player to the n-th's stair head, its first or third depth's landing or into its
// boss's chamber (the teleport permission); `/delve here [seed]` is delve_here.
delve_command :: proc(s: ^core.Server, c: ^core.Client, args: []string) -> bool {
	USAGE :: "Usage: delve [go <n>|last [landing|deep|hall] | here [seed] [still]]"
	if len(args) >= 1 && args[0] == "here" {return delve_here(s, c, args[1:])}
	if !core.allowed(s, c, "teleport.tp") {
		core.notice(s, c, "You may not teleport here")
		return true
	}
	dv := delves_of(s)
	if len(args) == 0 {
		if dv.count == 0 {core.notice(s, c, "This world has no delves")}
		for &d, i in dv.all[:dv.count] {
			m := d.site.middle
			core.notice(
				s,
				c,
				fmt.tprintf(
					"Delve %d: stair head at %d %d %d%s",
					i + 1,
					m.x,
					d.site.floor + 1,
					m.y,
					"" if d.built else " (not built)",
				),
			)
		}
		return true
	}
	if args[0] != "go" || len(args) < 2 || len(args) > 3 {
		core.notice(s, c, USAGE)
		return true
	}
	n, ok := strconv.parse_int(args[1])
	if args[1] == "last" {n, ok = dv.count, true} 	// (the last set down: /delve here)
	if !ok || n < 1 || n > dv.count || c.world != s.home {
		core.notice(s, c, USAGE)
		return true
	}
	d := &dv.all[n - 1]
	spot := args[2] if len(args) == 3 else ""
	head := [3]f64{f64(d.site.middle.x) + 0.5, f64(d.site.floor + 1), f64(d.site.middle.y) + 0.5}
	at, toward := head + {3, 0, 0}, head
	switch spot {
	case "":
	case "landing":
		first := &d.plan.depths[0]
		room := &first.rooms[first.start]
		at = play.place_point(d.origin + {room.lo.x, first.floor + 1, room.lo.y})
		toward = play.place_point(d.origin + {room.hi.x, first.floor + 1, room.hi.y})
	case "deep":
		deep := &d.plan.depths[DELVE_DEPTHS - 1]
		room := &deep.rooms[deep.start]
		at = play.place_point(d.origin + {room.lo.x, deep.floor + 1, room.lo.y})
		toward = play.place_point(d.origin + {room.hi.x, deep.floor + 1, room.hi.y})
	case "hall":
		toward = boss_post_point(d)
		door := boss_toward_door(d)
		at = toward + {door.x * 4, 0, door.y * 4}
	case:
		core.notice(s, c, USAGE)
		return true
	}
	core.teleport(s, c, at, play.look_at(at, toward))
	return true
}

// delve_here: `/delve here [seed] [still]` sets a delve of the seed (1 when none is given) down
// with its stair head at the player's feet, built as a planned one is once its ground is
// loaded, for the session alone (a picture, a try; the bulk edit permission); still, its
// custodian stands still on its feet for a picture.
delve_here :: proc(s: ^core.Server, c: ^core.Client, args: []string) -> bool {
	if !core.allowed(s, c, "world.edit.bulk") {
		core.notice(s, c, "You may not edit in bulk here")
		return true
	}
	dv := delves_of(s)
	seed, still := 1, false
	for a in args {
		n, ok := strconv.parse_int(a)
		switch {
		case a == "still":
			still = true
		case ok && n >= 0:
			seed = n
		case:
			core.notice(s, c, "Usage: delve here [seed] [still]")
			return true
		}
	}
	if len(args) > 2 || c.world != s.home || !dv.planned || dv.count == MAX_DELVES_HELD {
		core.notice(s, c, "No delve can be set down here now")
		return true
	}
	feet := play.block_of(c.player.position)
	d := &dv.all[dv.count]
	dv.count += 1
	d^ = {
		site = {middle = feet.xz, floor = feet.y - 1, seed = u64(seed)},
		plan = delve_plan(u64(seed)),
		made = true,
		still = still,
	}
	d.origin = {feet.x - d.plan.entry.x, feet.y - 1 - DELVE_SURFACE, feet.z - d.plan.entry.y}
	core.notice(s, c, fmt.tprintf("Delve %d set down here", dv.count))
	return true
}
