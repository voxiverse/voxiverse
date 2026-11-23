package core

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "common:game"
import "common:protocol"
import "common:starmap"
import "common:worldgen"

// The exit check over UDP: wrong addresses are refused; a gate opens,
// alice walks through its opening to the far world's gate, and once the
// gates close she opens one home from there and walks back.
@(test)
test_gates_over_the_network :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "net_gates"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	os.make_directory_all(dir)
	perms := strings.concatenate(
		{DEFAULT_PERMISSIONS, "player alice\nrole admin\n"},
		context.temp_allocator,
	)
	testing.expect(
		t,
		os.write_entire_file(
			filepath.join({dir, PERMISSIONS_FILE}, context.temp_allocator) or_else "",
			transmute([]u8)perms,
		) ==
		nil,
	)
	config := Config {
		rules       = quiet_rules(),
		seed        = 1,
		view_radius = 2,
		view_height = 1,
		save_dir    = dir,
		max_players = 2,
		listen      = true,
		generator   = .Earth,
		gate_open   = 2,
	}
	h := new(Harness)
	defer free(h)
	if !testing.expect(t, harness_start(h, config)) {return}
	defer harness_stop(h)
	srv := &h.srv
	home := srv.home.address
	home_gen := worldgen.generator_make(.Earth, srv.home.seed, srv.registry, srv.home.params)
	here, has := worldgen.arrival_gate(&home_gen)
	if !testing.expect(t, has, "no gate at home") {return}
	// A world of this galaxy, and its gate (worked out here as anywhere).
	away := starmap.address_derive(77)
	away.galaxy = home.galaxy
	far_world := World {
		server  = srv,
		address = away,
	}
	world_kind(&far_world)
	far_gen := worldgen.generator_make(.Earth, far_world.seed, srv.registry, far_world.params)
	there, far_has := worldgen.arrival_gate(&far_gen)
	if !testing.expect(t, far_has, "no gate at the far end") {return}

	alice := new(Net_Client)
	defer free(alice)
	net_connect(alice, 0, "alice", h = h)
	defer net_close(alice)
	clients := []^Net_Client{alice}
	ok := net_wait(t, clients, proc(cs: []^Net_Client) -> bool {
			return cs[0].welcomed && cs[0].update.acked > 0
		}, 30)
	if !testing.expect(t, ok, "alice never joined") {return}

	// To the front of the gate (tp) and facing it.
	walk_up :: proc(t: ^testing.T, c: ^Net_Client, g: worldgen.Structure) -> bool {
		// Still first: inputs sent before a teleport still move one after it.
		c.move = {}
		if !net_wait(t, {c}, proc(cs: []^Net_Client) -> bool {return at_rest(cs[0])}, 10) {
			st := c.update.state
			log.errorf(
				"walk_up: never at rest: at %v, on ground %v, velocity %v",
				st.position,
				st.on_ground,
				st.velocity,
			)
			return false
		}
		front, yaw := worldgen.gate_front(g)
		net_send(c, protocol.Command{fmt.tprintf("tp %.1f %.1f %.1f", front.x, front.y, front.z)})
		c.look = {yaw + 3.14159265, 0}
		@(static) want: [3]f64
		want = front
		ok := net_wait(t, {c}, proc(cs: []^Net_Client) -> bool {
				p := cs[0].update.state.position
				return(
					abs(p.x - want.x) < 0.6 &&
					abs(p.z - want.z) < 0.6 &&
					cs[0].update.state.on_ground &&
					abs(cs[0].update.state.velocity.x) + abs(cs[0].update.state.velocity.z) <
						0.05 &&
					len(cs[0].chunks) > 20 \
				)
			}, 30)
		if !ok {
			st := c.update.state
			log.errorf(
				"walk_up: at %v (want %v), on ground %v, velocity %v, %d chunks; notices %v",
				st.position,
				want,
				st.on_ground,
				st.velocity,
				len(c.chunks),
				c.notices[:],
			)
		}
		return ok
	}
	if !testing.expect(t, walk_up(t, alice, here), "alice never reached the gate") {return}

	// Refusals: another galaxy, this very world, not a gate (and a symbol
	// twice is not an address: no Open_Gate decodes).
	refused :: proc(t: ^testing.T, c: ^Net_Client, d: protocol.Open_Gate, why: string) {
		before := len(c.notices)
		net_send(c, d)
		@(static) n: int
		n = before
		ok := net_wait(t, {c}, proc(cs: []^Net_Client) -> bool {return len(cs[0].notices) > n})
		testing.expectf(
			t,
			ok && strings.contains(c.notices[len(c.notices) - 1], why),
			"refused: %v",
			c.notices[before:],
		)
	}
	frame := worldgen.gate_at(here, 3, 5)
	elsewhere := away
	elsewhere.galaxy = starmap.address_derive(5).galaxy
	refused(t, alice, {frame, elsewhere}, "galaxy")
	refused(t, alice, {frame, home}, "own world")
	refused(t, alice, {frame - {0, 40, 0}, away}, "not a gate")

	// Open: the void fills the opening; walk in.
	@(static) gate: worldgen.Structure
	gate = here
	net_send(alice, protocol.Open_Gate{frame, away})
	ok = net_wait(t, clients, proc(cs: []^Net_Client) -> bool {
			return gate_seen(cs[0], gate, .Gate_Horizon)
		}, 10)
	if !testing.expect(t, ok, "the gate never opened") {return}

	alice.move = {0, 1}
	@(static) want: starmap.Address
	@(static) front: [3]f64
	want = away
	front, _ = worldgen.gate_front(there)
	ok = net_wait(t, clients, proc(cs: []^Net_Client) -> bool {return cs[0].address == want}, 30)
	if !testing.expect(t, ok, "alice never arrived") {return}
	alice.move = {}
	// By the far gate.
	ok = net_wait(t, clients, proc(cs: []^Net_Client) -> bool {
		p := cs[0].update.state.position
		return abs(p.x - front.x) < 1.5 && abs(p.z - front.z) < 1.5 && cs[0].update.state.on_ground
	})
	testing.expectf(
		t,
		ok,
		"arrived at %v, not by the gate (%v)",
		alice.update.state.position,
		front,
	)

	// The gates close; she opens the gate home from here and walks back.
	gate = there
	ok = net_wait(t, clients, proc(cs: []^Net_Client) -> bool {
			return len(cs[0].chunks) > 20 && gate_seen(cs[0], gate, .Air)
		}, 15)
	testing.expect(t, ok, "the far gate never closed")
	if !testing.expect(t, walk_up(t, alice, there)) {return}
	net_send(alice, protocol.Open_Gate{worldgen.gate_at(there, 10, 5), home})
	ok = net_wait(t, clients, proc(cs: []^Net_Client) -> bool {
			return gate_seen(cs[0], gate, .Gate_Horizon)
		}, 10)
	if !testing.expectf(t, ok, "the far gate never opened: %v", alice.notices[:]) {return}
	alice.move = {0, 1}
	want = home
	ok = net_wait(t, clients, proc(cs: []^Net_Client) -> bool {return cs[0].address == want}, 30)
	testing.expect(t, ok, "alice never came home")
	alice.move = {}
}

// gate_seen: whether c sees every cell of g's opening as b.
@(private = "file")
gate_seen :: proc(c: ^Net_Client, g: worldgen.Structure, b: game.Block) -> bool {
	inside := make([dynamic]game.Block_Pos, context.temp_allocator)
	worldgen.gate_inside(g, &inside)
	for p in inside {
		seen, known := net_block(c, p)
		if !known || seen != b {return false}
	}
	return true
}

// dead_gate_config: a new universe in dir whose home world has a home gate
// (as the sandbox's has), on the stepped harness.
@(private = "file")
dead_gate_config :: proc(dir: string, home_gate := true) -> Config {
	return {
		rules = quiet_rules(),
		seed = 1,
		view_radius = 2,
		view_height = 1,
		save_dir = dir,
		max_players = 2,
		listen = true,
		generator = .Earth,
		gate_open = 2,
		backups = 0,
		home_gate = home_gate,
	}
}

// A new universe's home gate stands dead in front of the spawn: opening it
// says only that it is dark, and opening a gate onto its world finds
// nothing there. Woken, it opens and is travelled through as any gate.
@(test)
test_gate_dead_until_woken :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "dead_gate"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	h := new(Harness)
	defer free(h)
	p := new(Harness_Player)
	defer free(p)
	if !testing.expect(t, harness_start(h, dead_gate_config(dir))) {return}
	harness_player_join(h, p, "alice")
	defer harness_player_free(p)
	defer harness_stop(h)
	srv := &h.srv
	w := srv.home
	home, has_home := w.chunks.gen.home.?
	if !testing.expect(t, has_home, "no home gate") {return}
	testing.expect(t, len(w.gates) == 1 && w.gates[0] == Gate{structure = home, phase = .Dead})
	// In front of the spawn, its front facing it.
	front, _ := worldgen.gate_front(home)
	ahead := w.spawn.position.z - front.z
	testing.expectf(
		t,
		abs(w.spawn.position.x - front.x) < 1 && ahead > 0 && ahead < 16,
		"the home gate's front %v, the spawn %v",
		front,
		w.spawn.position,
	)
	playing :: proc(data: rawptr) -> bool {
		c := harness_player_client((^Harness_Player)(data))
		return c != nil && c.state == .Playing
	}
	if _, ok := harness_step_until(h, playing, p, 900); !testing.expect(t, ok, "never played") {
		return
	}
	c := harness_player_client(p)
	away := starmap.address_derive(77)
	away.galaxy = w.address.galaxy
	frame := worldgen.gate_at(home, 3, 5)

	// Dead: dark here, and nothing answers from elsewhere.
	c.player.position = front
	testing.expect_value(t, gate_open(srv, c, {frame, away}), "the gate is dark")
	testing.expect_value(t, len(w.gates), 1)
	testing.expect_value(t, travel(srv, c, away), "")
	far, has_far := worldgen.arrival_gate(&c.world.chunks.gen)
	if !testing.expect(t, has_far, "no gate at the far end") {return}
	c.player.position, _ = worldgen.gate_front(far)
	testing.expect_value(
		t,
		gate_open(srv, c, {worldgen.gate_at(far, 0, 5), w.address}),
		"nothing answers at that address",
	)
	testing.expect_value(t, len(c.world.gates), 0)
	testing.expect_value(t, travel(srv, c, w.address), "")

	// Woken (once), and killed only at rest.
	testing.expect(t, !gate_kill(w, frame), "a dead gate killed again")
	testing.expect(t, gate_wake(w, frame), "the home gate did not wake")
	testing.expect(t, !gate_wake(w, frame), "a live gate woken")
	testing.expect_value(t, len(w.gates), 0)
	testing.expect(t, !gate_wake(w, frame - {0, 40, 0}), "woke what is not a gate")

	// Alive: opened, and walked through to the far gate.
	c.player.position = front
	testing.expect_value(t, gate_open(srv, c, {frame, away}), "")
	testing.expect(t, !gate_kill(w, frame), "a gate in use killed")
	Walk :: struct {
		c:       ^Client,
		opening: [3]f64,
		to:      starmap.Address,
	}
	centre := worldgen.gate_at(home, 5, 1)
	walk := Walk{c, {f64(centre.x) + 0.5, f64(centre.y), f64(centre.z) + 0.5}, away}
	through :: proc(data: rawptr) -> bool {
		walk := (^Walk)(data)
		if walk.c.world.address == walk.to {return true}
		walk.c.player.position, walk.c.landing = walk.opening, nil // (in the opening)
		return false
	}
	_, through_ok := harness_step_until(h, through, &walk, 20 * game.TICK_RATE)
	testing.expect(t, through_ok, "never went through the woken gate")
}

// Dead gates are saved with their world and come back with it; a woken one
// stays alive. A universe made before home gates (none asked for) gets none
// when opened by a game that asks: every gate of it lives.
@(test)
test_gate_dead_saved :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "dead_gate_saved"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	h := new(Harness)
	defer free(h)
	if !testing.expect(t, harness_start(h, dead_gate_config(dir))) {return}
	home, _ := h.srv.home.chunks.gen.home.?
	testing.expect(t, harness_stop(h))

	if !testing.expect(t, harness_start(h, dead_gate_config(dir))) {return}
	w := h.srv.home
	testing.expect(
		t,
		len(w.gates) == 1 && w.gates[0].phase == .Dead && w.gates[0].structure.lo == home.lo,
		"the dead gate did not come back",
	)
	testing.expect(t, gate_wake(w, home.lo), "the reloaded gate did not wake")
	testing.expect(t, harness_stop(h))

	if !testing.expect(t, harness_start(h, dead_gate_config(dir))) {return}
	testing.expect_value(t, len(h.srv.home.gates), 0)
	testing.expect_value(t, h.srv.home.chunks.gen.home, home)
	testing.expect(t, harness_stop(h))

	// Made without a home gate, opened by a game that asks for one.
	os.remove_all(dir)
	if !testing.expect(t, harness_start(h, dead_gate_config(dir, home_gate = false))) {return}
	testing.expect(t, harness_stop(h))
	if !testing.expect(t, harness_start(h, dead_gate_config(dir))) {return}
	w = h.srv.home
	_, has_home := w.chunks.gen.home.?
	testing.expect(t, !has_home, "an older universe was given a home gate")
	testing.expect_value(t, len(w.gates), 0)
	arrival, has := worldgen.arrival_gate(&w.chunks.gen)
	testing.expect(t, has, "the older universe lost its gates")
	d := f64(arrival.lo.x) * f64(arrival.lo.x) + f64(arrival.lo.z) * f64(arrival.lo.z)
	testing.expect(t, d >= f64(w.params.gate_distance * w.params.gate_distance))
	testing.expect(t, harness_stop(h))
}
