package server

import "core:fmt"
import "core:math"
import "core:testing"
import "core:time"

import "../common/game"

// M11's exit check: a dam break. A pool of water on a raised stone
// platform (rimmed, so the land below plays no part) loses a wall; the
// water floods out and settles. Run twice, it settles into the same water;
// both players over UDP end with exactly the server's blocks.
@(test)
test_dam_break :: proc(t: ^testing.T) {
	first, ok1 := dam_break(t)
	second, ok2 := dam_break(t)
	if !testing.expect(t, ok1 && ok2, "a run did not settle") {return}
	testing.expectf(
		t,
		first.hash == second.hash,
		"two runs settled differently: %x and %x",
		first.hash,
		second.hash,
	)
	testing.expectf(
		t,
		first.water > 40,
		"the water did not flood out (%d blocks of it)",
		first.water,
	)
}

@(private = "file")
Dam_Result :: struct {
	hash:  u64, // the water's region, as the server has it
	water: int, // water blocks in the region
}

@(private = "file")
dam_break :: proc(t: ^testing.T) -> (result: Dam_Result, ok: bool) {
	still := game.rules_still() // (grass spreading would make two runs differ)
	config := Config {
		seed            = 21,
		generator       = .Classic,
		rules           = still,
		view_radius     = 3,
		view_height     = 2,
		workers         = 2,
		max_players     = 4,
		listen          = true,
		everyone_cheats = true,
	}
	srv: Server
	if !testing.expect(t, start(&srv, config, {})) {return}
	defer stop(&srv)
	port := srv.host.socket.port
	a, b: Net_Client
	net_connect(&a, port, "a")
	net_connect(&b, port, "b")
	defer net_close(&a)
	defer net_close(&b)
	if !testing.expect(t, net_wait(t, {&a, &b}, proc(cs: []^Net_Client) -> bool {
			return(
				landed(cs[0]) &&
				landed(cs[1]) &&
				len(cs[0].chunks) > 100 &&
				len(cs[1].chunks) > 100 \
			)
		}), "never landed") {return}

	// A platform 14 above the ground, 20 square with a rim, and a walled
	// pool on it: water 4 x 2 x 4. A pit three deep within the water's
	// reach: water falling into a hole must settle too.
	y := i32(math.floor(a.update.state.position.y)) + 14
	commands := []string {
		fmt.tprintf("fill 4 %d -8 23 %d 11 stone", y - 3, y + 1),
		fmt.tprintf("fill 15 %d -4 17 %d -2 air", y - 2, y),
		fmt.tprintf("fill 5 %d -7 22 %d 10 air", y + 1, y + 1), // the rim stays
		fmt.tprintf("fill 6 %d -6 11 %d -1 stone", y + 1, y + 3),
		fmt.tprintf("fill 7 %d -5 10 %d -2 water", y + 1, y + 2),
	}
	for c in commands {net_send(&a, game.Command{c})}
	settle(t, &a, &b, 2 * time.Second)
	net_send(&a, game.Command{fmt.tprintf("fill 11 %d -5 11 %d -2 air", y + 1, y + 3)}) // the dam breaks
	settle(t, &a, &b, 6 * time.Second)

	// Settled: the hash no longer moves; both players have the server's.
	last: u64
	for _ in 0 ..< 10 {
		h, count := server_hash(t, &srv, &a)
		if h == last && h == client_hash(&a) && stats(&srv).updates_waiting == 0 {
			hb, _ := server_hash(t, &srv, &b)
			testing.expectf(t, hb == client_hash(&b), "b's chunks differ from the server's")
			testing.expect(t, count == len(a.chunks))
			result.hash = h
			ok = true
			break
		}
		last = h
		settle(t, &a, &b, time.Second)
	}
	for z in i32(-8) ..= 11 {
		for x in i32(4) ..= 23 {
			blk, _ := net_block(&a, {x, y + 1, z})
			if _, water := game.water_level(blk); water {result.water += 1}
		}
	}
	return
}

// settle pumps both clients for a while.
@(private = "file")
settle :: proc(t: ^testing.T, a, b: ^Net_Client, d: time.Duration) {
	end := time.tick_add(time.tick_now(), d)
	for time.tick_diff(time.tick_now(), end) > 0 {
		net_pump(t, a)
		net_pump(t, b)
		time.sleep(game.TICK_DURATION)
	}
}

// server_hash: the server's hash of the chunks c has (server.call), then c
// given a moment to take in what was on its way.
@(private = "file")
server_hash :: proc(t: ^testing.T, srv: ^Server, c: ^Net_Client) -> (sum: u64, count: int) {
	Hash :: struct {
		name:  string,
		count: int,
		sum:   u64,
	}
	h := Hash {
		name = c.name,
	}
	call(srv, proc(s: ^Server, data: rawptr) {
			h := (^Hash)(data)
			h.count, h.sum = chunks_hash_of(s, h.name)
		}, &h)
	for _ in 0 ..< 5 {
		net_pump(t, c)
		time.sleep(game.TICK_DURATION)
	}
	return h.sum, h.count
}

@(private = "file")
client_hash :: proc(c: ^Net_Client) -> (sum: u64) {
	for pos, &blocks in c.chunks {game.chunks_hash_add(&sum, pos, &blocks)}
	return
}

// 10 000 blocks of water at once: a layer of sources over an empty, rimmed
// platform, each starting a stream down onto it. The server's ticks stay
// within budget while it all flows and settles.
@(test)
test_water_flood :: proc(t: ^testing.T) {
	config := Config {
		seed            = 21,
		generator       = .Classic,
		view_radius     = 7, // the square's corners loaded too
		view_height     = 2,
		workers         = 2,
		max_players     = 2,
		listen          = true,
		everyone_cheats = true,
	}
	srv: Server
	if !testing.expect(t, start(&srv, config, {})) {return}
	defer stop(&srv)
	a: Net_Client
	net_connect(&a, srv.host.socket.port, "a")
	defer net_close(&a)
	if !testing.expect(
		t,
		net_wait(
		t,
		{&a},
		proc(cs: []^Net_Client) -> bool {
			return landed(cs[0]) && len(cs[0].chunks) >= game.interest_count(7, 2) // all of it
		},
		),
		"never landed",
	) {return}
	feet := a.update.state.position
	x0, z0 := i32(math.floor(feet.x)) - 50, i32(math.floor(feet.z)) - 50
	y := i32(math.floor(feet.y)) + 12
	commands := []string {
		fmt.tprintf("fill %d %d %d %d %d %d stone", x0 - 1, y, z0 - 1, x0 + 100, y + 1, z0 + 100),
		fmt.tprintf("fill %d %d %d %d %d %d air", x0, y + 1, z0, x0 + 99, y + 1, z0 + 99),
		fmt.tprintf("fill %d %d %d %d %d %d water", x0, y + 8, z0, x0 + 99, y + 8, z0 + 99),
	}
	for c in commands {net_send(&a, game.Command{c})}
	// The fills' own ticks are bulk edits, not flowing water: from their
	// answers on.
	if !testing.expect(
		t,
		net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return len(cs[0].notices) >= 3}),
		"the fills were not answered",
	) {return}
	time.sleep(4 * game.TICK_DURATION)
	worst: f32
	most := 0
	end := time.tick_add(time.tick_now(), 8 * time.Second)
	for time.tick_diff(time.tick_now(), end) > 0 {
		net_pump(t, &a)
		st := stats(&srv)
		worst = max(worst, st.tick_ms)
		most = max(most, st.updates_waiting)
		time.sleep(game.TICK_DURATION)
	}
	log_line := fmt.tprintf(
		"water flood: slowest tick %.1f ms, at most %d updates waiting (%v)",
		worst,
		most,
		a.notices[:],
	)
	testing.expectf(t, most >= 10000, "%s: not 10 000 flowing", log_line)
	testing.expectf(
		t,
		worst < WATER_TICK_BUDGET_MS,
		"%s: over %d ms",
		log_line,
		WATER_TICK_BUDGET_MS,
	)
}

// The slowest tick allowed while 10 000 blocks of water flow: a tick, 33
// ms, optimized (CI runs the timed tests one at a time). Unoptimized, sharing the machine with
// the other tests running at once, only a gross slowdown fails.
@(private = "file")
WATER_TICK_BUDGET_MS ::
	150 when ODIN_OPTIMIZATION_MODE == .None || ODIN_OPTIMIZATION_MODE == .Minimal else 33
