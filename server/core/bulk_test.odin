package core

import "core:fmt"
import "core:math"
import "core:os"
import "core:testing"

import "common:game"
import "common:protocol"
import "common:voxel"

// Bulk edits reach every player who has the chunks, whole, and leave them
// all with the same blocks; rockets fly and blow holes.
@(test)
test_bulk_edits_and_rockets :: proc(t: ^testing.T) {
	config := Config {
		rules           = quiet_rules(),
		seed            = 21,
		generator       = .Classic, // flat-ish terrain: this tests the server, not the land
		view_radius     = 3,
		view_height     = 2,
		max_players     = 4,
		listen          = true,
		everyone_cheats = true,
	}
	h := new(Harness)
	defer free(h)
	srv := &h.srv
	if !testing.expect(t, harness_start(h, config)) {return}
	defer harness_stop(h)
	a := new(Net_Client)
	defer free(a)
	b := new(Net_Client)
	defer free(b)
	net_connect(a, 0, "a", h = h)
	net_connect(b, 0, "b", h = h)
	defer net_close(a)
	defer net_close(b)
	ok := net_wait(
		t,
		{a, b},
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
		a,
		protocol.Command {
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
	ok = net_wait(t, {a, b}, proc(cs: []^Net_Client) -> bool {
			return all_are(cs[0], box_lo, box_hi, .Stone) && all_are(cs[1], box_lo, box_hi, .Stone)
		})
	testing.expect(t, ok, "the filled box did not reach both players")
	testing.expect(t, a.bulk_begins >= 1 && b.bulk_begins >= 1, "no Bulk_Begin before the chunks")

	// A sphere of air inside it.
	@(static) center: game.Block_Pos
	center = {7, base_y + 7, 0}
	net_send(
		a,
		protocol.Command{fmt.tprintf("sphere %d %d %d 1.5 air", center.x, center.y, center.z)},
	)
	ok = net_wait(t, {a, b}, proc(cs: []^Net_Client) -> bool {
			b0, _ := net_block(cs[0], center)
			b1, _ := net_block(cs[1], center)
			return b0 == .Air && b1 == .Air
		})
	testing.expect(t, ok, "the sphere was not carved for both")

	// Too big: refused, nothing changes.
	before := a.bulk_begins
	net_send(a, protocol.Command{"fill -100 0 -100 100 60 100 dirt"})
	net_for(t, {a}, 0.3)
	testing.expect_value(t, a.bulk_begins, before)

	// An explosion: air inside, and the two players agree on every block
	// around it.
	@(static) blast: game.Block_Pos
	blast = {-6, base_y - 2, 6}
	Blast :: struct {
		at: game.Block_Pos,
	}
	blast_at := Blast{blast}
	call(srv, proc(s: ^Server, data: rawptr) {explode_by(s, "a", (^Blast)(data).at, 4)}, &blast_at)
	ok = net_wait(t, {a, b}, proc(cs: []^Net_Client) -> bool {
		x0, _ := net_block(cs[0], blast)
		x1, _ := net_block(cs[1], blast)
		return x0 == .Air && x1 == .Air && cs[0].explosions > 0 && cs[1].explosions > 0
	})
	testing.expect(t, ok, "the explosion did not reach both")
	net_ticks(t, {a, b}, 20)
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
	net_send(a, protocol.Teleport{position = a.update.state.position + {0, 20, 0}})
	net_for(t, {a}, 0.2)
	net_send(a, protocol.Fire{a.seq, 0, -1.5})
	@(static) want: int
	want = explosions + 1
	ok = net_wait(t, {a, b}, proc(cs: []^Net_Client) -> bool {return cs[0].explosions >= want})
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

// A class of blocks read into a mask and the mask applied back are the identity on the
// world, and an apply of any shape is one bulk edit: one cause holding every change, the
// chunks sent whole rather than a message per block.
@(test)
test_world_mask_round_trip :: proc(t: ^testing.T) {
	dir := "build/tmp/world_mask"
	os.remove_all(dir)
	defer os.remove_all(dir)
	g, opened := grief_open(t, dir)
	defer grief_close(g)
	if !opened {return}
	w := grief_world(g)
	reg := grief_srv(g).registry
	region := voxel.Bounds{at(g, -20, -24, -20), at(g, 20, 16, 20)} // (across chunk borders, ground and sky)
	stone := make([]bool, reg.blocks.count, context.temp_allocator)
	stone[int(game.Block.Stone)] = true
	collides := make([]bool, reg.blocks.count, context.temp_allocator)
	for b in 0 ..< reg.blocks.count {collides[b] = game.block_collides(&reg.blocks, game.Block(b))}

	// Read: a cell is in the mask exactly when its block is in the class.
	m := voxel.mask_make(region, context.temp_allocator)
	before := make([]game.Block, voxel.bounds_volume(region), context.temp_allocator)
	testing.expect(t, world_mask(w, &m, collides), "the region is not all loaded")
	i := 0
	for y in region.lo.y ..< region.hi.y {
		for z in region.lo.z ..< region.hi.z {
			for x in region.lo.x ..< region.hi.x {
				before[i] = block_at_pos(w, {x, y, z})
				if voxel.mask_get(m, {x, y, z}) != collides[int(before[i])] {
					testing.expectf(
						t,
						false,
						"%v read as %v",
						before[i],
						!collides[int(before[i])],
					)
					return
				}
				i += 1
			}
		}
	}

	// The stone taken away and put back: the world as it was.
	world_mask(w, &m, stone)
	stones := voxel.mask_count(m)
	if !testing.expect(t, stones > 1000, "too little stone to test with") {return}
	act := test_act(w)
	head := w.journal.head
	changes_flush(w)
	changed, result, _ := bulk_edit(w, {shape = m, op = .Set, block = .Air}, act)
	testing.expect_value(t, result, Bulk_Result.Done)
	testing.expect_value(t, changed, stones)
	testing.expect_value(t, int(w.journal.head - head), stones)
	for k in head ..< w.journal.head {
		e := ring_at(&w.journal, k)
		if e.action != u32(act.action) || e.how != act.how || e.new != .Air {
			testing.expectf(t, false, "entry %v is not the apply's", e^)
			break
		}
	}
	testing.expect_value(t, len(w.changes.blocks), 0) // (no block on its own: the chunks go whole)
	testing.expect(t, len(w.changes.chunks) > 0)
	bulk_edit(w, {shape = m, op = .Set, block = .Stone}, act)
	i = 0
	for y in region.lo.y ..< region.hi.y {
		for z in region.lo.z ..< region.hi.z {
			for x in region.lo.x ..< region.hi.x {
				if got := block_at_pos(w, {x, y, z}); got != before[i] {
					testing.expectf(
						t,
						false,
						"%v at %v after the round trip, was %v",
						got,
						[3]i32{x, y, z},
						before[i],
					)
					return
				}
				i += 1
			}
		}
	}
}
