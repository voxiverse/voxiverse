package client

import "core:math"
import "core:net"
import "core:testing"
import "core:time"

import "../common/game"
import "../server"

// Those who stand still stay in sight. Snapshots carry only what changed, so
// a player or a sheep that does not move sends nothing; it must not go
// invisible after STALE_SECONDS, and when it moves again it must not glide
// in from where it was last heard of. Two sessions on a stepped server: the
// ticks are the test's, no waiting in real time for them.

STILL_TICKS :: 4 * 2 * game.TICK_RATE // well past what the old two-second rule allowed

@(private = "file")
Pair :: struct {
	srv:          server.Server,
	mover, watch: ^Session,
}

@(private = "file")
tick_all :: proc(p: ^Pair) {
	server.step(&p.srv)
	input: Input_State
	actions: Actions
	for s in ([2]^Session{p.mover, p.watch}) {
		session_update(s, &input, &actions, {}, {}, game.TICK_SECONDS, false)
	}
	time.sleep(time.Millisecond) // (the loopback packets of this tick)
}

// seen: the watcher shows the thing at the time it renders at (its clock
// runs on the frames' dt, which the test gives, not the wall clock).
@(private = "file")
seen :: proc(s: ^Session, t: ^Track) -> (v: Other_View, ok: bool) {
	now, live := session_others_now(s)
	if !live {return}
	return track_view(t, now)
}

@(private = "file")
pair_start :: proc(t: ^testing.T, p: ^Pair) -> bool {
	config := server.Config {
		seed            = 33,
		view_radius     = 3,
		view_height     = 2,
		max_players     = 4,
		listen          = true,
		stepped         = true,
		allow_cheats    = true,
		everyone_cheats = true,
		no_sheep        = true,
		rules           = still_rules(),
	}
	if !testing.expect(t, server.start(&p.srv, config, {})) {return false}
	address := net.Endpoint{net.IP4_Loopback, p.srv.host.socket.port}
	open :: proc(name: string, seed: byte, address: net.Endpoint) -> ^Session {
		s := new(Session)
		key: game.Account_Key
		game.account_key_set(&key, {0 ..< 32 = seed})
		session_start(
			s,
			{
				name = name,
				key = key,
				join = Join{address = address},
				view_radius = 3,
				view_height = 2,
			},
		)
		return s
	}
	p.mover, p.watch = open("mover", 1, address), open("watcher", 2, address)
	for _ in 0 ..< 3000 {
		tick_all(p)
		if p.mover.state == .Playing &&
		   p.watch.state == .Playing &&
		   len(p.watch.others) == 1 {return true}
	}
	testing.expect(t, false, "the two players never met")
	return false
}

@(private = "file")
pair_stop :: proc(p: ^Pair) {
	session_end(p.mover, nil, nil)
	session_end(p.watch, nil, nil)
	free(p.mover)
	free(p.watch)
	server.stop(&p.srv)
}

@(test)
test_still_player_stays_visible :: proc(t: ^testing.T) {
	p: Pair
	defer pair_stop(&p)
	if !pair_start(t, &p) {return}
	// The mover stands: nothing of it is sent for longer than the old limit.
	for tick in 0 ..< STILL_TICKS {
		tick_all(&p)
		for _, &o in p.watch.others {
			_, ok := seen(p.watch, &o.track)
			if !testing.expectf(
				t,
				ok,
				"the standing player vanished after %d ticks",
				tick,
			) {return}
		}
	}
	// Moving again after standing must not glide in from where it stood:
	// a jump (a teleport) is a jump on the watcher's screen, not a slide
	// over everything it stood through.
	at := p.mover.prediction.state.position + {10, 2, 0}
	session_teleport(p.mover, {at, 0, 0})
	for _ in 0 ..< 20 {tick_all(&p)}
	for _, &o in p.watch.others {
		v, ok := seen(p.watch, &o.track)
		d := v.position - at
		testing.expectf(
			t,
			ok && math.sqrt(d.x * d.x + d.z * d.z) < 1.5,
			"glided: %v from %v",
			v.position,
			at,
		)
	}
	// Then it walks off: smooth (the render clock moves a tick per tick, so a
	// step is the mover's own: the server applies inputs that came bunched in
	// one tick, up to four ticks' walking, 0.58 blocks; never a jump).
	for _, &o in p.watch.others {
		before, _ := seen(p.watch, &o.track)
		p.mover.autopilot = game.Player_Input {
			move = {0, 1},
			yaw  = 0,
		}
		last := before.position
		moved := 0.0
		clock := p.watch.render_clock.time
		for tick in 0 ..< 60 {
			tick_all(&p)
			// The render clock itself never jumps, however late a packet is.
			now := p.watch.render_clock.time
			testing.expectf(
				t,
				now - clock > 0.85 && now - clock < 1.15,
				"the render clock stepped %v ticks at tick %d",
				now - clock,
				tick,
			)
			clock = now
			v, ok := seen(p.watch, &o.track)
			if !testing.expect(t, ok) {return}
			d := v.position - last
			step := math.sqrt(d.x * d.x + d.z * d.z)
			testing.expectf(t, step < 0.6, "jerked %v blocks at tick %d walking off", step, tick)
			last, moved = v.position, moved + step
		}
		testing.expectf(t, moved > 2, "never walked off: %v", moved)
		// And it is where it walks, a little behind (not still gliding in
		// from where it stood).
		d := last - p.mover.prediction.state.position
		testing.expectf(t, math.sqrt(d.x * d.x + d.z * d.z) < 3, "shown %v behind", d)
	}
}

@(test)
test_still_sheep_stays_visible :: proc(t: ^testing.T) {
	p: Pair
	defer pair_stop(&p)
	if !pair_start(t, &p) {return}
	send_message(p.mover, game.Command{"summon sheep"})
	for _ in 0 ..< 600 {
		tick_all(&p)
		if len(p.watch.entities) == 1 {break}
	}
	if !testing.expect_value(t, len(p.watch.entities), 1) {return}
	// Sheep wander and rest; through all of it, it is there.
	for tick in 0 ..< 2 * STILL_TICKS {
		tick_all(&p)
		for _, &e in p.watch.entities {
			v, ok := seen(p.watch, &e.track)
			if !testing.expectf(t, ok, "the sheep vanished at tick %d", tick) {return}
			testing.expect(t, v.position.y > 0)
		}
	}
}
