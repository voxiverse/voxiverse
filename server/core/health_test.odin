package core

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "common:game"
import "common:protocol"
import "common:telemetry"

@(private = "file")
config :: proc(dir: string) -> Config {
	rules := quiet_rules()
	return {
		mode              = "survival", // (health is an ability of it)
		seed              = 28,
		generator         = .Classic,
		rules             = rules,
		view_radius       = 3,
		view_height       = 2,
		max_players       = 4,
		listen            = true,
		everyone_cheats   = true,
		save_dir          = dir,
		no_natural_spawns = true,
	}
}

@(private = "file")
was_dead, first_respawn, second_respawn: bool

@(private = "file")
Probe :: struct {
	name:   string,
	health: f32,
	max:    f32,
	pos:    [3]f64,
	xp:     u64,
	level:  u64,
	items:  int,
}

@(private = "file")
probe :: proc(srv: ^Server, name: string) -> Probe {
	p := Probe {
		name = name,
	}
	call(srv, proc(s: ^Server, data: rawptr) {
			p := (^Probe)(data)
			if c := client_by_name(s, p.name); c != nil {
				p.health, p.max, p.pos = c.health, c.max_health, c.player.position
				p.xp, p.level = c.stats["xp"] or_else 0, c.stats["level"] or_else 1
				for st in c.inventory.slots {if !game.stack_empty(st) {p.items += 1}}
			}
		}, &p)
	return p
}

@(private = "file")
with_client :: proc(srv: ^Server, name: string, body: proc(s: ^Server, c: ^Client)) {
	Data :: struct {
		name: string,
		body: proc(s: ^Server, c: ^Client),
	}
	d := Data{name, body}
	call(srv, proc(s: ^Server, data: rawptr) {
			d := (^Data)(data)
			if c := client_by_name(s, d.name); c != nil {d.body(s, c)}
		}, &d)
}

@(private = "file")
pause :: proc(t: ^testing.T, clients: []^Net_Client, seconds: f64) {
	net_wait(t, clients, proc(cs: []^Net_Client) -> bool {return false}, seconds)
}

// The server half: a fall costs a point a block past three; an explosion by
// its nearness; death sends a player to the spawn with full health, their
// things dropped by the rule; rules.damage off hurts nothing; the client is
// told; experience is earned only where the registry has a level curve (the base pack
// has none: games/sandbox's tests hold what earns it), and what a character has is kept.
@(test)
test_damage_death_and_xp :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "health"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	h := new(Harness)
	defer free(h)
	srv := &h.srv
	if !testing.expect(t, harness_start(h, config(dir))) {return}
	stopped := false
	defer if !stopped {harness_stop(h)}
	a := new(Net_Client)
	defer free(a)
	net_connect(a, 0, "a", h = h)
	defer net_close(a)
	ok := net_wait(t, {a}, proc(cs: []^Net_Client) -> bool {return landed(cs[0])})
	if !testing.expect(t, ok, "never landed") {return}
	pause(t, {a}, 0.3)
	start_at := probe(srv, "a")
	testing.expect_value(t, start_at.health, f32(game.BASE_HEALTH))
	ok = net_wait(
		t,
		{a},
		proc(cs: []^Net_Client) -> bool {return cs[0].health.max == game.BASE_HEALTH},
	)
	testing.expect(t, ok, "the client was not told its health")

	// A fall of 8 blocks: 5 points.
	with_client(srv, "a", proc(s: ^Server, c: ^Client) {
		c.player.position.y += 8
		c.player.on_ground = false
		c.player.velocity = {}
	})
	// (a slow runner takes a while to land: wait for the hurt, then for it to settle)
	for _ in 0 ..< 40 {
		pause(t, {a}, 0.25)
		if probe(srv, "a").health < game.BASE_HEALTH {break}
	}
	pause(t, {a}, 0.5)
	after := probe(srv, "a")
	testing.expectf(
		t,
		abs(after.health - (game.BASE_HEALTH - 5)) < 0.6,
		"an 8 block fall left %.2f of %d",
		after.health,
		game.BASE_HEALTH,
	)
	ok = net_wait(
		t,
		{a},
		proc(cs: []^Net_Client) -> bool {return cs[0].health.health < game.BASE_HEALTH - 4},
	)
	testing.expect(t, ok, "the client was not told it was hurt")
	// A short fall costs nothing.
	hurt := after.health
	with_client(srv, "a", proc(s: ^Server, c: ^Client) {
		c.player.position.y += 2
		c.player.on_ground = false
	})
	pause(t, {a}, 1)
	testing.expect_value(t, probe(srv, "a").health, hurt)

	// An explosion 3 blocks away, blast reach 8: (1 - 3/8) * 12 = 7.5.
	with_client(srv, "a", proc(s: ^Server, c: ^Client) {
		c.health = c.max_health
		explode(c.world, c.player.position + {3, 0.9, 0}, 4, world_act(c.world, .Explosion).action)
	})
	hit := probe(srv, "a")
	testing.expectf(
		t,
		abs(hit.health - (game.BASE_HEALTH - 7.5)) < 1.2,
		"an explosion 3 away left %.2f",
		hit.health,
	)

	// A mode without health (and invulnerable): nothing hurts.
	with_client(srv, "a", proc(s: ^Server, c: ^Client) {
		c.health = c.max_health
		creative, _ := game.mode_find(s.registry, "creative")
		survival := c.mode
		set_game_mode(s, c, creative, {"test", ""})
		damage(s, c, 100, {kind = .Command})
		set_game_mode(s, c, survival, {"test", ""})
		c.health = c.max_health
	})
	pause(t, {a}, 0.1) // (the tick that takes it in)
	testing.expect_value(t, probe(srv, "a").health, f32(game.BASE_HEALTH))

	// Death: full health at the spawn again, the inventory kept (keep_inventory).
	with_client(srv, "a", proc(s: ^Server, c: ^Client) {
		c.player.position += {40, 0, 40}
		damage(s, c, 100, {kind = .Command})
	})
	pause(t, {a}, 0.5)
	testing.expect(t, a.health.dead && a.deaths == 1, "the client was told it is dead")
	testing.expect_value(t, probe(srv, "a").health, f32(0))
	with_client(srv, "a", proc(s: ^Server, c: ^Client) {
		was_dead, first_respawn, second_respawn = c.dead, respawn(s, c), respawn(s, c)
	})
	testing.expect(t, was_dead && first_respawn && !second_respawn, "respawn works once")
	pause(t, {a}, 0.5)
	died := probe(srv, "a")
	testing.expect_value(t, died.health, f32(game.BASE_HEALTH))
	testing.expectf(
		t,
		abs(died.pos.x - start_at.pos.x) < 30 && abs(died.pos.z - start_at.pos.z) < 30,
		"died at %v, started at %v",
		died.pos,
		start_at.pos,
	)
	testing.expect(t, died.items > 0, "the inventory was dropped though keep_inventory is on")
	// Without keep_inventory: dropped where they fell.
	with_client(srv, "a", proc(s: ^Server, c: ^Client) {
		c.world.rules.keep_inventory = false
		damage(s, c, 100, {kind = .Command})
		c.world.rules.keep_inventory = true
		respawn(s, c)
	})
	// (nothing of what they held: respawn gives the survival kit: six items in the slots, the boots worn)
	testing.expect_value(t, probe(srv, "a").items, 6)

	// Experience: with no level curve, mining a hundred blocks and a deed of the game's
	// earn none; what the character has (here a hundred, given) is kept.
	xp0 := probe(srv, "a").xp
	with_client(srv, "a", proc(s: ^Server, c: ^Client) {
		for _ in 0 ..< 100 {record(s, c, .Block_Mined, "stone")}
		experience_gain(s, c, 50)
		stat_add(c, "xp", 100)
	})
	grown := probe(srv, "a")
	testing.expect_value(t, grown.xp, xp0 + 100)

	// The events carry the causes; the log has them.
	call(srv, proc(s: ^Server, data: rawptr) {telemetry.sink_flush(&s.sink)}, nil)
	log_text := read_log(dir)
	testing.expect(
		t,
		strings.contains(log_text, `"k":"damage","world"`) &&
		strings.contains(log_text, `"cause":"fall"`) &&
		strings.contains(log_text, `"cause":"explosion"`),
	)
	testing.expect(t, strings.contains(log_text, `"k":"death"`))

	// Kept: the experience through save and load.
	net_close(a)
	a^ = {}
	harness_step(h, 4)
	expect_items_balanced(t, srv)
	testing.expect(t, harness_stop(h))
	stopped = true
	if !testing.expect(t, harness_start(h, config(dir))) {return}
	stopped = false
	again := new(Net_Client)
	defer free(again)
	net_connect(again, 0, "a", h = h)
	defer net_close(again)
	ok = net_wait(t, {again}, proc(cs: []^Net_Client) -> bool {return landed(cs[0])})
	testing.expect(t, ok)
	back := probe(srv, "a")
	testing.expect_value(t, back.xp, grown.xp)
	testing.expect_value(t, back.level, grown.level)
	free_all(context.temp_allocator)
}

// What a player wears changes their health: the server derives it from the
// worn armor and tells the client (the client's prediction derives the speed
// and jump from the same inventory: common/game/physics_test.odin).
@(test)
test_worn_armor_raises_health :: proc(t: ^testing.T) {
	h := new(Harness)
	defer free(h)
	if !testing.expect(t, harness_start(h, config(""))) {return}
	defer harness_stop(h)
	a := new(Net_Client)
	defer free(a)
	net_connect(a, 0, "a", h = h)
	defer net_close(a)
	ok := net_wait(
		t,
		{a},
		proc(cs: []^Net_Client) -> bool {return(
				landed(cs[0]) &&
				cs[0].health.max == game.BASE_HEALTH \
			)},
	)
	if !testing.expect(t, ok, "never landed with its health") {return}
	for item in ([]string{"cap", "tunic", "trousers", "boots"}) {
		net_send(a, protocol.Command{fmt.tprintf("give @s %s", item)})
	}
	net_send(a, protocol.Command{"wear"})
	ok = net_wait(
		t,
		{a},
		proc(cs: []^Net_Client) -> bool {return cs[0].health.max == game.BASE_HEALTH + 8},
	)
	testing.expectf(
		t,
		ok,
		"worn armor gave %.0f health points, not %d",
		a.health.max,
		game.BASE_HEALTH + 8,
	)
	// Taking one off lowers it (and what was in excess is cut off).
	net_send(a, protocol.Command{"clear @s tunic"})
	pause(t, {a}, 0.3)
	net_send(
		a,
		protocol.Inventory_Request {
			1,
			{.Quick_Move, game.EQUIP_BASE + int(game.Equip_Slot.Chest), 0},
		},
	)
	ok = net_wait(
		t,
		{a},
		proc(cs: []^Net_Client) -> bool {return cs[0].health.max == game.BASE_HEALTH + 4},
	)
	testing.expect(t, ok, "the tunic taken off did not lower the maximum")
}

// A game's health bonus raises a player's most health from the next tick (its health
// tops out there, and a respawn fills it); taken away, the most falls and cuts what it
// has; heal_player heals up to the most, and not the dead.
@(test)
test_game_health_bonus :: proc(t: ^testing.T) {
	sess := new(Session)
	defer free(sess)
	config := harness_world()
	config.mode = "survival"
	if !testing.expect(t, session_start(sess, {}, false, with = config)) {
		session_stop(sess)
		return
	}
	defer session_stop(sess)
	_, ok := harness_step_until(&sess.h, proc(data: rawptr) -> bool {
			sess := (^Session)(data)
			return sess.mirror.welcomed && sess.h.srv.clients[0].state == .Playing
		}, sess, 600)
	if !testing.expect(t, ok) {return}
	s := &sess.h.srv
	c := &s.clients[0]
	base_most := c.max_health
	player_health_bonus(s, c, 6)
	harness_step(&sess.h)
	testing.expect_value(t, c.max_health, base_most + 6)
	heal_player(c, 100)
	testing.expect_value(t, c.health, base_most + 6)
	player_health_bonus(s, c, 2)
	harness_step(&sess.h)
	testing.expect_value(t, c.health, base_most + 2)
	damage(s, c, 1000, {kind = .Command})
	heal_player(c, 5)
	testing.expect_value(t, c.health, 0)
	harness_step(&sess.h)
	respawn(s, c)
	testing.expect_value(t, c.health, base_most + 2)
}

// /damage names its player by its name or by a selector (@s: whoever typed it), as /give
// and /xp do.
@(test)
test_damage_command_takes_a_selector :: proc(t: ^testing.T) {
	h := new(Harness)
	defer free(h)
	dir := filepath.join({"build", "test", "damage_selector"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	if !testing.expect(t, harness_start(h, config(dir))) {return}
	defer harness_stop(h)
	a := new(Net_Client)
	defer free(a)
	net_connect(a, 0, "a", h = h)
	defer net_close(a)
	ok := net_wait(t, {a}, proc(cs: []^Net_Client) -> bool {return landed(cs[0])})
	if !testing.expect(t, ok, "never landed") {return}
	s := &h.srv
	c := client_by_name(s, "a")
	c.protected_until = 0
	before := c.health
	testing.expect(t, admin_damage(s, c, {"@s", "3"}))
	testing.expect_value(t, c.health, before - 3)
	testing.expect(t, admin_damage(s, c, {"a", "2"}))
	testing.expect_value(t, c.health, before - 5)
}
