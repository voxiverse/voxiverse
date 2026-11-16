package skirmish_server

import "core:fmt"
import "core:log"
import "core:strconv"
import "core:strings"

import "common:game"
import "common:protocol"
import "games:skirmish"
import "server:core"
import "server:play"

// Skirmish's server part (the game: games/skirmish). A match is played on a field laid out
// from the seed and the match's number (field.odin): sides start at its corners, each with
// its headquarters and workers. The players present take the sides in turn and the computer
// the rest (computer.odin); every order, a player's or the computer's, goes through
// order_apply (orders.odin), which checks each unit is the side's. The units and buildings
// live in units.odin. Under the fog (core.world_fog) each player is told only of what its
// side sees. When one side is left with a headquarters or a building that trains, it wins;
// the results stand a while and a new match is laid out. The settings and every player's
// wins are kept with the universe; the matches are not.

GAME :: core.Game {
	info         = skirmish.INFO,
	kinds        = skirmish.KINDS,
	pack         = skirmish.PACK,
	server_state = State,
	client_state = Seat,
	entity_data  = Mind,
	configure    = configure,
	start        = start,
	stop         = stop,
	tick         = tick,
	joined       = joined,
	left         = left,
	request      = request,
	command      = command,
	harming      = harming,
	entity_died  = entity_died,
	editing      = editing,
	save         = save,
	load         = load,
}

NODE_ADMIN :: "skirmish.admin"
MAX_WINS :: 64 // players whose wins are kept

Side :: struct {
	team:     u8, // 1 ..= MAX_SIDES (0: the slot is not in this match)
	player:   core.Player_Ref, // who plays it (a computer's is none)
	human:    bool,
	name:     [16]u8,
	name_len: int,
	stock:    skirmish.Cost,
	supply:   int,
	cap:      int,
	lost:     bool,
	killed:   int,
	units:    int,
	built:    int, // buildings standing
	start:    [2]i32, // its headquarters' column
	computer: Computer,
}

Wins :: struct {
	name:  [16]u8,
	len:   int,
	count: int,
}

State :: struct {
	phase:     play.Phase(skirmish.Phase),
	match:     int,
	settings:  skirmish.Settings,
	playing:   skirmish.Settings, // the settings of the match being played
	sides:     [skirmish.MAX_SIDES]Side,
	field:     Field,
	built:     bool, // the field is in the world
	winner:    u8,
	routes:    play.Routes,
	wins:      [MAX_WINS]Wins,
	units:     [skirmish.Unit]game.Kind_Id,
	buildings: [skirmish.Building]game.Kind_Id,
	crystal:   game.Kind_Id,
	grove:     game.Kind_Id,
	templates: [skirmish.Building]game.Template, // (heap: stop frees them)
	seconds:   u32, // into the match
}

// Seat: a player's place in the match.
Seat :: struct {
	side: int, // its side's index + 1 (0: watching)
}

state :: proc(s: ^core.Server) -> ^State {return core.game_state(s, State)}
seat :: proc(s: ^core.Server, c: ^core.Client) -> ^Seat {return core.game_client_state(s, c, Seat)}

// side_of: the side a player plays (nil: watching).
side_of :: proc(s: ^core.Server, c: ^core.Client) -> ^Side {
	i := seat(s, c).side
	return &state(s).sides[i - 1] if i > 0 else nil
}

// side_team: the side of a team (nil: none in this match).
side_team :: proc(s: ^core.Server, team: u8) -> ^Side {
	if team == 0 || int(team) > skirmish.MAX_SIDES {return nil}
	side := &state(s).sides[team - 1]
	return side if side.team == team else nil
}

side_name :: proc(side: ^Side) -> string {return string(side.name[:side.name_len])}

configure :: proc(config: ^core.Config) {
	config.mode = skirmish.COMMANDER_MODE
	play.configure_flat(config, {skirmish.MAP / 2, 8, skirmish.MAP / 2}, "")
}

start :: proc(s: ^core.Server) -> bool {
	g := state(s)
	w := s.home
	play.world_still(s, w, clock = 0.4)
	core.game_rule(s, w, "fly_speed", "24") // (the commander's panning)
	core.game_rule(s, w, "fly_sprint_speed", "60")
	core.world_fog(w, true)
	reg := s.registry
	for &k, u in g.units {k = game.registry_kind(reg, skirmish.UNITS[u].kind) or_return}
	for &k, b in g.buildings {k = game.registry_kind(reg, skirmish.BUILDINGS[b].kind) or_return}
	g.crystal = game.registry_kind(reg, "skirmish:crystal") or_return
	g.grove = game.registry_kind(reg, "skirmish:grove") or_return
	for &t, b in g.templates {t = skirmish.building_template(b)}
	g.settings = skirmish.DEFAULT_SETTINGS
	g.routes.area = FIELD_AREA
	core.world_keep(w, play.arena_area(FIELD))
	log.infof("skirmish started seed=%d", s.config.seed)
	return true
}

stop :: proc(s: ^core.Server) {
	g := state(s)
	play.routes_free(s.home, &g.routes)
	for &t in g.templates {delete(t.cells)}
	log.infof("skirmish stopped match=%d", g.match)
}

tick :: proc(s: ^core.Server) {
	g := state(s)
	switch g.phase.now {
	case .Waiting:
		if play.present(s) == 0 && g.match > 0 {break}
		if !g.built {g.built = field_build(s)}
		if g.built && core.world_ready(s.home, play.arena_area(FIELD)) {match_begin(s)}
	case .Playing:
		g.seconds = u32(play.phase_seconds(s, &g.phase))
		units_tick(s)
		computers_tick(s)
		match_judge(s)
	case .Results:
		units_tick(s)
		if play.phase_seconds(s, &g.phase) >= skirmish.RESULTS_SECONDS {
			match_clear(s)
			g.built = false
			play.phase_set(s, &g.phase, .Waiting)
		}
	}
	put_records(s)
}

// match_begin: the sides taken (the players present in turn, the computer the rest), each
// given its headquarters, workers and stock at its corner, every player set down over its own.
match_begin :: proc(s: ^core.Server) {
	g := state(s)
	g.match += 1
	g.playing = g.settings
	g.winner = 0
	n := g.playing.sides
	corners := field_corners(n)
	g.sides = {}
	nodes_place(s)
	for &c in s.clients {
		if play.here(s, &c) {seat(s, &c).side = 0}
	}
	taken := 0
	for &c in s.clients {
		if !play.here(s, &c) || taken >= n {continue}
		side := &g.sides[taken]
		side.player, side.human = core.player_ref(s, &c), true
		side.name_len = copy(side.name[:], core.client_name(&c))
		taken += 1
		seat(s, &c).side = taken
	}
	for i in 0 ..< n {
		side := &g.sides[i]
		side.team = u8(i + 1)
		side.start = corners[i]
		side.stock = {
			.Ore  = g.playing.ore,
			.Wood = g.playing.wood,
		}
		if !side.human {
			side.name_len = copy(
				side.name[:],
				skirmish.tr(.Computer, skirmish.tr(.Side_Name, i + 1)),
			)
			side.computer = {
				wave = g.playing.wave,
			}
		}
		side_place(s, side)
	}
	for &c in s.clients {
		if !play.here(s, &c) {continue}
		side := side_of(s, &c)
		core.client_set_team(&c, side.team if side != nil else 0)
		look_from(s, &c, side.start if side != nil else {skirmish.MAP / 2, skirmish.MAP / 2})
	}
	play.phase_set(s, &g.phase, .Playing)
	core.announce(s, fmt.tprintf("Skirmish: match %d, %d sides", g.match, n))
}

// look_from: the commander's camera over a point of the field.
look_from :: proc(s: ^core.Server, c: ^core.Client, at: [2]i32) {
	core.game_mode(s, c, skirmish.COMMANDER_MODE)
	p := [3]f64{f64(at.x) + 0.5, f64(skirmish.GROUND + skirmish.HIGH + 2), f64(at.y) + 0.5}
	core.teleport(s, c, p, {0, -0.9}, flying = true)
}

// match_judge: a side with neither a headquarters nor a building that trains has lost;
// with one side left (or none), the match is over.
match_judge :: proc(s: ^core.Server) {
	g := state(s)
	standing: [skirmish.MAX_SIDES + 1]bool
	it := core.entities_each(s.home)
	for h in core.entities_next(&it) {
		m := mind(s.home, h)
		if m == nil || m.role != .Building {continue}
		if m.building == .Headquarters || skirmish.BUILDINGS[m.building].trains != {} {
			standing[core.entity_team(s.home, h)] = true
		}
	}
	left, last := 0, u8(0)
	for &side in g.sides {
		if side.team == 0 {continue}
		if !side.lost && !standing[side.team] {
			side.lost = true
			core.announce(s, fmt.tprintf("Skirmish: %s is defeated", side_name(&side)))
		}
		if !side.lost {left, last = left + 1, side.team}
	}
	if left > 1 {return}
	g.winner = last
	if winner := side_team(s, last); winner != nil {
		core.announce(s, fmt.tprintf("Skirmish: %s wins match %d", side_name(winner), g.match))
		if winner.human {wins_add(g, side_name(winner))}
	}
	play.phase_set(s, &g.phase, .Results)
}

// match_clear: every unit, building and node of the match gone, its routes let go.
match_clear :: proc(s: ^core.Server) {
	g := state(s)
	it := core.entities_each(s.home)
	for h in core.entities_next(&it) {
		if mind(s.home, h) != nil {core.entity_gone(s.home, h)}
	}
	play.routes_free(s.home, &g.routes)
	for &c in s.clients {
		seat(s, &c).side = 0
		core.client_set_team(&c, 0)
	}
}

wins_add :: proc(g: ^State, name: string) {
	for &w in g.wins {
		if string(w.name[:w.len]) == name {w.count += 1; return}
	}
	for &w in g.wins {
		if w.len == 0 {w.len = copy(w.name[:], name); w.count = 1; return}
	}
}

wins_of :: proc(g: ^State, name: string) -> int {
	for &w in g.wins {if w.len > 0 && string(w.name[:w.len]) == name {return w.count}}
	return 0
}

// joined: a player who comes during a match takes a side the computer plays, if one still
// stands (else it watches until the next).
joined :: proc(s: ^core.Server, c: ^core.Client) {
	g := state(s)
	if g.phase.now == .Playing {
		for &side, i in g.sides {
			if side.team == 0 || side.human || side.lost {continue}
			side.player, side.human = core.player_ref(s, c), true
			side.name_len = copy(side.name[:], core.client_name(c))
			seat(s, c).side = i + 1
			core.client_set_team(c, side.team)
			look_from(s, c, side.start)
			core.notice(
				s,
				c,
				fmt.tprintf("Skirmish: you take side %d from the computer", side.team),
			)
			return
		}
	}
	look_from(s, c, {skirmish.MAP / 2, skirmish.MAP / 2})
	core.notice(
		s,
		c,
		"Skirmish: gather ore and wood, build, train an army; destroy their headquarters and barracks",
	)
}

// left: a player's side is the computer's from now on.
left :: proc(s: ^core.Server, c: ^core.Client) {
	if side := side_of(s, c); side != nil {
		side.human = false
		side.computer = {
			wave = state(s).playing.wave,
		}
	}
	seat(s, c).side = 0
}

// editing: the field's blocks are the game's; a commander has no hands.
editing :: proc(
	s: ^core.Server,
	c: ^core.Client,
	at: game.Block_Pos,
	old, new: game.Block,
) -> string {
	return "Command from the panel"
}

// request: a player's order, training or rally point, judged for its side.
request :: proc(s: ^core.Server, c: ^core.Client, r: core.Request) {
	g := state(s)
	side := side_of(s, c)
	if g.phase.now != .Playing || side == nil || side.lost {return}
	if v, ok := core.request_value(s, r, skirmish.Order); ok {
		if refused := order_apply(s, side, v^); refused > 0 {
			core.notice(s, c, fmt.tprintf("%d of those are not yours to command", refused))
		}
	}
	if v, ok := core.request_value(s, r, skirmish.Train); ok {
		if why := train(s, side, v.at, v.unit); why != "" {core.notice(s, c, why)}
	}
	if v, ok := core.request_value(s, r, skirmish.Rally); ok {
		rally(s, side, v.at, {i32(v.to.x), i32(v.to.y)})
	}
}

// put_records: the match to everyone; each player's economy; every side for the board; the
// records of the units, buildings and nodes each player knows.
put_records :: proc(s: ^core.Server) {
	g := state(s)
	match := skirmish.Match {
		phase  = g.phase.now,
		match  = u16(g.match),
		winner = u8(g.winner),
	}
	switch g.phase.now {
	case .Waiting:
	case .Playing:
		match.seconds = g.seconds
	case .Results:
		match.seconds = u32(play.phase_left(s, &g.phase, skirmish.RESULTS_SECONDS))
	}
	for side in g.sides {if side.team != 0 {match.sides += 1}}
	w := s.home
	for &c in s.clients {
		if c.state != .Playing || c.world != w {continue}
		core.game_put(s, &c, &match)
		eco: skirmish.Economy
		if side := side_of(s, &c); side != nil {
			eco = {
				team = side.team,
				stock = {.Ore = u32(side.stock[.Ore]), .Wood = u32(side.stock[.Wood])},
				supply = u16(side.supply),
				supply_cap = u16(side.cap),
				lost = side.lost,
			}
		}
		core.game_put(s, &c, &eco)
		for &side in g.sides {
			if side.team == 0 {continue}
			r := skirmish.Side_Record {
				name   = side_name(&side),
				team   = side.team,
				units  = u16(side.units),
				built  = u16(side.built),
				killed = u16(side.killed),
				wins   = u16(wins_of(g, side_name(&side))) if side.human else 0,
			}
			// (keyed by its team: an entity key is any number of the game's)
			core.game_put(s, &c, &r, protocol.key_entity(u32(side.team)))
		}
	}
	it := core.entities_each(w)
	for h in core.entities_next(&it) {
		m := mind(w, h)
		if m == nil {continue}
		id := core.entity_id(w, h)
		key := protocol.key_entity(id)
		for &c in s.clients {
			if c.state != .Playing || c.world != w || !core.entity_known(&c, id) {continue}
			switch m.role {
			case .Unit:
				r := skirmish.Unit_Record{m.unit, m.carrying, m.resource}
				core.game_put(s, &c, &r, key)
			case .Building:
				r := building_record(m)
				core.game_put(s, &c, &r, key)
			case .Node:
				r := skirmish.Node_Record{m.resource, m.left}
				core.game_put(s, &c, &r, key)
			}
		}
	}
}

// command: /skirmish shows the match and its settings; /skirmish set <setting> <value>
// sets one (from the next match); /skirmish restart lays out a new match; /skirmish give
// <ore> <wood> fills the admin's side's stock, /skirmish clash <n> sets n soldiers and
// archers of each of the first two sides at each other by the camera's focus (for trying,
// a picture aid).
command :: proc(s: ^core.Server, c: ^core.Client, name: string, args: []string) -> bool {
	if name != "skirmish" {return false}
	g := state(s)
	table := skirmish.settings_table()
	if len(args) == 0 {
		core.notice(
			s,
			c,
			fmt.tprintf(
				"Skirmish match %d, %v, %d s: %s",
				g.match,
				g.phase.now,
				g.seconds,
				play.settings_text(table, &g.settings),
			),
		)
		return true
	}
	if handled, _ := play.settings_command(s, c, table, &g.settings, NODE_ADMIN, args); handled {
		return true
	}
	if !core.allowed(s, c, NODE_ADMIN) {
		core.notice(s, c, "You may not change the match (skirmish.admin)")
		return true
	}
	switch {
	case len(args) == 1 && args[0] == "restart":
		match_clear(s)
		g.built = false
		play.phase_set(s, &g.phase, .Waiting)
		core.notice(s, c, "Skirmish: a new match")
	case len(args) == 2 && args[0] == "clash":
		n, ok := strconv.parse_int(args[1])
		if !ok || n < 1 || n > 100 || g.phase.now != .Playing {
			core.notice(s, c, "Usage: skirmish clash <1..100> (while a match is played)")
			return true
		}
		clash(s, c, n)
	case len(args) == 3 && args[0] == "give":
		side := side_of(s, c)
		ore, ok1 := strconv.parse_int(args[1])
		wood, ok2 := strconv.parse_int(args[2])
		if side == nil || !ok1 || !ok2 || ore < 0 || wood < 0 {
			core.notice(s, c, "Usage: skirmish give <ore> <wood> (while playing a side)")
			return true
		}
		side.stock[.Ore] += ore
		side.stock[.Wood] += wood
	case:
		core.notice(
			s,
			c,
			fmt.tprintf(
				"Usage: skirmish [%s | restart | give <ore> <wood> | clash <n>]",
				play.settings_usage(table),
			),
		)
	}
	return true
}

// save: the settings and every player's wins, kept with the universe (`wins <n> <name>`).
save :: proc(s: ^core.Server, out: ^strings.Builder) {
	g := state(s)
	play.settings_save(skirmish.settings_table(), &g.settings, out)
	for &w in g.wins {
		if w.len > 0 {fmt.sbprintf(out, "wins = %d %s\n", w.count, string(w.name[:w.len]))}
	}
}

// load: what the universe kept (a line Skirmish does not know is not Skirmish's).
load :: proc(s: ^core.Server, text: string) -> bool {
	g := state(s)
	own := play.settings_read(skirmish.settings_table(), &g.settings, text) or_return
	i := 0
	for line in own {
		if line.key != "wins" || i >= MAX_WINS {return false}
		count, _, name := strings.partition(line.value, " ")
		n, ok := strconv.parse_int(count)
		if !ok || n < 0 || len(name) == 0 || len(name) > 16 {return false}
		g.wins[i].len = copy(g.wins[i].name[:], name)
		g.wins[i].count = n
		i += 1
	}
	return true
}

// clash: n units of each of the first two sides, a few blocks either side of the player's
// focus, attack-moving at each other.
clash :: proc(s: ^core.Server, c: ^core.Client, n: int) {
	g := state(s)
	at := [2]i32{i32(c.player.position.x), i32(c.player.position.z)}
	for k in 0 ..< 2 {
		side := &g.sides[k]
		if side.team == 0 {continue}
		side.computer.wave = 1000 // (the computer does not send them elsewhere)
		dir := i32(-1 if k == 0 else 1)
		units := make([dynamic]game.Entity_Handle, context.temp_allocator)
		for i in 0 ..< n {
			x, z := at.x + dir * (7 + i32(i / 6)), at.y - 3 + i32(i % 6)
			y := floor_at(s, x, z) or_continue
			u := skirmish.Unit.Archer if i % 3 == 2 else .Soldier
			if h := unit_spawn(s, side, u, {x, y, z}); h != 0 {append(&units, h)}
		}
		group_send(s, units[:], .Attack_Move, {at.x - dir * 8, skirmish.GROUND, at.y})
	}
}
