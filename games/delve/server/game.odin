package delve_server

import "core:fmt"
import "core:log"
import "core:strconv"
import "core:strings"

import "common:base"
import "common:game"
import "common:protocol"
import "games:delve"
import "server:core"
import "server:play"

// Delve's server part (the game: games/delve): it runs the dungeons in the home world.
// A dungeon is built from its seed (dungeon.odin) and peopled with creatures and chests;
// the creatures wake and fight by themselves (foes.odin); the delvers' blows, levels,
// whirls, potions and loot are delvers.odin's. The warden's death opens the way down,
// and a delver who steps on it takes everyone to the next, deeper dungeon.

GAME :: core.Game {
	info         = delve.INFO,
	kinds        = delve.KINDS,
	pack         = delve.PACK,
	server_state = Run,
	client_state = Seat,
	configure    = configure,
	start        = start,
	stop         = stop,
	tick         = tick,
	joined       = joined,
	left         = left,
	command      = command,
	editing      = editing,
	respawned    = respawned,
	died         = died,
	entity_hurt  = entity_hurt,
	entity_died  = entity_died,
	harming      = harming,
	action       = action,
	picking      = picking,
	save         = save,
	load         = load,
}

MAX_FOES :: 200 // creatures alive at once (a call for more is refused)
MAX_KEPT :: 64 // delvers' progress kept with the universe, by name
BUILD_WAIT :: 10 // seconds: the dungeon is built with what is loaded by then

// Run: the dungeon now, and what the pack's names are in this session.
Run :: struct {
	rng:         base.Rng, // seeds, spawns, loot, crits (from the universe's seed)
	depth:       int,
	seed:        u32,
	phase:       play.Phase(delve.Phase),
	plan:        delve.Dungeon,
	foes:        [MAX_FOES]Foe_Slot,
	foe_count:   int,
	warden:      u32, // its entity id (0: dead, or not yet)
	warden_call: u64, // the tick the warden next calls biters
	kept:        play.By_Name(Kept, MAX_KEPT),
	// What the pack's names are in this session's registry.
	kinds:       [delve.Foe]game.Kind_Id,
	chest, spit: game.Kind_Id,
	weapons:     [delve.Weapon]game.Item,
	coin:        game.Item,
	potion:      game.Item,
	floor:       game.Block,
	wall:        game.Block,
	exit:        game.Block,
}

// Seat: a delver's progress in this session.
Seat :: struct {
	level:    int, // 0: not yet delving (joined, not restored)
	xp:       int, // towards the next level
	kills:    int,
	deaths:   int,
	best:     int, // the deepest dungeon reached
	whirl_at: u64, // the tick its whirl is ready again
}

// Kept: a delver's progress as the universe keeps it (by name: play.By_Name).
Kept :: struct {
	level: int,
	xp:    int,
	best:  int,
}

state :: proc(s: ^core.Server) -> ^Run {return core.game_state(s, Run)}
seat :: proc(s: ^core.Server, c: ^core.Client) -> ^Seat {return core.game_client_state(s, c, Seat)}

NODE_ADMIN :: "delve.admin"

configure :: proc(config: ^core.Config) {
	play.configure_flat(config, {4.5, 0, 4.5}, delve.DELVER_MODE)
}

start :: proc(s: ^core.Server) -> bool {
	d := state(s)
	d.rng = base.rng_make(u64(s.config.seed) ~ 0xde17e)
	w := s.home
	play.world_still(s, w, clock = 0.45)
	core.game_rule(s, w, "pvp", "false")
	core.game_rule(s, w, "keep_inventory", "true")
	core.game_rule(s, w, "respawn_delay", "2")
	reg := s.registry
	ok := true
	for &k, f in d.kinds {
		k, ok = game.registry_kind(reg, fmt.tprintf("delve:%s", delve.FOES[f].kind))
		if !ok {return false}
	}
	d.chest = game.registry_kind(reg, delve.CHEST_KIND) or_return
	d.spit = game.registry_kind(reg, "delve:spit") or_return
	for &item, wp in d.weapons {
		item = game.registry_item(reg, delve.WEAPON_ITEMS[wp]) or_return
	}
	d.coin = game.registry_item(reg, delve.COIN) or_return
	d.potion = game.registry_item(reg, delve.POTION) or_return
	d.floor = game.registry_block(reg, delve.FLOOR_BLOCK) or_return
	d.wall = game.registry_block(reg, delve.WALL_BLOCK) or_return
	d.exit = game.registry_block(reg, delve.EXIT_BLOCK) or_return
	core.world_keep(w, AREA)
	dungeon_begin(s, 1)
	log.infof("delve started seed=%d", s.config.seed)
	return true
}

stop :: proc(s: ^core.Server) {
	log.infof("delve stopped depth=%d", state(s).depth)
}

// here: c is delving (playing in the home world, where the dungeon is).
here :: play.here

seconds :: proc(s: ^core.Server) -> f64 {return play.phase_seconds(s, &state(s).phase)}

set_phase :: proc(s: ^core.Server, phase: delve.Phase) {play.phase_set(s, &state(s).phase, phase)}

tick :: proc(s: ^core.Server) {
	d := state(s)
	switch d.phase.now {
	case .Building:
		if dungeon_build(s, force = seconds(s) >= BUILD_WAIT) {
			set_phase(s, .Delving)
			for &c in s.clients {if here(s, &c) {enter(s, &c)}}
		}
	case .Delving, .Open:
		foes_tick(s)
		if d.phase.now == .Open {way_down(s)}
	}
	put_records(s)
}

joined :: proc(s: ^core.Server, c: ^core.Client) {
	core.notice(s, c, "Delve: Z whirls, X drinks a potion; the warden's death opens the way down")
	restore(s, c)
	if state(s).phase.now != .Building {enter(s, c)}
}

left :: proc(s: ^core.Server, c: ^core.Client) {
	keep(s, c)
}

// enter: c starts this dungeon: the delver's mode and kit, in the start room.
enter :: proc(s: ^core.Server, c: ^core.Client) {
	d := state(s)
	core.game_mode(s, c, delve.DELVER_MODE)
	core.kit_give(s, c)
	core.hotbar_select(s, c, 0)
	p := seat(s, c)
	p.best = max(p.best, d.depth)
	core.player_health_bonus(s, c, delve.level_health(p.level))
	core.heal_player(c, 1000)
	core.teleport(s, c, start_point(s), {0, -0.6}, flying = false)
}

// restore: the progress the universe kept for c's name, or a new delver's.
restore :: proc(s: ^core.Server, c: ^core.Client) {
	d := state(s)
	p := seat(s, c)
	p^ = {
		level = 1,
	}
	if k := play.by_name(&d.kept, core.client_name(c)); k != nil {
		p.level, p.xp, p.best = k.level, k.xp, k.best
	}
}

// keep: c's progress, kept by name (for the save and a later join).
keep :: proc(s: ^core.Server, c: ^core.Client) {
	d := state(s)
	p := seat(s, c)
	if p.level == 0 {return}
	k := play.by_name(&d.kept, core.client_name(c), make_it = true)
	if k == nil {return}
	k.level, k.xp, k.best = p.level, p.xp, p.best
}

// editing: the dungeon's blocks are not a delver's to change.
editing :: proc(
	s: ^core.Server,
	c: ^core.Client,
	at: game.Block_Pos,
	old, new: game.Block,
) -> string {
	return "The dungeon's stones do not move"
}

// respawned: a dead delver wakes in the start room; the toll: the experience towards
// the next level, and half its coins.
respawned :: proc(s: ^core.Server, c: ^core.Client) {
	if !here(s, c) {return}
	d := state(s)
	p := seat(s, c)
	p.xp = 0
	lost := core.item_take(s, c, d.coin, core.item_count(c, d.coin) / 2)
	core.player_health_bonus(s, c, delve.level_health(p.level))
	core.heal_player(c, 1000)
	core.teleport(s, c, start_point(s), {0, -0.6}, flying = false)
	core.notice(s, c, fmt.tprintf("You wake in the first room; %d coins are gone", lost))
}

died :: proc(s: ^core.Server, c: ^core.Client, harm: core.Harm) {
	seat(s, c).deaths += 1
}

// put_records: the dungeon to everyone, every delver's progress to every delver, and
// each creature's tag to those who know it (only what changed is sent).
put_records :: proc(s: ^core.Server) {
	d := state(s)
	r := delve.Delve {
		phase  = d.phase.now,
		depth  = u8(clamp(d.depth, 0, 255)),
		seed   = d.seed,
		foes   = u16(foes_alive(s)),
		warden = d.warden,
	}
	for &c in s.clients {
		if !here(s, &c) {continue}
		core.game_put(s, &c, &r)
		for &o in s.clients {
			if !here(s, &o) {continue}
			p := seat(s, &o)
			hero := delve.Hero {
				name    = core.client_name(&o),
				level   = u8(clamp(p.level, 0, 255)),
				xp      = u32(p.xp),
				next    = u32(delve.xp_to_next(p.level)),
				kills   = u32(p.kills),
				deaths  = u16(clamp(p.deaths, 0, 65535)),
				best    = u8(clamp(p.best, 0, 255)),
				whirl   = u16(clamp(int(p.whirl_at) - int(s.tick), 0, 65535)),
				potions = u16(core.item_count(&o, d.potion)),
				coins   = u32(core.item_count(&o, d.coin)),
			}
			core.game_put(s, &c, &hero, protocol.key_player(core.player_id(s, &o)))
		}
		for &f in d.foes[:d.foe_count] {
			if !core.entity_known(&c, f.id) {continue}
			tag := delve.Foe_Tag {
				name  = string(f.name[:f.name_len]),
				foe   = f.foe,
				level = u8(clamp(f.level, 0, 255)),
				elite = f.elite,
			}
			core.game_put(s, &c, &tag, protocol.key_entity(f.id))
		}
	}
}

// command: /delve shows the dungeon; the admin's: /delve down takes everyone to the
// next one now, /delve depth <n> to a dungeon of that depth, /delve goto <start|boss>
// moves the admin there, /delve spawn <creature> [elite] makes one awake beside it,
// /delve loot drops a roll of loot at its feet.
command :: proc(s: ^core.Server, c: ^core.Client, name: string, args: []string) -> bool {
	if name != "delve" {return false}
	d := state(s)
	if len(args) == 0 {
		core.notice(
			s,
			c,
			fmt.tprintf(
				"Delve depth %d, %v, seed %d: %d creatures, the warden %s",
				d.depth,
				d.phase.now,
				d.seed,
				foes_alive(s),
				"alive" if d.warden != 0 else "dead",
			),
		)
		return true
	}
	if !core.allowed(s, c, NODE_ADMIN) {
		core.notice(s, c, "You may not change the dungeon (delve.admin)")
		return true
	}
	switch {
	case len(args) == 1 && args[0] == "down":
		dungeon_begin(s, d.depth + 1)
	case len(args) == 2 && args[0] == "depth":
		n, ok := strconv.parse_int(args[1])
		if !ok || n < 1 || n > 99 {
			core.notice(s, c, "Usage: delve depth <1..99>")
			return true
		}
		dungeon_begin(s, n)
	case len(args) == 2 && args[0] == "goto":
		switch args[1] {
		case "start":
			core.teleport(s, c, start_point(s), {0, -0.6}, flying = false)
		case "boss":
			// (at the warden's room's door: its middle less a few blocks)
			p := room_point(d.plan.rooms[d.plan.boss].area)
			core.teleport(s, c, p + {0, 0, 3}, {0, -0.6}, flying = false)
		case:
			core.notice(s, c, "Usage: delve goto <start|boss>")
		}
	case (len(args) == 2 || len(args) == 3) && args[0] == "spawn":
		for foe, f in delve.FOES {
			if foe.kind != args[1] {continue}
			at := c.player.position + {3, 0, 0}
			if h := foe_spawn(s, f, at, len(args) == 3 && args[2] == "elite"); h != 0 {
				slot := foe_of(s, core.entity_id(s.home, h))
				slot.awake, slot.prey = true, core.player_ref(s, c)
			}
			return true
		}
		core.notice(s, c, "Usage: delve spawn <biter|husk|spitter|brute|warden> [elite]")
	case len(args) == 1 && args[0] == "loot":
		loot(s, c.player.position + {2.5, 0, -1.5}, 3, 25, 1)
		loot(s, c.player.position + {-2.5, 0, 1.5}, 1, 7, 1)
	case:
		core.notice(
			s,
			c,
			"Usage: delve [down | depth <1..99> | goto <start|boss> | spawn <creature> [elite] | loot]",
		)
	}
	return true
}

// save: every delver's progress, kept by name ("hero = <level> <xp> <best> <name>").
save :: proc(s: ^core.Server, out: ^strings.Builder) {
	for &c in s.clients {if here(s, &c) {keep(s, &c)}}
	write :: proc(b: ^strings.Builder, k: ^Kept) -> bool {
		fmt.sbprintf(b, "%d %d %d", k.level, k.xp, k.best)
		return true
	}
	play.by_name_save(&state(s).kept, "hero", out, write)
}

// load: the progress the universe kept; a line Delve does not know, or a number out of
// its bounds, is not Delve's.
load :: proc(s: ^core.Server, text: string) -> bool {
	d := state(s)
	read :: proc(f: []string, k: ^Kept) -> bool {
		if len(f) != 3 {return false}
		level, ok1 := strconv.parse_int(f[0])
		xp, ok2 := strconv.parse_int(f[1])
		best, ok3 := strconv.parse_int(f[2])
		if !ok1 || !ok2 || !ok3 || level < 1 || level > delve.MAX_LEVEL || xp < 0 || best < 0 {
			return false
		}
		k.level, k.xp, k.best = level, xp, best
		return true
	}
	for line in play.saved_lines(text) {play.by_name_read(&d.kept, "hero", line, read) or_return}
	for &c in s.clients {if here(s, &c) {restore(s, &c)}}
	return true
}
