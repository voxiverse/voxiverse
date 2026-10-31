package server

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "common:game"

// entity_count: the entities awake in client name's world.
@(private = "file")
entity_count :: proc(srv: ^Server, name: string) -> (n: int) {
	Data :: struct {
		name:  string,
		count: int,
	}
	d := Data {
		name = name,
	}
	call(srv, proc(s: ^Server, data: rawptr) {
			d := (^Data)(data)
			d.count = len(client_by_name(s, d.name).world.entities.list)
		}, &d)
	return d.count
}

// The playtest crash: /summon spammed past the arena's limit, then one
// explosion kills them all in the same tick (deaths, drops, despawns). A
// full arena refuses (with a notice to the summoner), the game goes on.
@(test)
test_full_arena_and_one_blast :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "arena"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	config := Config {
		rules           = quiet_rules(),
		seed            = 81,
		view_radius     = 3,
		view_height     = 2,
		max_players     = 2,
		listen          = true,
		everyone_cheats = true,
		save_dir        = dir,
		no_sheep        = true,
	}
	h: Harness
	if !testing.expect(t, harness_start(&h, config)) {return}
	stopped := false
	defer if !stopped {harness_stop(&h)}
	a: Net_Client
	net_connect(&a, 0, "a", h = &h)
	defer net_close(&a)
	ok := net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return landed(cs[0])})
	if !testing.expect(t, ok, "never landed") {return}
	net_send(&a, game.Command{"time midnight"})
	for _ in 0 ..< MAX_ENTITIES / 20 + 10 {
		net_send(&a, game.Command{"summon sheep 20"})
		net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return false}, 0.05)
	}
	net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return false}, 0.5)
	testing.expect_value(t, entity_count(&h.srv, "a"), MAX_ENTITIES) // full, and no more
	refused := false
	for n in a.notices {refused ||= strings.contains(n, "Too many entities")}
	testing.expect(t, refused, "the summoner was not told the arena is full")

	// One blast over them all.
	call(
		&h.srv,
		proc(s: ^Server, _: rawptr) {
			c := client_by_name(s, "a")
			p := c.player.position
			for &e in c.world.entities.list {e.health = 1} 	// (one blast kills any)
			explode_by(s, "a", {i32(p.x), i32(p.y), i32(p.z)}, 12)
		},
		nil,
	)
	for _ in 0 ..< 3 * game.TICK_RATE {
		net_pump(t, &a)
		harness_step(&h)
	}
	testing.expect(t, entity_count(&h.srv, "a") < MAX_ENTITIES, "the blast killed nothing")
	testing.expect_value(t, entity_count(&h.srv, "a"), 0)
	net_close(&a)
	a = {}
	harness_step(&h, 4)
	testing.expect(t, harness_stop(&h))
	stopped = true
}
