package hamlet_server

import "core:fmt"
import "core:log"
import "core:strconv"
import "core:strings"

import "common:game"
import "common:protocol"
import "games:hamlet"
import "server:core"
import "server:play"

// Hamlet's server part (the game: games/hamlet). The village is one per session, on the
// home world's flat ground: its land is built from the seed once (town.odin), then the
// players shape it with their requests (roads, zones, buildings, demolition, the
// speed), each checked here (its cost, the placement rules, the permission), and the
// citizens live in it (citizens.odin). The whole village is kept with the universe
// (game.cfg) and comes back after a restart.

GAME :: core.Game {
	info         = hamlet.INFO,
	kinds        = hamlet.KINDS,
	pack         = hamlet.PACK,
	server_state = Town,
	configure    = configure,
	start        = start,
	stop         = stop,
	tick         = tick,
	joined       = joined,
	editing      = editing,
	request      = request,
	command      = command,
	save         = save,
	load         = load,
}

NODE_BUILD :: "world.edit" // roads, zones, buildings: what any joined player may do
NODE_DEMOLISH :: "hamlet.demolish" // taking things down (the host's, a mod's)
NODE_SPEED :: "hamlet.speed" // the simulation's speed (the host's, a mod's)

Phase :: enum u8 {
	Building, // the land is being made
	Running,
}

Structure :: struct {
	used:     bool,
	kind:     hamlet.Kind,
	at:       [2]i32, // the lowest corner's tile
	rotation: u8,
	floor:    i32, // the y its shape stands on
	workers:  int,
	people:   int, // a house's
}

Town :: struct {
	phase:        Phase,
	built:        bool, // the land is in the world (a loaded universe's already is)
	ground:       hamlet.Ground,
	tiles:        hamlet.Tiles,
	owner:        [hamlet.MAP][hamlet.MAP]i16, // [z][x]: the structure on it (-1: none)
	structures:   [hamlet.MAX_STRUCTURES]Structure,
	count:        int, // structures[:count] are used or free
	citizens:     [hamlet.MAX_CITIZENS]Citizen,
	population:   int,
	respawn:      bool, // the loaded citizens wait for their entities
	stock:        [hamlet.Good]int,
	delivered:    [hamlet.Good]int, // brought to the storehouses this session (tests, F3)
	steps:        u64,
	day:          int,
	milestone:    int,
	happiness:    int,
	templates:    [hamlet.Kind]game.Template, // (heap: stop frees them)
	citizen_kind: game.Kind_Id,
	road, grass:  game.Block,
	dirt, water:  game.Block,
	log, leaves:  game.Block,
	stone:        game.Block,
}

state :: proc(s: ^core.Server) -> ^Town {return core.game_state(s, Town)}

// configure: a flat world of the game's own, every universe planned from above (a
// mode asked for is not kept: a planner has no body).
configure :: proc(config: ^core.Config) {
	config.mode = hamlet.PLANNER_MODE
	play.configure_flat(config, {f64(hamlet.MAP / 2) + 0.5, 0, f64(hamlet.MAP / 2) + 0.5}, "")
}

start :: proc(s: ^core.Server) -> bool {
	t := state(s)
	w := s.home
	play.world_still(s, w, clock = 0.42)
	core.game_rule(s, w, "fly_speed", "24") // (the planner's panning)
	core.game_rule(s, w, "fly_sprint_speed", "60")
	reg := s.registry
	t.citizen_kind = game.registry_kind(reg, hamlet.CITIZEN_KIND) or_return
	t.road = game.registry_block(reg, hamlet.ROAD_BLOCK) or_return
	t.grass = game.registry_block(reg, "grass") or_return
	t.dirt = game.registry_block(reg, "dirt") or_return
	t.water = game.registry_block(reg, "water") or_return
	t.log = game.registry_block(reg, "log") or_return
	t.leaves = game.registry_block(reg, "leaves") or_return
	t.stone = game.registry_block(reg, "stone") or_return
	for &tmpl, k in t.templates {tmpl = hamlet.template_shape(reg, k) or_return}
	hamlet.ground_make(&t.ground, u32(s.config.seed))
	t.tiles = t.ground.tiles
	for &row in t.owner {for &o in row {o = -1}}
	t.stock = hamlet.START_STOCK
	t.happiness = 60
	core.world_keep(w, AREA)
	log.infof("hamlet started seed=%d", s.config.seed)
	return true
}

stop :: proc(s: ^core.Server) {
	t := state(s)
	for &tmpl in t.templates {delete(tmpl.cells)}
	log.infof("hamlet stopped population=%d day=%d", t.population, t.day)
}

tick :: proc(s: ^core.Server) {
	t := state(s)
	switch t.phase {
	case .Building:
		if !t.built {t.built = ground_build(s)}
		if t.built && core.world_ready(s.home, AREA) {
			t.phase = .Running
			if t.respawn {respawn(s)}
		}
	case .Running:
		for _ in 0 ..< s.sim_steps {town_step(s)}
	}
	put_records(s)
}

// town_step: one step of the village's life (sim_steps of them a tick).
town_step :: proc(s: ^core.Server) {
	t := state(s)
	t.steps += 1
	for &c, i in t.citizens {if c.id != 0 {citizen_step(s, i)}}
	if t.steps % hamlet.GROW_STEPS == 0 {grow(s)}
	if t.steps % hamlet.ARRIVE_STEPS == 0 {arrive(s)}
	if t.steps % hamlet.DAY_STEPS == 0 {day_end(s)}
}

// respawn: the citizens a loaded village kept stand at their homes' doors again.
respawn :: proc(s: ^core.Server) {
	t := state(s)
	t.respawn = false
	for &c in t.citizens {
		if c.id == 0 {continue}
		door, ok := structure_access(t, c.home)
		if !ok {door = center(&t.structures[c.home])}
		h := core.entity_spawn(s.home, t.citizen_kind, citizen_point(t, door), false)
		if h == 0 {continue}
		core.entity_set_speed(s.home, h, hamlet.WALK_SPEED)
		c.id, c.at, c.state, c.timer, c.carrying =
			core.entity_id(s.home, h), door, .Home, hamlet.REST_STEPS, 0
	}
}

joined :: proc(s: ^core.Server, c: ^core.Client) {
	core.game_mode(s, c, hamlet.PLANNER_MODE)
	t := state(s)
	m := i32(hamlet.MAP / 2)
	at := [3]f64{f64(m) + 0.5, f64(hamlet.ground_top(&t.ground, m, m) + 1), f64(m) + 0.5}
	core.teleport(s, c, at, {0, -0.8}, flying = true)
	core.notice(
		s,
		c,
		"Hamlet: lay roads, zone homes, build a well, a farm and a storehouse; people come",
	)
}

// editing: the village's blocks are the game's; the planner has no hands.
editing :: proc(
	s: ^core.Server,
	c: ^core.Client,
	at: game.Block_Pos,
	old, new: game.Block,
) -> string {
	return "Build with the toolbar"
}

// request: what a player's toolbar asked, judged: who may, what it costs, where it goes.
request :: proc(s: ^core.Server, c: ^core.Client, r: core.Request) {
	t := state(s)
	if t.phase != .Running {return}
	if v, ok := core.request_value(s, r, hamlet.Lay_Road); ok {
		if !core.allowed(s, c, NODE_BUILD) {core.notice(s, c, "You may not build here"); return}
		if refusal := lay_road(s, {i32(v.from.x), i32(v.from.y)}, {i32(v.to.x), i32(v.to.y)});
		   refusal != "" {
			core.notice(s, c, refusal)
		}
	}
	if v, ok := core.request_value(s, r, hamlet.Zone); ok {
		if !core.allowed(s, c, NODE_BUILD) {core.notice(s, c, "You may not build here"); return}
		zone(s, {i32(v.from.x), i32(v.from.y)}, {i32(v.to.x), i32(v.to.y)}, v.clear)
	}
	if v, ok := core.request_value(s, r, hamlet.Build); ok {
		if !core.allowed(s, c, NODE_BUILD) {core.notice(s, c, "You may not build here"); return}
		if refusal := build(s, v.kind, {i32(v.at.x), i32(v.at.y)}, v.rotation); refusal != "" {
			core.notice(s, c, refusal)
		}
	}
	if v, ok := core.request_value(s, r, hamlet.Demolish); ok {
		if !core.allowed(s, c, NODE_DEMOLISH) {
			core.notice(s, c, "You may not demolish (hamlet.demolish)")
			return
		}
		demolish(s, {i32(v.at.x), i32(v.at.y)})
	}
	if v, ok := core.request_value(s, r, hamlet.Set_Speed); ok {
		if !core.allowed(s, c, NODE_SPEED) {
			core.notice(s, c, "You may not change the speed (hamlet.speed)")
			return
		}
		core.sim_speed_set(s, int(v.speed))
	}
}

// lay_road: a road along the L from a to b, all or none: every tile must be open
// (grass, zoned or road already); the road is free.
lay_road :: proc(s: ^core.Server, a, b: [2]i32) -> string {
	t := state(s)
	tiles := hamlet.road_path(a, b)
	if refusal := hamlet.road_refusal(&t.tiles, tiles); refusal != "" {return refusal}
	road_lay(s, tiles)
	return ""
}

// zone: the rectangle's open tiles zoned for homes (or unzoned).
zone :: proc(s: ^core.Server, a, b: [2]i32, clear: bool) {
	t := state(s)
	for z in max(min(a.y, b.y), 0) ..= min(max(a.y, b.y), hamlet.MAP - 1) {
		for x in max(min(a.x, b.x), 0) ..= min(max(a.x, b.x), hamlet.MAP - 1) {
			if clear && t.tiles[z][x] == .Zone {tile_set(t, x, z, .Grass)}
			if !clear && t.tiles[z][x] == .Grass {tile_set(t, x, z, .Zone)}
		}
	}
}

// build: a workplace (or a well, a market, a storehouse) placed, paid for from the
// stock; refused, it costs nothing.
build :: proc(s: ^core.Server, kind: hamlet.Kind, at: [2]i32, rotation: u8) -> string {
	t := state(s)
	info := &hamlet.KINDS_INFO[kind]
	if !info.placed {return "That grows by itself"}
	if !hamlet.can_afford(t.stock, info.cost) {
		return fmt.tprintf(
			"Not enough in stock: %s needs %d wood and %d stone",
			info.name,
			info.cost[.Wood],
			info.cost[.Stone],
		)
	}
	floor, refusal := fit(s, kind, at, rotation, {.Grass})
	if refusal != "" {return refusal}
	if structure_add(s, kind, at, rotation, floor) < 0 {return "The village has no room for more"}
	for n, g in info.cost {t.stock[g] -= n}
	return ""
}

// demolish: what is on the tile goes: a road, a zone, a structure (half its cost back).
demolish :: proc(s: ^core.Server, p: [2]i32) {
	t := state(s)
	switch tile(t, p.x, p.y) {
	case .Road:
		road_take(s, p)
	case .Zone:
		tile_set(t, p.x, p.y, .Grass)
	case .House, .Building:
		i := int(t.owner[p.y][p.x])
		if i < 0 || !t.structures[i].used {return}
		for n, g in hamlet.KINDS_INFO[t.structures[i].kind].cost {t.stock[g] += n / 2}
		structure_take(s, i)
	case .Grass, .Water, .Tree, .Rock:
	}
}

// put_records: the town, the map's rows and the structures to every player (only what
// changed travels).
put_records :: proc(s: ^core.Server) {
	t := state(s)
	town := hamlet.Town {
		population = u16(t.population),
		happiness  = u8(clamp(t.happiness, 0, 100)),
		speed      = u8(s.sim_speed),
		day        = u32(t.day),
		milestone  = u8(t.milestone),
		seed       = u32(s.config.seed),
	}
	for n, g in t.stock {town.stock[g] = u32(max(n, 0))}
	for &st, k in t.structures[:t.count] {
		if !st.used {continue}
		info := &hamlet.KINDS_INFO[st.kind]
		town.jobs += u16(info.jobs)
		town.workers += u16(st.workers)
		if st.kind == .House && watered(t, k) {town.housing += u16(info.homes)}
	}
	happy: [hamlet.MAP][hamlet.MAP]u8
	for &c in t.citizens {
		if c.id == 0 || c.home < 0 {continue}
		st := &t.structures[c.home]
		size := hamlet.footprint(st.kind, st.rotation)
		for z in st.at.y ..< st.at.y + size.y {
			for x in st.at.x ..< st.at.x + size.x {happy[z][x] = u8(clamp(c.happiness, 1, 100))}
		}
	}
	for &cl in s.clients {
		if cl.state != .Playing || cl.world != s.home {continue}
		core.game_put(s, &cl, &town)
		for z in 0 ..< hamlet.MAP {
			row := hamlet.Row {
				tiles = t.tiles[z],
				happy = happy[z],
			}
			core.game_put(s, &cl, &row, protocol.key_entity(u32(z)))
		}
		for &st, k in t.structures[:t.count] {
			if !st.used {continue}
			r := hamlet.Structure_Record {
				kind     = st.kind,
				at       = {i16(st.at.x), i16(st.at.y)},
				floor    = i16(st.floor),
				rotation = st.rotation,
				workers  = u8(clamp(st.workers, 0, 255)),
				people   = u8(clamp(st.people, 0, 255)),
			}
			core.game_put(s, &cl, &r, protocol.key_entity(u32(k)))
		}
	}
}

// command: /hamlet says how the village is; the host's (hamlet.speed): /hamlet stock
// <wood> <stone> <food> sets the stock, /hamlet speed <0..4> the speed, /hamlet plan
// lays out a village (roads, zones,
// wells, farms, a storehouse, a market, a woodcutter and a quarry where they fit), for
// trying things and for the pictures.
command :: proc(s: ^core.Server, c: ^core.Client, name: string, args: []string) -> bool {
	if name != "hamlet" {return false}
	t := state(s)
	host := core.allowed(s, c, NODE_SPEED)
	if len(args) == 4 && args[0] == "stock" && host {
		for g, i in ([3]hamlet.Good{.Wood, .Stone, .Food}) {
			n, ok := strconv.parse_int(args[i + 1])
			if ok && n >= 0 {t.stock[g] = n}
		}
	}
	if len(args) == 1 && args[0] == "plan" && host && t.phase == .Running {plan(s)}
	if len(args) == 2 && args[0] == "speed" && host {
		if n, ok := strconv.parse_int(args[1]); ok {core.sim_speed_set(s, n)}
	}
	core.notice(
		s,
		c,
		fmt.tprintf(
			"Hamlet day %d: %d people, wood %d, stone %d, food %d, happiness %d",
			t.day,
			t.population,
			t.stock[.Wood],
			t.stock[.Stone],
			t.stock[.Food],
			t.happiness,
		),
	)
	return true
}

// plan: a village laid out as a player would, through the same rules: three streets
// and three cross streets (each block of road laid where it may go), the land between
// them zoned, and the buildings each at the first place by a road where it fits.
plan :: proc(s: ^core.Server) {
	t := state(s)
	t.stock = #partial {
		.Wood  = 400,
		.Stone = 300,
		.Food  = 600,
	}
	lo, hi := i32(hamlet.MAP / 2 - 18), i32(hamlet.MAP / 2 + 18)
	for z := lo; z <= hi; z += 9 {
		for x := lo; x < hi; x += 4 {lay_road(s, {x, z}, {min(x + 4, hi), z})}
	}
	for x := lo; x <= hi; x += 12 {
		for z := lo; z < hi; z += 3 {lay_road(s, {x, z}, {x, min(z + 3, hi)})}
	}
	KINDS :: [?]hamlet.Kind {
		.Storehouse,
		.Well,
		.Well,
		.Well,
		.Farm,
		.Farm,
		.Farm,
		.Farm,
		.Market,
		.Woodcutter,
		.Quarry,
	}
	for kind in KINDS {
		size := hamlet.footprint(kind, 0)
		search: for z in i32(2) ..< hamlet.MAP - 6 {
			for x in i32(2) ..< hamlet.MAP - 6 {
				at := [2]i32{x, z}
				if _, ok := hamlet.access(&t.tiles, at, size); !ok {continue}
				if build(s, kind, at, 0) == "" {break search}
			}
		}
	}
	zone(s, {lo, lo}, {hi, hi}, false)
}

// save: the whole village as text (game.cfg): its seed, its stock and its clock, each
// row of the map, each structure and each citizen.
//
//	hamlet 1
//	seed <seed>
//	stock <wood> <stone> <food>
//	clock <steps> <day> <milestone> <speed>
//	row <z> <a tile's number for each x>
//	structure <index> <kind> <x> <z> <rotation> <floor>
//	citizen <home> <job> <hungry> <happiness>
save :: proc(s: ^core.Server, out: ^strings.Builder) {
	t := state(s)
	fmt.sbprintln(out, "hamlet 1")
	fmt.sbprintfln(out, "seed %d", s.config.seed)
	fmt.sbprintfln(out, "stock %d %d %d", t.stock[.Wood], t.stock[.Stone], t.stock[.Food])
	fmt.sbprintfln(out, "clock %d %d %d %d", t.steps, t.day, t.milestone, s.sim_speed)
	for z in 0 ..< hamlet.MAP {
		fmt.sbprintf(out, "row %d ", z)
		for v in t.tiles[z] {strings.write_byte(out, '0' + u8(v))}
		strings.write_byte(out, '\n')
	}
	for &st, k in t.structures[:t.count] {
		if !st.used {continue}
		fmt.sbprintfln(
			out,
			"structure %d %d %d %d %d %d",
			k,
			int(st.kind),
			st.at.x,
			st.at.y,
			st.rotation,
			st.floor,
		)
	}
	for &c in t.citizens {
		if c.id == 0 {continue}
		fmt.sbprintfln(out, "citizen %d %d %d %d", c.home, c.job, c.hungry, c.happiness)
	}
}

// load: the village a universe kept; a line Hamlet does not know, or a number out of its
// bounds, is not Hamlet's. The land is already in the world; the citizens' entities are
// made again at their homes once it is loaded.
load :: proc(s: ^core.Server, text: string) -> bool {
	t := state(s)
	rest := text
	ints :: proc(fields: []string, out: []int) -> bool {
		if len(fields) != len(out) {return false}
		for f, i in fields {out[i] = strconv.parse_int(f) or_return}
		return true
	}
	seen_header := false
	citizens := 0
	for line in strings.split_lines_iterator(&rest) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) == 0 {continue}
		n: [8]int
		switch f[0] {
		case "hamlet":
			seen_header = len(f) == 2 && f[1] == "1"
		case "seed":
			if !ints(f[1:], n[:1]) || i64(n[0]) != s.config.seed {return false}
		case "stock":
			if !ints(f[1:], n[:3]) {return false}
			t.stock = {
				.None  = 0,
				.Wood  = n[0],
				.Stone = n[1],
				.Food  = n[2],
			}
		case "clock":
			if !ints(f[1:], n[:4]) || n[3] < 0 || n[3] > core.MAX_SIM_SPEED {return false}
			t.steps, t.day, t.milestone = u64(n[0]), n[1], n[2]
			core.sim_speed_set(s, n[3])
		case "row":
			if len(f) != 3 ||
			   !ints(f[1:2], n[:1]) ||
			   n[0] < 0 ||
			   n[0] >= hamlet.MAP ||
			   len(f[2]) != hamlet.MAP {
				return false
			}
			for ch, x in transmute([]u8)f[2] {
				if ch < '0' || int(ch - '0') >= len(hamlet.Tile) {return false}
				t.tiles[n[0]][x] = hamlet.Tile(ch - '0')
			}
		case "structure":
			if !ints(f[1:], n[:6]) {return false}
			k := n[0]
			if k < 0 ||
			   k >= hamlet.MAX_STRUCTURES ||
			   n[1] < 0 ||
			   n[1] >= len(hamlet.Kind) ||
			   n[4] < 0 ||
			   n[4] > 3 {
				return false
			}
			t.structures[k] = {
				used     = true,
				kind     = hamlet.Kind(n[1]),
				at       = {i32(n[2]), i32(n[3])},
				rotation = u8(n[4]),
				floor    = i32(n[5]),
			}
			t.count = max(t.count, k + 1)
		case "citizen":
			if !ints(f[1:], n[:4]) || citizens >= hamlet.MAX_CITIZENS {return false}
			home, job := n[0], n[1]
			if home < 0 ||
			   home >= hamlet.MAX_STRUCTURES ||
			   job < -1 ||
			   job >= hamlet.MAX_STRUCTURES {
				return false
			}
			t.citizens[citizens] = {
				id        = 1, // (a placeholder: respawn makes its entity)
				home      = home,
				job       = job,
				hungry    = n[2],
				happiness = n[3],
			}
			citizens += 1
		case:
			return false
		}
	}
	if !seen_header {return false}
	// The owners of the tiles, the counts, from the structures and the citizens.
	for &st, k in t.structures[:t.count] {
		if !st.used {continue}
		size := hamlet.footprint(st.kind, st.rotation)
		for z in st.at.y ..< st.at.y + size.y {
			for x in st.at.x ..< st.at.x + size.x {
				if !hamlet.on_map(x, z) {return false}
				t.owner[z][x] = i16(k)
			}
		}
	}
	for &c in t.citizens[:citizens] {
		if !t.structures[c.home].used || (c.job >= 0 && !t.structures[c.job].used) {return false}
		t.structures[c.home].people += 1
		if c.job >= 0 {t.structures[c.job].workers += 1}
	}
	t.population = citizens
	t.built, t.respawn = true, true
	return true
}
