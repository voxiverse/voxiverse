package server

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "../game"
import "../worldgen"

// M18's exit check over UDP: misdials are refused; a dialed gate opens,
// alice walks through its horizon to the far world's gate, and once the
// gates close she dials home from there and walks back.
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
		workers     = 2,
		save_dir    = dir,
		max_players = 2,
		listen      = true,
		generator   = .Earth,
		gate_open   = 2,
	}
	srv: Server
	if !testing.expect(t, start(&srv, config, {})) {return}
	defer stop(&srv)
	for !srv.listening {}
	port := srv.host.socket.port
	home := srv.home.address
	home_gen := worldgen.generator_make(.Earth, srv.home.seed, srv.home.params)
	here, has := worldgen.arrival_gate(&home_gen)
	if !testing.expect(t, has, "no gate at home") {return}
	// A world of this galaxy, and its gate (worked out here as anywhere).
	away := game.address_derive(77)
	away.galaxy = home.galaxy
	far_world := World {
		server  = &srv,
		address = away,
	}
	world_kind(&far_world)
	far_gen := worldgen.generator_make(.Earth, far_world.seed, far_world.params)
	there, far_has := worldgen.arrival_gate(&far_gen)
	if !testing.expect(t, far_has, "no gate at the far end") {return}

	alice: Net_Client
	net_connect(&alice, port, "alice")
	defer net_close(&alice)
	clients := []^Net_Client{&alice}
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
		net_send(c, game.Command{fmt.tprintf("tp %.1f %.1f %.1f", front.x, front.y, front.z)})
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
	if !testing.expect(t, walk_up(t, &alice, here), "alice never reached the gate") {return}

	// Misdials: another galaxy, this very world, not a gate (and a symbol
	// twice is not an address: no Dial decodes).
	misdial :: proc(t: ^testing.T, c: ^Net_Client, d: game.Dial, why: string) {
		before := len(c.notices)
		net_send(c, d)
		@(static) n: int
		n = before
		ok := net_wait(t, {c}, proc(cs: []^Net_Client) -> bool {return len(cs[0].notices) > n})
		testing.expectf(
			t,
			ok && strings.contains(c.notices[len(c.notices) - 1], why),
			"misdial: %v",
			c.notices[before:],
		)
	}
	ring := worldgen.gate_at(here, 0, 5)
	elsewhere := away
	elsewhere.galaxy = game.address_derive(5).galaxy
	misdial(t, &alice, {ring, elsewhere}, "galaxy")
	misdial(t, &alice, {ring, home}, "own world")
	misdial(t, &alice, {ring - {0, 40, 0}, away}, "not a gate")

	// Dial: the chevrons light, the horizon forms; walk in.
	@(static) gate: worldgen.Structure
	gate = here
	net_send(&alice, game.Dial{ring, away})
	ok = net_wait(t, clients, proc(cs: []^Net_Client) -> bool {
			return gate_seen(cs[0], gate, .Gate_Horizon)
		}, 10)
	if !testing.expect(t, ok, "the gate never opened") {return}
	chevrons := worldgen.gate_chevrons(here)
	for c in chevrons[:game.WORLD_LENGTH] {
		b, _ := net_block(&alice, c)
		testing.expect_value(t, b, game.Block.Gate_Chevron_Lit)
	}
	alice.move = {0, 1}
	@(static) want: game.Address
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

	// The gates close; she dials home from here and walks back.
	gate = there
	ok = net_wait(t, clients, proc(cs: []^Net_Client) -> bool {
			return len(cs[0].chunks) > 20 && gate_seen(cs[0], gate, .Air)
		}, 15)
	testing.expect(t, ok, "the far gate never closed")
	if !testing.expect(t, walk_up(t, &alice, there)) {return}
	net_send(&alice, game.Dial{worldgen.gate_at(there, 10, 5), home})
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

// gate_seen: whether c sees every cell inside g's ring as b.
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
