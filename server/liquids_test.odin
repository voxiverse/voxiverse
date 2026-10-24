package server

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"

import "../game"

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
	config := Config {
		seed            = 21,
		generator       = .Classic,
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
	// pool on it: water 4 x 2 x 4.
	y := i32(math.floor(a.update.state.position.y)) + 14
	commands := []string {
		fmt.tprintf("fill 4 %d -8 23 %d 11 stone", y, y + 1),
		fmt.tprintf("fill 5 %d -7 22 %d 10 air", y + 1, y + 1), // the rim stays
		fmt.tprintf("fill 6 %d -6 11 %d -1 stone", y + 1, y + 3),
		fmt.tprintf("fill 7 %d -5 10 %d -2 water", y + 1, y + 2),
	}
	for c in commands {net_send(&a, game.Admin{c})}
	settle(t, &a, &b, 2 * time.Second)
	net_send(&a, game.Admin{fmt.tprintf("fill 11 %d -5 11 %d -2 air", y + 1, y + 3)}) // the dam breaks
	settle(t, &a, &b, 6 * time.Second)

	// Settled: the hash no longer moves; both players have the server's.
	last: u64
	for _ in 0 ..< 10 {
		h, count := server_hash(t, &a)
		if h == last && h == client_hash(&a) {
			hb, _ := server_hash(t, &b)
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

// server_hash: the server's hash of the chunks c has (admin "hash").
@(private = "file")
server_hash :: proc(t: ^testing.T, c: ^Net_Client) -> (sum: u64, count: int) {
	for n in c.notices {delete(n)}
	clear(&c.notices)
	net_send(c, game.Admin{"hash"})
	for _ in 0 ..< 100 {
		net_pump(t, c)
		for n in c.notices {
			if !strings.has_prefix(n, "hash ") {continue}
			f := strings.fields(n, context.temp_allocator)
			count, _ = strconv.parse_int(f[1])
			sum, _ = strconv.parse_u64_of_base(f[2], 16)
			return
		}
		time.sleep(game.TICK_DURATION)
	}
	return
}

@(private = "file")
client_hash :: proc(c: ^Net_Client) -> (sum: u64) {
	for pos, &blocks in c.chunks {game.chunks_hash_add(&sum, pos, &blocks)}
	return
}
