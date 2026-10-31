package server

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "common:game"
import "common:netcode"

// M8's exit check: an entity simulated on the server, seen by the players
// near it and only them, hit to death, and kept by the save. Over real
// sockets, as players reach a dedicated server.
@(test)
test_entities_replicated_hit_and_saved :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "entities"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	config := Config {
		seed            = 21,
		view_radius     = 3,
		view_height     = 2,
		max_players     = 4,
		listen          = true,
		everyone_cheats = true, // summon, tp, time
		save_dir        = dir,
	}
	h: Harness
	if !testing.expect(t, harness_start(&h, config)) {return}
	stopped := false
	defer if !stopped {harness_stop(&h)}

	near, far: Net_Client
	net_connect(&near, 0, "near", h = &h)
	net_connect(&far, 0, "far", h = &h)
	defer net_close(&near)
	defer net_close(&far)
	ok := net_wait(
		t,
		{&near, &far},
		proc(cs: []^Net_Client) -> bool {return landed(cs[0]) && landed(cs[1])},
	)
	if !testing.expect(t, ok, "never landed") {return}
	// Night: no sheep of their own accord, only ours. Far goes away.
	net_send(&near, game.Command{"time midnight"})
	net_send(&far, game.Teleport{position = {600.5, 120, 0.5}})
	ok = net_wait(
		t,
		{&near, &far},
		proc(cs: []^Net_Client) -> bool {return cs[1].update.state.position.x > 500},
	)
	testing.expect(t, ok, "far never moved away")

	net_send(&near, game.Command{"summon sheep"})
	ok = net_wait(
		t,
		{&near, &far},
		proc(cs: []^Net_Client) -> bool {return len(cs[0].entities) == 1},
	)
	if !testing.expect(t, ok, "the summoned sheep never showed up") {return}
	testing.expect_value(t, len(far.entities), 0) // too far to be told

	// It lives: it moves about over the next seconds, on the ground.
	id: u32
	start_at: [3]f64
	for k, p in near.entities {id, start_at = k, p}
	moved := false
	for _ in 0 ..< 20 * game.TICK_RATE {
		if moved {break}
		net_pump(t, &near)
		net_pump(t, &far)
		harness_step(&h)
		p := near.entities[id]
		d := p - start_at
		if math.sqrt(d.x * d.x + d.z * d.z) > 1 {moved = true}
		testing.expectf(t, abs(p.y - start_at.y) < 4, "fell or flew: %v from %v", p, start_at)
	}
	testing.expect(t, moved, "the sheep never wandered")

	// Far comes over: now it is told; goes again: told it is gone.
	at := near.entities[id]
	net_send(&far, game.Teleport{position = at + {3, 2, 0}})
	ok = net_wait(
		t,
		{&near, &far},
		proc(cs: []^Net_Client) -> bool {return len(cs[1].entities) == 1},
	)
	testing.expect(t, ok, "far never saw the sheep it walked up to")
	net_send(&far, game.Teleport{position = {600.5, 120, 0.5}})
	ok = net_wait(
		t,
		{&near, &far},
		proc(cs: []^Net_Client) -> bool {return len(cs[1].entities) == 0},
	)
	testing.expect(t, ok, "far was not told the sheep left its area")

	// Out of reach: nothing happens.
	net_send(&far, game.Attack{id, far.seq})
	net_for(t, {&near, &far}, 0.2)
	testing.expect_value(t, near.hurt, 0)

	// Near walks up and hits it four times: three flinches, then it dies,
	// and it is gone for good.
	for hit in 0 ..< 4 {
		p, known := near.entities[id]
		if !testing.expectf(t, known, "lost sight of the sheep before hit %d", hit + 1) {break}
		// Next to it (it runs once hit); the server takes the teleport
		// first: the same ordered stream.
		net_send(&near, game.Teleport{position = p + {1.2, 0, 0}})
		net_send(&near, game.Attack{id, near.seq})
		@(static) want: int
		want = hit + 1
		ok = net_wait(
			t,
			{&near},
			proc(cs: []^Net_Client) -> bool {return cs[0].hurt + cs[0].died >= want},
		)
		if !testing.expectf(t, ok, "hit %d did nothing", hit + 1) {break}
	}
	testing.expect_value(t, near.hurt, 3)
	testing.expect_value(t, near.died, 1)

	// Saved: another one, then quit and load.
	net_send(&near, game.Command{"summon sheep"})
	ok = net_wait(t, {&near}, proc(cs: []^Net_Client) -> bool {return len(cs[0].entities) == 1})
	testing.expect(t, ok)
	// A rocket straight up, still flying when the server stops: not saved.
	net_send(&near, game.Fire{near.seq, 0, 1.5})
	ok = net_wait(t, {&near}, proc(cs: []^Net_Client) -> bool {return len(cs[0].entities) == 2})
	testing.expect(t, ok, "the rocket never showed up")
	netcode.link_close(&near.link, "bye")
	netcode.link_close(&far.link, "bye")
	harness_step(&h, 4)
	testing.expect(t, harness_stop(&h))
	stopped = true
	saved, _ := os.read_entire_file_from_path(
		filepath.join({home_dir(dir, 21), ENTITIES_FILE}, context.temp_allocator) or_else "",
		context.temp_allocator,
	)
	testing.expect(t, strings.contains(string(saved), "sheep"), "the sheep was not saved")
	testing.expect(t, !strings.contains(string(saved), "rocket"), "a rocket in flight was saved")
	if !testing.expect(t, harness_start(&h, config)) {return}
	stopped = false
	// Near comes back where it left, beside the saved sheep.
	again: Net_Client
	net_connect(&again, 0, "near", h = &h)
	defer net_close(&again)
	ok = net_wait(t, {&again}, proc(cs: []^Net_Client) -> bool {return len(cs[0].entities) == 1})
	testing.expect(t, ok, "the saved sheep did not come back")
}

// Sheep come by themselves in daylight (no more than the cap), and go
// once nobody is near.
@(test)
test_sheep_spawn_and_despawn :: proc(t: ^testing.T) {
	config := Config {
		seed            = 21,
		generator       = .Classic, // grass near the spawn
		view_radius     = 4,
		view_height     = 2,
		max_players     = 2,
		listen          = true,
		everyone_cheats = true,
	}
	h: Harness
	if !testing.expect(t, harness_start(&h, config)) {return}
	defer harness_stop(&h)
	c: Net_Client
	net_connect(&c, 0, "watcher", h = &h)
	defer net_close(&c)
	ok := net_wait(
		t,
		{&c},
		proc(cs: []^Net_Client) -> bool {return landed(cs[0]) && len(cs[0].chunks) > 200},
	)
	if !testing.expect(t, ok, "never landed") {return}
	net_send(&c, game.Command{"time noon"})
	most := 0
	for _ in 0 ..< 40 * game.TICK_RATE {
		if len(c.entities) >= 3 {break}
		net_pump(t, &c)
		most = max(most, len(c.entities))
		harness_step(&h)
	}
	testing.expectf(t, len(c.entities) >= 1, "no sheep came in daylight (most seen %d)", most)
	for _ in 0 ..< 60 {
		net_pump(t, &c)
		most = max(most, len(c.entities))
		harness_step(&h)
	}
	testing.expectf(
		t,
		most <= SPAWN_CAP + 2,
		"%d sheep: the cap is %d (a herd may top it by 2)",
		most,
		SPAWN_CAP,
	)

	// Night, and away: they go, and the watcher is told.
	net_send(&c, game.Command{"time midnight"})
	net_send(&c, game.Teleport{position = {0.5, 140, 400.5}})
	ok = net_wait(t, {&c}, proc(cs: []^Net_Client) -> bool {return len(cs[0].entities) == 0}, 20)
	testing.expect(t, ok, "sheep stayed known after the watcher left")
}
