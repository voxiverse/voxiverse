package server

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

import "../game"
import "../telemetry"

@(private = "file")
config :: proc(dir: string) -> Config {
	return {
		seed = 28,
		generator = .Classic,
		rules = quiet_rules(),
		view_radius = 3,
		view_height = 2,
		workers = 2,
		max_players = 4,
		listen = true,
		everyone_cheats = true,
		save_dir = dir,
		no_sheep = true,
	}
}

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

// M28's server half: a fall costs a point a block past three; an explosion by
// its nearness; death sends a player to the spawn with full health, their
// things dropped by the rule; rules.damage off hurts nothing; the client is
// told; experience and level come from events and are kept.
@(test)
test_damage_death_and_xp :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "health"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	srv: Server
	if !testing.expect(t, start(&srv, config(dir), {})) {return}
	stopped := false
	defer if !stopped {stop(&srv)}
	a: Net_Client
	net_connect(&a, srv.host.socket.port, "a")
	defer net_close(&a)
	ok := net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return landed(cs[0])})
	if !testing.expect(t, ok, "never landed") {return}
	pause(t, {&a}, 0.3)
	start_at := probe(&srv, "a")
	testing.expect_value(t, start_at.health, f32(game.BASE_HEALTH))
	ok = net_wait(
		t,
		{&a},
		proc(cs: []^Net_Client) -> bool {return cs[0].health.max == game.BASE_HEALTH},
	)
	testing.expect(t, ok, "the client was not told its health")

	// A fall of 8 blocks: 5 points.
	with_client(&srv, "a", proc(s: ^Server, c: ^Client) {
		c.player.position.y += 8
		c.player.on_ground = false
		c.player.velocity = {}
	})
	// (a slow runner takes a while to land: wait for the hurt, then for it to settle)
	for _ in 0 ..< 40 {
		pause(t, {&a}, 0.25)
		if probe(&srv, "a").health < game.BASE_HEALTH {break}
	}
	pause(t, {&a}, 0.5)
	after := probe(&srv, "a")
	testing.expectf(
		t,
		abs(after.health - (game.BASE_HEALTH - 5)) < 0.6,
		"an 8 block fall left %.2f of %d",
		after.health,
		game.BASE_HEALTH,
	)
	ok = net_wait(
		t,
		{&a},
		proc(cs: []^Net_Client) -> bool {return cs[0].health.health < game.BASE_HEALTH - 4},
	)
	testing.expect(t, ok, "the client was not told it was hurt")
	// A short fall costs nothing.
	hurt := after.health
	with_client(&srv, "a", proc(s: ^Server, c: ^Client) {
		c.player.position.y += 2
		c.player.on_ground = false
	})
	pause(t, {&a}, 1)
	testing.expect_value(t, probe(&srv, "a").health, hurt)

	// An explosion 3 blocks away, blast reach 8: (1 - 3/8) * 12 = 7.5.
	with_client(&srv, "a", proc(s: ^Server, c: ^Client) {
		c.health = c.max_health
		explode(c.world, c.player.position + {3, 0.9, 0}, 4)
	})
	hit := probe(&srv, "a")
	testing.expectf(
		t,
		abs(hit.health - (game.BASE_HEALTH - 7.5)) < 1.2,
		"an explosion 3 away left %.2f",
		hit.health,
	)

	// rules.damage off: nothing hurts.
	with_client(&srv, "a", proc(s: ^Server, c: ^Client) {
		c.health = c.max_health
		c.world.rules.damage = false
		damage_player(s, c, 100, "test")
		c.world.rules.damage = true
	})
	testing.expect_value(t, probe(&srv, "a").health, f32(game.BASE_HEALTH))

	// Death: full health at the spawn again, the inventory kept (death_drops off).
	with_client(&srv, "a", proc(s: ^Server, c: ^Client) {
		c.player.position += {40, 0, 40}
		damage_player(s, c, 100, "test")
	})
	pause(t, {&a}, 0.5)
	died := probe(&srv, "a")
	testing.expect_value(t, died.health, f32(game.BASE_HEALTH))
	testing.expectf(
		t,
		abs(died.pos.x - start_at.pos.x) < 30 && abs(died.pos.z - start_at.pos.z) < 30,
		"died at %v, started at %v",
		died.pos,
		start_at.pos,
	)
	testing.expect(t, died.items > 0, "the inventory was dropped though death_drops is off")
	// With death_drops: dropped where they fell.
	with_client(&srv, "a", proc(s: ^Server, c: ^Client) {
		c.world.rules.death_drops = true
		damage_player(s, c, 100, "test")
		c.world.rules.death_drops = false
	})
	testing.expect_value(t, probe(&srv, "a").items, 0)

	// Experience: 100 points of mining is level 2 (one level up, and only one).
	xp0 := probe(&srv, "a").xp
	with_client(&srv, "a", proc(s: ^Server, c: ^Client) {
		for _ in 0 ..< 100 {record(s, c, .Block_Mined, "stone")}
	})
	grown := probe(&srv, "a")
	testing.expect_value(t, grown.xp, xp0 + 100)
	testing.expect_value(t, grown.level, level_of(xp0 + 100))
	testing.expect(t, level_of(xp0 + 100) >= 2)
	testing.expect_value(t, level_of(0), 1)
	testing.expect_value(t, level_of(99), 1)
	testing.expect_value(t, level_of(100), 2)
	testing.expect_value(t, level_of(299), 2)
	testing.expect_value(t, level_of(300), 3)

	// The events carry the causes; the log has them.
	call(&srv, proc(s: ^Server, data: rawptr) {telemetry.sink_flush(&s.sink)}, nil)
	log_text := read_log(dir)
	testing.expect(
		t,
		strings.contains(log_text, `"k":"damage","world"`) &&
		strings.contains(log_text, `"cause":"fall"`) &&
		strings.contains(log_text, `"cause":"explosion"`),
	)
	testing.expect(
		t,
		strings.contains(log_text, `"k":"death"`) && strings.contains(log_text, `"k":"level_up"`),
	)

	// Kept: the experience through save and load.
	net_close(&a)
	a = {}
	time.sleep(100 * time.Millisecond)
	expect_items_balanced(t, &srv)
	testing.expect(t, stop(&srv))
	stopped = true
	if !testing.expect(t, start(&srv, config(dir), {})) {return}
	stopped = false
	again: Net_Client
	net_connect(&again, srv.host.socket.port, "a")
	defer net_close(&again)
	ok = net_wait(t, {&again}, proc(cs: []^Net_Client) -> bool {return landed(cs[0])})
	testing.expect(t, ok)
	back := probe(&srv, "a")
	testing.expect_value(t, back.xp, grown.xp)
	testing.expect_value(t, back.level, grown.level)
	free_all(context.temp_allocator)
}

@(private = "file")
read_log :: proc(dir: string) -> string {
	infos, _ := os.read_all_directory_by_path(
		filepath.join({dir, "telemetry"}, context.temp_allocator) or_else "",
		context.temp_allocator,
	)
	b := strings.builder_make(context.temp_allocator)
	for info in infos {
		data, _ := os.read_entire_file_from_path(info.fullpath, context.temp_allocator)
		strings.write_string(&b, string(data))
	}
	return strings.to_string(b)
}

// What a player wears changes their health: the server derives it from the
// worn armor and tells the client (the client's prediction derives the speed
// and jump from the same inventory: game/physics_test.odin).
@(test)
test_worn_armor_raises_health :: proc(t: ^testing.T) {
	srv: Server
	if !testing.expect(t, start(&srv, config(""), {})) {return}
	defer stop(&srv)
	a: Net_Client
	net_connect(&a, srv.host.socket.port, "a")
	defer net_close(&a)
	ok := net_wait(
		t,
		{&a},
		proc(cs: []^Net_Client) -> bool {return(
				landed(cs[0]) &&
				cs[0].health.max == game.BASE_HEALTH \
			)},
	)
	if !testing.expect(t, ok, "never landed with its health") {return}
	for item in ([]string{"cap", "tunic", "trousers", "boots"}) {
		net_send(&a, game.Command{fmt.tprintf("give @s %s", item)})
	}
	net_send(&a, game.Command{"wear"})
	ok = net_wait(
		t,
		{&a},
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
	net_send(&a, game.Command{"clear @s tunic"})
	pause(t, {&a}, 0.3)
	net_send(
		&a,
		game.Inventory_Request{1, {.Quick_Move, game.EQUIP_BASE + int(game.Equip_Slot.Chest), 0}},
	)
	ok = net_wait(
		t,
		{&a},
		proc(cs: []^Net_Client) -> bool {return cs[0].health.max == game.BASE_HEALTH + 4},
	)
	testing.expect(t, ok, "the tunic taken off did not lower the maximum")
}
