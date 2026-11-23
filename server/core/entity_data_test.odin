package core

import "core:os"
import "core:testing"

import "common:game"
import "common:protocol"

// A game's creature survives a restart whole, without its game making it again: its
// kind, place, health and most health, the way it was going, the looks its game set and
// the game's own record on it (Game.entity_data: CREATURES_GAME's Creature_Data).
@(test)
test_a_games_creature_survives_a_restart :: proc(t: ^testing.T) {
	dir :: "build/tmp/test_game_creature"
	os.remove_all(dir)
	defer os.remove_all(dir)
	config := harness_world()
	config.save_dir = dir
	config.game = harness_creatures()
	h := new(Harness)
	defer free(h)
	if !testing.expect(t, harness_start(h, config)) {return}
	s := &h.srv
	kind, known := game.registry_kind(s.registry, "creatures:walker")
	if !testing.expect(t, known) {
		harness_stop(h)
		return
	}
	e := entity_spawn(s.home, kind, {3.5, 1, 3.5}, false)
	if !testing.expect(t, e != 0) {
		harness_stop(h)
		return
	}
	id := entity_id(s.home, e)
	want := Creature_Data {
		number = -42,
		mood   = .Scared,
		home   = {7, -1, 300},
	}
	entity_data(s.home, e, Creature_Data)^ = want
	entity_set_max_health(s.home, e, 9)
	entity_set_health(s.home, e, 6)
	entity_set_speed(s.home, e, 2.5)
	entity_go(s.home, e, {20.5, 1, 3.5})
	testing.expect(t, entity_show(s.home, e, "big", true))
	testing.expect(t, entity_show(s.home, e, "sad", true))
	testing.expect(t, !entity_show(s.home, e, "tall", true), "a look the kind has not")
	testing.expect_value(t, entity_looks(s.home, s.registry, e), 3)
	testing.expect(t, harness_stop(h))

	if !testing.expect(t, harness_start(h, config)) {return}
	defer harness_stop(h)
	back, found := entity_find(s.home, id)
	if !testing.expect(t, found, "the creature was not kept") {return}
	testing.expect_value(t, entity_kind(s.home, back), kind)
	testing.expect_value(t, entity_pos(s.home, back), [3]f64{3.5, 1, 3.5})
	testing.expect_value(t, entity_health_of(s.home, back), 6)
	testing.expect_value(t, entity_max_health(s.home, back), 9)
	testing.expect_value(t, entity_data(s.home, back, Creature_Data)^, want)
	testing.expect_value(t, entity_looks(s.home, s.registry, back), 3)
	st := entity_steer(s.home, back)
	if !testing.expect(t, st != nil) {return}
	testing.expect_value(t, st.mode, Steer_Mode.Go)
	testing.expect_value(t, st.target, [3]f64{20.5, 1, 3.5})
	testing.expect_value(t, st.speed, 2.5)
}

// A game's brain: the creatures of each of its kinds whose brain is "game" are given to
// its think hook once a tick, all of them in one call (lowest id first), and what it
// steers them to do they do. Hundreds cost one call a tick.
@(test)
test_a_games_brain_thinks_for_its_creatures :: proc(t: ^testing.T) {
	Seen :: struct {
		calls, last: int,
		in_order:    bool,
	}
	h := new(Harness)
	defer free(h)
	config := harness_world()
	config.game = harness_creatures()
	config.game.server_state = Seen
	config.game.think = proc(
		s: ^Server,
		w: ^World,
		kind: game.Kind_Id,
		entities: []game.Entity_Handle,
	) {
		seen := game_state(s, Seen)
		seen.calls += 1
		seen.last = len(entities)
		seen.in_order = true
		for e, i in entities {
			if i > 0 && entity_id(w, entities[i - 1]) >= entity_id(w, e) {seen.in_order = false}
			data := entity_data(w, e, Creature_Data)
			data.number += 1
			if data.number == 1 {entity_go(w, e, entity_pos(w, e) + {4, 0, 0})}
		}
	}
	if !testing.expect(t, harness_start(h, config)) {return}
	defer harness_stop(h)
	s := &h.srv
	kind, _ := game.registry_kind(s.registry, "creatures:thinker")
	walker, _ := game.registry_kind(s.registry, "creatures:walker")
	area := Box{{-24, -16, -24}, {24, 16, 24}}
	world_keep(s.home, area)
	for _ in 0 ..< 300 {
		if world_ready(s.home, area) {break}
		harness_step(h)
	}
	if !testing.expect(t, world_ready(s.home, area), "the ground never came") {return}
	COUNT :: 300
	first: game.Entity_Handle
	for i in 0 ..< COUNT {
		e := entity_spawn(s.home, kind, {f64(i % 20) * 1.5 - 15, 0, f64(i / 20) * 1.5 - 12}, false)
		if i == 0 {first = e}
	}
	entity_spawn(s.home, walker, {0.5, 1, 20.5}, false) // (no brain of the game's: not given)
	start := entity_pos(s.home, first)
	seen := game_state(s, Seen)
	seen.calls = 0
	harness_step(h, 30)
	testing.expect_value(t, seen.calls, 30)
	testing.expect_value(t, seen.last, COUNT)
	testing.expect(t, seen.in_order, "not lowest id first")
	testing.expect_value(t, entity_data(s.home, first, Creature_Data).number, 30)
	st := entity_steer(s.home, first)
	testing.expectf(
		t,
		entity_pos(s.home, first).x > start.x + 0.5,
		"the brain's steering did nothing: %v -> %v, %v %v %v",
		start,
		entity_pos(s.home, first),
		st.mode,
		st.target,
		st.path.count,
	)
}

// A game decides its natural creatures: a kind's spawn rule (its pack's) brings them near
// the players, no more than its cap, and the game's spawned hook makes each what it is or
// refuses it; with nobody near, they go.
@(test)
test_a_game_decides_its_natural_spawns :: proc(t: ^testing.T) {
	Seen :: struct {
		calls: int,
	}
	config := Config {
		seed            = 21,
		generator       = .Classic, // grass near the spawn
		view_radius     = 4,
		view_height     = 2,
		max_players     = 2,
		listen          = true,
		everyone_cheats = true,
	}
	config.game = harness_creatures()
	config.game.server_state = Seen
	config.game.spawned = proc(s: ^Server, w: ^World, h: game.Entity_Handle) -> bool {
		d := entity_data(w, h, Creature_Data)
		if d == nil {return true} 	// (not the game's kind)
		seen := game_state(s, Seen)
		seen.calls += 1
		d.number = 7
		return seen.calls % 2 == 1 // (every other one refused)
	}
	h := new(Harness)
	defer free(h)
	if !testing.expect(t, harness_start(h, config)) {return}
	defer harness_stop(h)
	c := new(Net_Client)
	defer free(c)
	net_connect(c, 0, "watcher", h = h)
	defer net_close(c)
	ok := net_wait(
		t,
		{c},
		proc(cs: []^Net_Client) -> bool {return landed(cs[0]) && len(cs[0].chunks) > 200},
	)
	if !testing.expect(t, ok, "never landed") {return}
	s := &h.srv
	wild, _ := game.registry_kind(s.registry, "creatures:wild")
	most := 0
	for _ in 0 ..< 60 * game.TICK_RATE {
		net_pump(t, c)
		harness_step(h)
		n := 0
		it := entities_each(s.home)
		for e in entities_next(&it) {
			if entity_kind(s.home, e) != wild {continue}
			n += 1
			testing.expect(t, entity_is_natural(s.home, e))
			testing.expect_value(t, entity_data(s.home, e, Creature_Data).number, 7)
		}
		most = max(most, n)
	}
	testing.expect(t, most >= 1, "none came")
	testing.expectf(t, most <= 4, "%d came: the cap is 4", most)
	testing.expect(t, game_state(s, Seen).calls > most, "none was refused")

	// Its player away, past their despawn distance: they go.
	net_send(c, protocol.Teleport{position = {0.5, 140, 400.5}})
	gone :: proc(cs: []^Net_Client) -> bool {
		for _, p in cs[0].entities {if p.z < 300 {return false}}
		return cs[0].update.state.position.z > 300
	}
	went := net_wait(t, {c}, gone, 20)
	wild_left := 0
	it := entities_each(s.home)
	for e in entities_next(&it) {
		if entity_kind(s.home, e) == wild && entity_pos(s.home, e).z < 300 {wild_left += 1}
	}
	testing.expect(t, went && wild_left == 0, "the wild ones stayed with nobody near")
}

// A player uses a creature: the game's entity_use hook is asked with what the player
// holds, does the use or refuses it, and a refusal is told to the player.
@(test)
test_a_game_judges_the_use_of_its_creatures :: proc(t: ^testing.T) {
	config := harness_world()
	config.listen = true
	config.game = harness_creatures()
	config.game.entity_use = proc(
		s: ^Server,
		c: ^Client,
		h: game.Entity_Handle,
		stack: game.Stack,
	) -> string {
		if game.stack_empty(stack) {return "Hold something to give it"}
		entity_data(c.world, h, Creature_Data).number = i32(stack.count)
		return ""
	}
	h := new(Harness)
	defer free(h)
	if !testing.expect(t, harness_start(h, config)) {return}
	defer harness_stop(h)
	c := new(Net_Client)
	defer free(c)
	net_connect(c, 0, "user", h = h)
	defer net_close(c)
	standing :: proc(cs: []^Net_Client) -> bool {return(
			cs[0].welcomed &&
			cs[0].update.state.on_ground \
		)}
	if !testing.expect(t, net_wait(t, {c}, standing), "never stood") {return}
	s := &h.srv
	player := client_by_name(s, "user")
	kind, _ := game.registry_kind(s.registry, "creatures:walker")
	e := entity_spawn(s.home, kind, player.player.position + {1.5, 0, 0}, false)
	id := entity_id(s.home, e)
	clear_slots :: proc(c: ^Client) {for &slot in c.inventory.slots {slot = {}}}
	clear_slots(player)
	net_send(c, protocol.Use_Entity{id, c.seq})
	ok := net_wait(t, {c}, proc(cs: []^Net_Client) -> bool {
		for n in cs[0].notices {if n == "Hold something to give it" {return true}}
		return false
	})
	testing.expect(t, ok, "the refusal was not told")
	testing.expect_value(t, entity_data(s.home, e, Creature_Data).number, 0)
	player.inventory.slots[player.inventory.selected] = {
		game.item_of_block(s.registry, .Stone),
		5,
		0,
		0,
	}
	net_send(c, protocol.Use_Entity{id, c.seq})
	net_for(t, {c}, 0.3)
	testing.expect_value(t, entity_data(s.home, e, Creature_Data).number, 5)

	// What the use costs: spent from what the player carries (kept by a mode that gives
	// without end); not when it carries too few.
	stone := game.item_of_block(s.registry, .Stone)
	infinite := has_ability(s, player, .Infinite_Items)
	testing.expect(t, item_spend(s, player, stone, 2))
	testing.expect_value(t, game.inventory_count(&player.inventory, stone), 5 if infinite else 3)
	testing.expect(t, !item_spend(s, player, stone, 9), "spent more than it carried")
}

// An entity hurt is told where the harm came from: the striker's place (where it would
// flee from).
@(test)
test_an_entity_is_told_where_harm_came_from :: proc(t: ^testing.T) {
	Seen :: struct {
		from: [3]f64,
		hurt: int,
	}
	config := harness_world()
	config.listen = true
	config.game = harness_creatures()
	config.game.server_state = Seen
	config.game.entity_hurt = proc(
		s: ^Server,
		w: ^World,
		h: game.Entity_Handle,
		harm: Entity_Harm,
	) {
		seen := game_state(s, Seen)
		seen.from, seen.hurt = harm.from, seen.hurt + 1
	}
	h := new(Harness)
	defer free(h)
	if !testing.expect(t, harness_start(h, config)) {return}
	defer harness_stop(h)
	c := new(Net_Client)
	defer free(c)
	net_connect(c, 0, "striker", h = h)
	defer net_close(c)
	standing :: proc(cs: []^Net_Client) -> bool {return(
			cs[0].welcomed &&
			cs[0].update.state.on_ground \
		)}
	if !testing.expect(t, net_wait(t, {c}, standing), "never stood") {return}
	s := &h.srv
	player := client_by_name(s, "striker")
	kind, _ := game.registry_kind(s.registry, "creatures:walker")
	e := entity_spawn(s.home, kind, player.player.position + {1.5, 0, 0}, false)
	net_send(c, protocol.Attack{entity_id(s.home, e), c.seq})
	net_for(t, {c}, 0.3)
	seen := game_state(s, Seen)
	testing.expect_value(t, seen.hurt, 1)
	d := seen.from - player.player.position
	testing.expectf(
		t,
		d.x * d.x + d.y * d.y + d.z * d.z < 0.01,
		"from %v, the striker at %v",
		seen.from,
		player.player.position,
	)
}

// A game's own statistics are counted with the character and its world as the engine's
// are, kept with the character, and their names are checked at start: none of the
// engine's, each once.
@(test)
test_a_games_statistics_are_kept_with_the_character :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		game_stats_valid({{name = "herded", kind = .Count}, {name = "trotted", kind = .Distance}}),
		"",
	)
	testing.expect(
		t,
		game_stats_valid({{name = "xp", kind = .Count}}) != "",
		"the engine's xp was taken",
	)
	testing.expect(
		t,
		game_stats_valid({{name = "blocks.herded", kind = .Count}}) != "",
		"the engine's blocks were taken",
	)
	testing.expect(
		t,
		game_stats_valid({{name = "Herded", kind = .Count}}) != "",
		"a capital was taken",
	)
	testing.expect(
		t,
		game_stats_valid({{name = "a", kind = .Count}, {name = "a", kind = .Time}}) != "",
		"a name twice",
	)
	dir :: "build/tmp/test_game_stats"
	os.remove_all(dir)
	defer os.remove_all(dir)
	h := new(Harness)
	defer free(h)
	standing :: proc(cs: []^Net_Client) -> bool {return(
			cs[0].welcomed &&
			cs[0].update.state.on_ground \
		)}
	for round in 0 ..< 2 {
		if !testing.expect(t, start_counting(h, dir)) {return}
		c := new(Net_Client)
		net_connect(c, 0, "herder", h = h)
		if testing.expect(t, net_wait(t, {c}, standing), "never stood") {
			s := &h.srv
			player := client_by_name(s, "herder")
			if round == 0 {
				xp := player.stats["xp"]
				stat_count(s, player, "herded", 3)
				testing.expect_value(t, player.stats["xp"], xp + 6)
				stat_count(s, player, "trotted", 250)
				stat_world(s, s.home, "herded")
			}
			testing.expect_value(t, player.stats["herded"], 3)
			testing.expect_value(t, player.stats["distance.trotted"], 250)
			testing.expect_value(t, s.home.stats["herded"], 4)
		}
		net_close(c)
		free(c)
		harness_step(h, 4)
		testing.expect(t, harness_stop(h))
	}
}

// start_counting: the creatures game counting two statistics on h, started from a call
// that returns before they are counted (the session keeps its own copy of the game's
// list, not the caller's).
@(private = "file")
start_counting :: proc(h: ^Harness, dir: string) -> bool {
	config := harness_world()
	config.listen = true
	config.save_dir = dir
	config.game = harness_creatures()
	config.game.stats = {
		{name = "herded", kind = .Count, xp = 2},
		{name = "trotted", kind = .Distance},
	}
	return harness_start(h, config)
}

// A creature that dies leaves its kind's drops where it fell, each by its chance, booked
// as a creature's drop; one that goes without dying leaves nothing.
@(test)
test_a_creature_leaves_its_drops :: proc(t: ^testing.T) {
	config := harness_world()
	config.game = harness_creatures()
	h := new(Harness)
	defer free(h)
	if !testing.expect(t, harness_start(h, config)) {return}
	defer harness_stop(h)
	s := &h.srv
	w := s.home
	quarry, _ := game.registry_kind(s.registry, "creatures:quarry")
	wheat, _ := game.registry_item(s.registry, "voxiverse:wheat")
	seeds, _ := game.registry_item(s.registry, "voxiverse:seeds")
	lying :: proc(w: ^World, item: game.Item) -> (n: int) {
		it := entities_each(w)
		for e in entities_next(&it) {
			if entity_kind(w, e) != w.server.registry.engine.item {continue}
			if st := entity_stack(w, e)^; st.item == item {n += st.count}
		}
		return
	}
	gone := entity_spawn(w, quarry, {-3.5, 1, 0.5}, false)
	entity_gone(w, gone)
	harness_step(h)
	testing.expect_value(t, lying(w, wheat), 0)

	e := entity_spawn(w, quarry, {3.5, 1, 0.5}, false)
	if !testing.expect(t, e != 0) {return}
	testing.expect(t, entity_harm(w, e, {amount = 5, kind = .Game}), "it lived")
	harness_step(h)
	testing.expect_value(t, lying(w, wheat), 2)
	testing.expect_value(t, lying(w, seeds), 0)
	testing.expect_value(t, s.ledger.entries[wheat][.Drop_Mob], 2)
}
