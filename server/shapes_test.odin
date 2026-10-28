package server

import "core:math"
import "core:testing"

import "../common/game"

// M48: stairs, slabs and ladders on a built course, walked by a mirror client
// against a stepped server: they collide, step up and climb the same on both
// sides, tick by tick, with no correction and no difference in the world.

@(private = "file")
Course_Track :: struct {
	max_y:      [32]f64, // the highest the feet were, by block column from the start
	min_y:      [32]f64, // the lowest after the first visit
	visited:    [32]bool,
	x_reached:  f64,
	ladder_top: f64, // the highest the feet got while x was within the ladder's column
}

// course: the commands that build it, relative to the player's feet block.
// x runs east (the way the script walks).
@(private = "file")
COURSE := [?]string {
	"fill ~-2 ~ ~-3 ~32 ~14 ~3 air",
	"fill ~-2 ~-1 ~-3 ~32 ~-1 ~3 stone",
	// A slab staircase: tops at 0.5, 1.0, 1.5, 2.0.
	"fill ~2 ~ ~ ~2 ~ ~ stone_slab[type=bottom]",
	"fill ~3 ~ ~ ~3 ~ ~ stone",
	"fill ~4 ~ ~ ~4 ~ ~ stone",
	"fill ~4 ~1 ~ ~4 ~1 ~ stone_slab[type=bottom]",
	"fill ~5 ~ ~ ~5 ~1 ~ stone",
	// A stair flight up, high side east: the last step's top is 5.0.
	"fill ~6 ~ ~ ~6 ~1 ~ stone",
	"fill ~6 ~2 ~ ~6 ~2 ~ stone_stairs[facing=east,half=bottom]",
	"fill ~7 ~ ~ ~7 ~2 ~ stone",
	"fill ~7 ~3 ~ ~7 ~3 ~ stone_stairs[facing=east,half=bottom]",
	"fill ~8 ~ ~ ~8 ~3 ~ stone",
	"fill ~8 ~4 ~ ~8 ~4 ~ stone_stairs[facing=east,half=bottom]",
	// A landing, then the flight down, high side west.
	"fill ~9 ~ ~ ~9 ~4 ~ stone",
	"fill ~10 ~ ~ ~10 ~3 ~ stone",
	"fill ~10 ~4 ~ ~10 ~4 ~ stone_stairs[facing=west,half=bottom]",
	"fill ~11 ~ ~ ~11 ~2 ~ stone",
	"fill ~11 ~3 ~ ~11 ~3 ~ stone_stairs[facing=west,half=bottom]",
	"fill ~12 ~ ~ ~12 ~1 ~ stone",
	"fill ~12 ~2 ~ ~12 ~2 ~ stone_stairs[facing=west,half=bottom]",
	"fill ~13 ~ ~ ~13 ~ ~ stone",
	"fill ~13 ~1 ~ ~13 ~1 ~ stone_stairs[facing=west,half=bottom]",
	"fill ~14 ~ ~ ~14 ~ ~ stone_stairs[facing=west,half=bottom]",
	// A ceiling of top slabs (underside 2.5 above the floor: a jump bumps it).
	"fill ~17 ~2 ~-1 ~20 ~2 ~1 stone_slab[type=top]",
	// A wall with a ladder up its west face.
	"fill ~24 ~ ~-1 ~26 ~6 ~1 stone",
	"fill ~23 ~ ~ ~23 ~6 ~ ladder[facing=west]",
}

@(private = "file")
stand :: proc(m: ^Mirror) -> game.Player_State {
	return m.prediction.state
}

@(test)
test_shapes_agree :: proc(t: ^testing.T) {
	sess := new(Session)
	defer free(sess)
	if !testing.expect(t, session_start(sess, {}, false, no_sheep = true)) {return}
	defer session_stop(sess)
	m := &sess.mirror
	for i in 0 ..< 900 { 	// join, and stand until the world is there
		session_step(sess, false)
		if ready(sess) {break}
		if !testing.expect(t, i < 899, "the player never landed") {return}
	}
	origin := stand(m).position
	ox := math.floor(origin.x)
	m.corrections, m.mismatches, m.updates = 0, 0, 0
	for text in COURSE {
		command(m, text)
		for _ in 0 ..< 3 {session_step(sess, false)}
	}
	for _ in 0 ..< 60 {session_step(sess, false)} 	// the chunks arrive, the player settles
	testing.expectf(t, stand(m).on_ground, "not on the ground: %v", stand(m).position)
	floor_y := stand(m).position.y
	start_x := stand(m).position.x
	// The walk: east, jumping under the ceiling.
	track: Course_Track
	for i in 0 ..< 900 {
		mirror_receive(sess)
		st := stand(m)
		in_ := game.Player_Input {
			move  = {0, 1},
			yaw   = -math.PI / 2,
			pitch = -0.7,
		}
		if st.position.x > start_x + 16 &&
		   st.position.x < start_x + 20 &&
		   i % 12 == 0 {in_.buttons += {.Jump}}
		msg := game.prediction_tick(&m.prediction, in_, &m.rules, mirror_query(m))
		msg.snapshot = m.rx.ack
		mirror_send(m, msg)
		step(&sess.srv)
		now := stand(m)
		col := int(math.floor(now.position.x - ox))
		if col >= 0 && col < len(track.max_y) {
			dy := now.position.y - floor_y
			track.max_y[col] = max(track.max_y[col], dy)
			track.visited[col] = true
		}
		track.x_reached = max(track.x_reached, now.position.x - start_x)
	}
	testing.expectf(t, track.x_reached > 25, "got no further than %v blocks", track.x_reached)
	// Where the player stood: on the slabs, the stairs, the landing, the wall's top.
	near :: proc(a, b: f64) -> bool {return abs(a - b) < 1e-4}
	testing.expectf(t, track.max_y[3] >= 0.5 - 1e-4, "slab step 1: %v", track.max_y[3])
	testing.expectf(t, track.max_y[5] >= 1.5 - 1e-4, "slab step 3: %v", track.max_y[5])
	testing.expectf(
		t,
		near(track.max_y[8], 2.0) || track.max_y[8] > 2.0,
		"slab top: %v",
		track.max_y[8],
	)
	testing.expectf(t, track.max_y[9] >= 5.0 - 1e-4, "the top stair at %v, want 5", track.max_y[9])
	testing.expectf(t, track.max_y[10] < 5.0 + 1e-4, "above the landing: %v", track.max_y[10])
	testing.expectf(
		t,
		track.max_y[26] >= 7.0 - 1e-4,
		"the ladder's top: the wall at %v, want 7",
		track.max_y[26],
	)
	testing.expect_value(t, m.corrections, 0)
	testing.expect_value(t, m.mismatches, 0)
	for f in sess.failures {testing.expect(t, false, f)}
	// The world the mirror holds is the server's.
	testing.expect(t, chunks_agree(sess), "the mirror's chunks hash otherwise than the server's")
}
