package foundry_server

import "core:fmt"
import "core:strconv"
import "core:strings"

import "common:base"
import "common:game"
import "common:protocol"
import "games:foundry"
import "server:core"
import "server:grid"
import "server:play"

// Foundry's server part: the map from the seed, the factory's machines (machines.odin), its
// power, research and goal, what each player asked of it (its requests) and what is kept
// with the universe. The factory is the world's blocks and machines; what is the game's
// beyond them (research, the goal, the clock, the builders) is game.cfg's.

GAME :: core.Game {
	info          = foundry.INFO,
	kinds         = foundry.KINDS,
	pack          = foundry.PACK,
	server_state  = Foundry,
	machine_data  = Machine,
	machine_shown = foundry.Shown,
	stats         = STATS,
	configure     = configure,
	start         = start,
	stop          = stop,
	tick          = tick,
	joined        = joined,
	command       = command,
	request       = request,
	block_changed = block_changed,
	machines      = think,
	machine_use   = machine_use,
	world_opened  = world_opened,
	save          = save,
	load          = load,
}

STATS :: []core.Game_Stat{{"foundry.crafted", .Count, 1}, {"foundry.placed", .Count, 1}}

NODE_ADMIN :: "foundry.admin"
MAX_BUILDERS :: 64

Builder_Row :: struct {
	crafted: u32,
	placed:  u32,
}

Foundry :: struct {
	settings:  foundry.Settings,
	built:     bool, // the map is in the world (a loaded universe's already is)
	kinds:     map[game.Block_Type]foundry.Kind, // the machines' block types (heap)
	belt:      game.Block,
	pole:      game.Block,
	ores:      [3]game.Block,
	fuel:      game.Item,
	insight:   game.Item,
	theory:    game.Item,
	goal_item: game.Item,
	grid:      int, // the power grid (core.grid_open)
	power:     map[u32]Part_Power, // by part of the grid, balanced once a second (heap)
	status:    foundry.Status,
	ticks:     u64, // the factory's ticks since it began (kept)
	builders:  play.By_Name(Builder_Row, MAX_BUILDERS),
	panels:    [dynamic]Open_Panel, // who has which machine open (heap)
}

// Part_Power: a part of the grid this second: what its generators give and its machines ask.
Part_Power :: struct {
	supply, demand: u32,
	ratio:          f32, // what the machines get of what they ask (0..1)
	load:           f32, // what the generators give of what they could (0..1)
}

Open_Panel :: struct {
	who: core.Player_Ref,
	at:  game.Block_Pos,
}

state :: proc(s: ^core.Server) -> ^Foundry {return core.game_state(s, Foundry)}

configure :: proc(config: ^core.Config) {
	play.configure_flat(config, foundry.SPAWN, foundry.MODE)
}

start :: proc(s: ^core.Server) -> bool {
	f := state(s)
	reg := s.registry
	f.settings = foundry.DEFAULT_SETTINGS
	f.kinds = make(map[game.Block_Type]foundry.Kind)
	for id, k in foundry.KIND_BLOCKS {
		if k == .None {continue}
		b := game.registry_block(reg, id) or_return
		f.kinds[reg.blocks.type_of[b]] = k
	}
	f.belt = game.registry_block(reg, foundry.BELT_BLOCK) or_return
	f.pole = game.registry_block(reg, foundry.POLE_BLOCK) or_return
	for id, i in foundry.ORES {f.ores[i] = game.registry_block(reg, id) or_return}
	f.fuel = game.registry_item(reg, foundry.FUEL) or_return
	f.insight = game.registry_item(reg, foundry.INSIGHT) or_return
	f.theory = game.registry_item(reg, foundry.THEORY) or_return
	f.goal_item = game.registry_item(reg, foundry.GOAL_ITEM) or_return
	f.power = make(map[u32]Part_Power)
	f.panels = make([dynamic]Open_Panel)
	play.world_rule(s, s.home, "daylight_cycle", false)
	s.home.clock = 0.45
	core.world_keep(s.home, AREA)
	return true
}

stop :: proc(s: ^core.Server) {
	f := state(s)
	delete(f.kinds)
	delete(f.power)
	delete(f.panels)
}

// world_opened: the world's power grid: poles reach POLE_REACH, machines that draw power
// (and generators) join it.
world_opened :: proc(s: ^core.Server, w: ^core.World) {
	if w != s.home {return}
	f := state(s)
	t := &s.registry.blocks
	kinds := make([dynamic]grid.Kind, context.temp_allocator)
	append(&kinds, grid.Kind{type = t.type_of[f.pole], reach = foundry.POLE_REACH})
	for type, k in f.kinds {
		if foundry.DRAW_KW[k] > 0 ||
		   k == .Generator {append(&kinds, grid.Kind{type = type, node = true})}
	}
	f.grid = core.grid_open(w, kinds[:])
}

// AREA: the map, kept loaded while it is built.
AREA :: core.Box {
	{0, foundry.GROUND - 4, 0},
	{foundry.MAP - 1, foundry.GROUND + 8, foundry.MAP - 1},
}

tick :: proc(s: ^core.Server) {
	f := state(s)
	if !f.built {
		f.built = map_build(s)
		if f.built {core.world_release(s.home)}
		return
	}
	if s.sim_steps == 0 {return}
	if !f.status.done {f.ticks += 1}
	if s.tick % game.TICK_RATE == 0 {power_balance(s)}
	status_put(s)
}

joined :: proc(s: ^core.Server, c: ^core.Client) {
	play.by_name(&state(s).builders, core.client_name(c), make_it = true)
}

// status_put: the factory's status to everyone, the builders' rows, each open panel.
status_put :: proc(s: ^core.Server) {
	f := state(s)
	st := &f.status
	st.goal = u16(f.settings.goal)
	st.seconds = u32(f.ticks / game.TICK_RATE)
	for &c in s.clients {
		if c.state != .Playing {continue}
		core.game_put(s, &c, st)
		for &r in play.by_name_rows(&f.builders) {
			if other := client_named(s, play.named_name(&r)); other != nil {
				b := foundry.Builder{play.named_name(&r), r.crafted, r.placed}
				core.game_put(s, &c, &b, protocol.key_player(core.player_id(s, other)))
			}
		}
	}
	for i := 0; i < len(f.panels); {
		p := f.panels[i]
		c := core.player_of(s, p.who)
		if c == nil {
			unordered_remove(&f.panels, i)
			continue
		}
		panel := panel_of(s, p.at)
		core.game_put(s, c, &panel)
		if !panel.open {
			unordered_remove(&f.panels, i)
			continue
		}
		i += 1
	}
}

client_named :: proc(s: ^core.Server, name: string) -> ^core.Client {
	for &c in s.clients {if c.state == .Playing && core.client_name(&c) == name {return &c}}
	return nil
}

// block_changed: a player who built a machine or a belt is counted for it.
block_changed :: proc(s: ^core.Server, w: ^core.World, change: core.Block_Change) {
	f := state(s)
	if change.by == nil || change.bulk {return}
	t := &s.registry.blocks
	_, machine := f.kinds[t.type_of[change.new]]
	if !machine && t.type_of[change.new] != t.type_of[f.belt] {return}
	if t.type_of[change.old] == t.type_of[change.new] {return} 	// (a turn)
	core.stat_count(s, change.by, "foundry.placed", 1)
	if r := play.by_name(&f.builders, core.client_name(change.by), make_it = true); r != nil {
		r.placed += 1
	}
}

command :: proc(s: ^core.Server, c: ^core.Client, name: string, args: []string) -> bool {
	if name != "foundry" {return false}
	f := state(s)
	table := foundry.settings_table()
	if handled, _ := play.settings_command(s, c, table, &f.settings, NODE_ADMIN, args); handled {
		return true
	}
	if !core.allowed(s, c, NODE_ADMIN) {
		core.notice(s, c, "Foundry: that is the host's")
		return true
	}
	switch {
	case len(args) == 1 && args[0] == "demo":
		demo_build(s, c)
		core.notice(s, c, "Foundry: a line built by the spawn")
	case len(args) == 2 && args[0] == "give":
		item, found := game.registry_item(s.registry, args[1])
		if !found {item, found = game.registry_item(s.registry, strings.concatenate({"foundry:", args[1]}, context.temp_allocator))}
		if !found {
			core.notice(s, c, "Foundry: no such item")
			return true
		}
		core.item_give(s, c, item, 50)
	case len(args) == 2 && args[0] == "research":
		n, ok := strconv.parse_int(args[1])
		if !ok || n < 0 || n > len(foundry.Research) {
			core.notice(s, c, "Foundry: research <0..8> (how many are done, in order)")
			return true
		}
		f.status.studied = u8((1 << uint(n)) - 1)
		study_next(f)
	case:
		core.notice(
			s,
			c,
			fmt.tprintf(
				"Foundry: demo | give <item> | research <n> | %s",
				play.settings_usage(table),
			),
		)
	}
	return true
}

// ---- what is kept: game.cfg ----

save :: proc(s: ^core.Server, out: ^strings.Builder) {
	f := state(s)
	play.settings_save(foundry.settings_table(), &f.settings, out)
	st := &f.status
	fmt.sbprintfln(out, "built = %v", f.built)
	fmt.sbprintfln(out, "ticks = %d", f.ticks)
	fmt.sbprintfln(out, "made = %d", st.made)
	fmt.sbprintfln(out, "done = %v", st.done)
	fmt.sbprintfln(out, "studied = %d", st.studied)
	fmt.sbprintfln(out, "studying = %d %d", int(st.studying), st.progress)
	play.by_name_save(
		&f.builders,
		"builder",
		out,
		proc(b: ^strings.Builder, v: ^Builder_Row) -> bool {
			fmt.sbprintf(b, "%d %d", v.crafted, v.placed)
			return true
		},
	)
}

load :: proc(s: ^core.Server, text: string) -> bool {
	f := state(s)
	own := play.settings_read(foundry.settings_table(), &f.settings, text) or_return
	st := &f.status
	for l in own {
		switch l.key {
		case "built":
			f.built = l.value == "true"
			if f.built {core.world_release(s.home)}
		case "ticks":
			f.ticks = strconv.parse_u64(l.value) or_else 0
		case "made":
			st.made = u16(clamp(strconv.parse_int(l.value) or_else 0, 0, 1000))
		case "done":
			st.done = l.value == "true"
		case "studied":
			st.studied = u8(clamp(strconv.parse_int(l.value) or_else 0, 0, 255))
		case "studying":
			fields := strings.fields(l.value, context.temp_allocator)
			if len(fields) != 2 {return false}
			r := strconv.parse_int(fields[0]) or_else -1
			if r < 0 || r >= len(foundry.Research) {return false}
			st.studying = foundry.Research(r)
			st.progress = u16(clamp(strconv.parse_int(fields[1]) or_else 0, 0, 1000))
		case "builder":
			play.by_name_read(
				&f.builders,
				"builder",
				l,
				proc(fields: []string, v: ^Builder_Row) -> bool {
					if len(fields) != 2 {return false}
					v.crafted = u32(strconv.parse_uint(fields[0]) or_else 0)
					v.placed = u32(strconv.parse_uint(fields[1]) or_else 0)
					return true
				},
			) or_return
		case:
			return false
		}
	}
	return true
}

// ---- the map ----

// map_build: the flat ground's ores, rocks, trees and pond, from the seed, once its chunks
// are there (false: not yet).
map_build :: proc(s: ^core.Server) -> bool {
	w := s.home
	if !core.world_ready(w, AREA) {return false}
	f := state(s)
	reg := s.registry
	act := core.game_act(s, w, .Structure)
	set :: proc(w: ^core.World, lo, hi: game.Block_Pos, b: game.Block, act: core.Act) {
		core.bulk_edit(w, {shape = core.Box{lo, hi}, op = .Set, block = b}, act)
	}
	rng := base.rng_make(u64(s.config.seed) ~ 0xf0_0d)
	g :: foundry.GROUND
	// The ores: two patches of each, ember nearest the spawn, the ground's top three deep.
	for ore, i in f.ores {
		for k in 0 ..< 2 {
			angle := f64(i) * 2.1 + f64(k) * 3.14 + base.rng_f64(&rng)
			reach := 12.0 + f64(i) * 6 + f64(k) * 14
			cx := i32(48 + reach * base.cos(angle))
			cz := i32(48 + reach * base.sin(angle))
			r := i32(3 + base.rng_u32(&rng) % 2)
			for dz in -r ..= r {
				for dx in -r ..= r {
					if dx * dx + dz * dz > r * r + 1 {continue}
					set(w, {cx + dx, g - 2, cz + dz}, {cx + dx, g, cz + dz}, ore, act)
				}
			}
		}
	}
	cobble := game.registry_block(reg, "cobblestone") or_return
	log := game.registry_block(reg, "log") or_return
	leaves := game.registry_block(reg, "leaves") or_return
	water := game.registry_block(reg, "water") or_return
	sand := game.registry_block(reg, "sand") or_return
	// Rocks of cobblestone, trees, a pond with a sandy shore.
	for _ in 0 ..< 10 {
		x, z := 8 + i32(base.rng_u32(&rng) % 80), 8 + i32(base.rng_u32(&rng) % 80)
		if abs(x - 48) < 6 && abs(z - 48) < 6 {continue}
		set(w, {x, g + 1, z}, {x + 1, g + 1 + i32(base.rng_u32(&rng) % 2), z + 1}, cobble, act)
	}
	for _ in 0 ..< 14 {
		x, z := 4 + i32(base.rng_u32(&rng) % 88), 4 + i32(base.rng_u32(&rng) % 88)
		if abs(x - 48) < 8 && abs(z - 48) < 8 {continue}
		set(w, {x - 1, g + 3, z - 1}, {x + 1, g + 4, z + 1}, leaves, act)
		set(w, {x, g + 5, z}, {x, g + 5, z}, leaves, act)
		set(w, {x, g + 1, z}, {x, g + 3, z}, log, act)
	}
	px, pz := i32(70), i32(24)
	set(w, {px - 6, g, pz - 5}, {px + 6, g, pz + 5}, sand, act)
	set(w, {px - 4, g - 1, pz - 3}, {px + 4, g, pz + 3}, water, act)
	return true
}

play_row :: proc(f: ^Foundry, c: ^core.Client) -> ^play.Named(Builder_Row) {
	return play.by_name(&f.builders, core.client_name(c), make_it = true)
}

// demo_build: a working line by the spawn, on an ember patch of its own: a miner onto a belt,
// an arm into a furnace and out to a crate; a crate of bars an arm feeds an assembler making
// gears, out to another crate; a lab with insight; a generator with peat and a pole that
// reaches them all. For pictures and tests: the host's (`/foundry demo`).
demo_build :: proc(s: ^core.Server, c: ^core.Client) {
	f := state(s)
	w := s.home
	reg := s.registry
	t := &reg.blocks
	act := core.game_act(s, w, .Structure)
	block :: proc(s: ^core.Server, k: foundry.Kind) -> game.Block {
		b, _ := game.registry_block(s.registry, foundry.KIND_BLOCKS[k])
		return b
	}
	facing :: proc(t: ^game.Block_Table, b: game.Block, way: string) -> game.Block {
		turned, _ := game.state_set(t, b, "facing", way)
		return turned
	}
	put :: proc(s: ^core.Server, w: ^core.World, p: game.Block_Pos, b: game.Block, act: core.Act) {
		core.set_block(w, p, b, act)
		core.machine_wake(w, p, 1)
	}
	g :: foundry.GROUND
	core.set_block(w, {52, g, 40}, f.ores[0], act)
	put(s, w, {52, 0, 40}, facing(t, block(s, .Miner), "east"), act)
	for x in i32(53) ..= 56 {core.set_block(w, {x, 0, 40}, facing(t, f.belt, "east"), act)}
	put(s, w, {57, 0, 40}, facing(t, block(s, .Arm), "east"), act)
	put(s, w, {58, 0, 40}, block(s, .Furnace), act)
	put(s, w, {59, 0, 40}, facing(t, block(s, .Arm), "east"), act)
	put(s, w, {60, 0, 40}, block(s, .Crate), act)
	bars, _ := game.registry_item(reg, "foundry:ember_bar")
	gear, _ := game.recipe_by_id(reg, "foundry:gear")
	put(s, w, {52, 0, 46}, block(s, .Crate), act)
	core.machine_slots(w, {52, 0, 46})[0] = {bars, 40, 0, 0}
	core.items_made(s, w, bars, 40)
	put(s, w, {53, 0, 46}, facing(t, block(s, .Arm), "east"), act)
	put(s, w, {54, 0, 46}, block(s, .Assembler), act)
	core.machine_data(w, {54, 0, 46}, Machine).recipe = u16(gear) + 1
	put(s, w, {55, 0, 46}, facing(t, block(s, .Arm), "east"), act)
	put(s, w, {56, 0, 46}, block(s, .Crate), act)
	put(s, w, {58, 0, 46}, block(s, .Lab), act)
	core.machine_slots(w, {58, 0, 46})[0] = {f.insight, 10, 0, 0}
	core.items_made(s, w, f.insight, 10)
	put(s, w, {56, 0, 43}, block(s, .Generator), act)
	core.machine_slots(w, {56, 0, 43})[0] = {f.fuel, 20, 0, 0}
	core.items_made(s, w, f.fuel, 20)
	core.set_block(w, {55, 0, 43}, f.pole, act)
	_ = c
}
