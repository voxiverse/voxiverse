package server

import "core:fmt"
import "core:math"
import "core:testing"
import "core:time"

import "../game"

// Bulk edits reach every player who has the chunks, whole, and leave them
// all with the same blocks; rockets fly and blow holes.
@(test)
test_bulk_edits_and_rockets :: proc(t: ^testing.T) {
	config := Config {
		rules           = quiet_rules(),
		seed            = 21,
		generator       = .Classic, // flat-ish M3 terrain: this tests the server, not the land
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
	ok := net_wait(
		t,
		{&a, &b},
		proc(cs: []^Net_Client) -> bool {return(
				landed(cs[0]) &&
				landed(cs[1]) &&
				len(cs[0].chunks) > 100 &&
				len(cs[1].chunks) > 100 \
			)},
	)
	if !testing.expect(t, ok, "never landed") {return}
	feet := a.update.state.position
	base_y := i32(math.floor(feet.y))
	@(static) box_lo, box_hi: game.Block_Pos
	box_lo = {4, base_y + 6, -3}
	box_hi = {11, base_y + 9, 4} // across a chunk border
	all_are :: proc(c: ^Net_Client, lo, hi: game.Block_Pos, want: game.Block) -> bool {
		for y in lo.y ..= hi.y {
			for z in lo.z ..= hi.z {
				for x in lo.x ..= hi.x {
					if got, known := net_block(c, {x, y, z}); !known || got != want {return false}
				}
			}
		}
		return true
	}

	// Fill: a stone box, seen by both.
	net_send(
		&a,
		game.Command {
			fmt.tprintf(
				"fill %d %d %d %d %d %d stone",
				box_lo.x,
				box_lo.y,
				box_lo.z,
				box_hi.x,
				box_hi.y,
				box_hi.z,
			),
		},
	)
	ok = net_wait(t, {&a, &b}, proc(cs: []^Net_Client) -> bool {
			return all_are(cs[0], box_lo, box_hi, .Stone) && all_are(cs[1], box_lo, box_hi, .Stone)
		})
	testing.expect(t, ok, "the filled box did not reach both players")
	testing.expect(t, a.bulk_begins >= 1 && b.bulk_begins >= 1, "no Bulk_Begin before the chunks")

	// A sphere of air inside it.
	@(static) center: game.Block_Pos
	center = {7, base_y + 7, 0}
	net_send(
		&a,
		game.Command{fmt.tprintf("sphere %d %d %d 1.5 air", center.x, center.y, center.z)},
	)
	ok = net_wait(t, {&a, &b}, proc(cs: []^Net_Client) -> bool {
			b0, _ := net_block(cs[0], center)
			b1, _ := net_block(cs[1], center)
			return b0 == .Air && b1 == .Air
		})
	testing.expect(t, ok, "the sphere was not carved for both")

	// Too big: refused, nothing changes.
	before := a.bulk_begins
	net_send(&a, game.Command{"fill -100 0 -100 100 60 100 dirt"})
	time.sleep(300 * time.Millisecond)
	net_pump(t, &a)
	testing.expect_value(t, a.bulk_begins, before)

	// An explosion: air inside, and the two players agree on every block
	// around it.
	@(static) blast: game.Block_Pos
	blast = {-6, base_y - 2, 6}
	Blast :: struct {
		at: game.Block_Pos,
	}
	blast_at := Blast{blast}
	call(
		&srv,
		proc(s: ^Server, data: rawptr) {explode_by(s, "a", (^Blast)(data).at, 4)},
		&blast_at,
	)
	ok = net_wait(t, {&a, &b}, proc(cs: []^Net_Client) -> bool {
		x0, _ := net_block(cs[0], blast)
		x1, _ := net_block(cs[1], blast)
		return x0 == .Air && x1 == .Air && cs[0].explosions > 0 && cs[1].explosions > 0
	})
	testing.expect(t, ok, "the explosion did not reach both")
	for _ in 0 ..< 20 {
		net_pump(t, &a)
		net_pump(t, &b)
		time.sleep(game.TICK_DURATION)
	}
	differ := 0
	for pos, &blocks in a.chunks {
		other, both := &b.chunks[pos]
		if !both {continue}
		for i in 0 ..< game.CHUNK_VOLUME {
			l := game.local_from_index(i)
			if game.chunk_get(&blocks, l) != game.chunk_get(other, l) {
				differ += 1
				break
			}
		}
	}
	testing.expectf(t, differ == 0, "%d chunks differ between the players", differ)

	// A rocket, straight down from up high: it hits the ground and blows.
	explosions := a.explosions
	net_send(&a, game.Teleport{position = a.update.state.position + {0, 20, 0}})
	time.sleep(200 * time.Millisecond)
	net_pump(t, &a)
	net_send(&a, game.Fire{a.seq, 0, -1.5})
	@(static) want: int
	want = explosions + 1
	ok = net_wait(t, {&a, &b}, proc(cs: []^Net_Client) -> bool {return cs[0].explosions >= want})
	testing.expect(t, ok, "the rocket never exploded")
}

// net_block: a block as a test client knows it.
@(private)
net_block :: proc(c: ^Net_Client, p: game.Block_Pos) -> (game.Block, bool) {
	blocks, ok := &c.chunks[game.chunk_of(p)]
	if !ok {return .Air, false}
	return game.chunk_get(blocks, game.local_of(p)), true
}

// Shapes: a sphere holds the blocks whose centres are inside it; a box its
// corners and everything between, whichever way round they are given.
@(test)
test_bulk_shapes :: proc(t: ^testing.T) {
	ball := Sphere{{0.5, 0.5, 0.5}, 1.5}
	lo, hi := shape_box(ball)
	testing.expect(t, lo == {-1, -1, -1} && hi == {2, 2, 2})
	inside := 0
	for y in lo.y ..= hi.y {
		for z in lo.z ..= hi.z {
			for x in lo.x ..= hi.x {if shape_has(ball, {x, y, z}) {inside += 1}}
		}
	}
	testing.expect_value(t, inside, 19) // the centre, 6 faces, 12 edges (not the 8 corners)
	box := Box{{3, 0, -2}, {1, 2, 0}}
	lo, hi = shape_box(box)
	testing.expect(t, lo == {1, 0, -2} && hi == {3, 2, 0})
	testing.expect(
		t,
		shape_has(box, {1, 0, -2}) && shape_has(box, {3, 2, 0}) && shape_has(box, {2, 1, -1}),
	)
	testing.expect(t, !shape_has(box, {0, 0, 0}) && !shape_has(box, {2, 3, -1}))
}
