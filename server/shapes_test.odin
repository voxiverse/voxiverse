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
	if !session_land(t, sess) {return}
	sess.manual = true // (the test drives the mirror from here on)
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
		harness_step(&sess.h)
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

// M48b: fences that join and let go, and a door placed, opened, walked through,
// closed and bumped, on a mirror against a stepped server: no correction, the
// same chunks.

@(private = "file")
block_named :: proc(name: string) -> game.Block {
	b, ok := game.state_parse(test_reg(), name)
	if !ok {panic(name)}
	return b
}

// tick_once: one input of the mirror's, predicted and sent, then one server tick.
@(private = "file")
tick_once :: proc(sess: ^Session, in_: game.Player_Input) -> u32 {
	m := &sess.mirror
	mirror_receive(sess)
	msg := game.prediction_tick(&m.prediction, in_, &m.rules, mirror_query(m))
	msg.snapshot = m.rx.ack
	mirror_send(m, msg)
	harness_step(&sess.h)
	return msg.sequence
}

@(private = "file")
server_block :: proc(sess: ^Session, p: game.Block_Pos) -> game.Block {
	b, _ := chunks_block(&sess.h.srv.home.chunks, p)
	return b
}

@(private = "file")
text_of :: proc(b: game.Block) -> string {
	return game.state_text(test_reg(), b)
}

@(test)
test_doors_and_fences_agree :: proc(t: ^testing.T) {
	sess := new(Session)
	defer free(sess)
	if !testing.expect(t, session_start(sess, {}, false, no_sheep = true)) {return}
	defer session_stop(sess)
	m := &sess.mirror
	if !session_land(t, sess) {return}
	sess.manual = true // (the test drives the mirror from here on)
	feet := game.Block_Pos {
		i32(math.floor(m.prediction.state.position.x)),
		i32(math.floor(m.prediction.state.position.y)),
		i32(math.floor(m.prediction.state.position.z)),
	}
	m.corrections, m.mismatches, m.updates = 0, 0, 0
	for text in ([]string {
			"fill ~-2 ~ ~-4 ~12 ~6 ~4 air",
			"fill ~-2 ~-1 ~-4 ~12 ~-1 ~4 stone",
			// A fence line along z at x + 3, seven long.
			"fill ~3 ~ ~-3 ~3 ~ ~3 planks_fence",
			// A wall at x + 6 with a gap at the player's row: the door's place.
			"fill ~6 ~ ~-4 ~6 ~4 ~4 stone",
			"fill ~6 ~ ~ ~6 ~1 ~ air",
		}) {
		command(m, text)
		for _ in 0 ..< 3 {session_step(sess, false)}
	}
	for _ in 0 ..< 40 {tick_once(sess, {})}
	// The line joined end to end: the ends have one side, the rest two.
	for dz in i32(-3) ..= 3 {
		got := server_block(sess, feet + {3, 0, dz})
		north, south :=
			game.state_is(&test_reg().blocks, got, "north", "true"),
			game.state_is(&test_reg().blocks, got, "south", "true")
		testing.expectf(t, north == (dz > -3), "fence %d north: %s", dz, text_of(got))
		testing.expectf(t, south == (dz < 3), "fence %d south: %s", dz, text_of(got))
		east := game.state_is(&test_reg().blocks, got, "east", "true")
		testing.expectf(t, !east, "fence %d joined the air to its east", dz)
	}
	testing.expect(t, chunks_agree(sess), "fence line: the mirror's chunks differ")
	// Break the middle: both neighbours let go, on both sides.
	break_at := feet + {3, 0, 0}
	seq := tick_once(sess, {})
	m.edit_id += 1
	mirror_send(m, game.edit_plain(m.edit_id, seq, break_at, .Air))
	for _ in 0 ..< 20 {tick_once(sess, {})}
	tb := &test_reg().blocks
	testing.expect_value(t, server_block(sess, break_at), game.Block.Air)
	for dz in ([2]i32{-1, 1}) {
		got := server_block(sess, break_at + {0, 0, dz})
		toward := "south" if dz < 0 else "north"
		testing.expectf(
			t,
			game.state_is(tb, got, toward, "false"),
			"still joined: %s",
			text_of(got),
		)
	}
	testing.expect(t, chunks_agree(sess), "after the break: the mirror's chunks differ")
	// Steer to the middle of the row, then place a door in the gap.
	yaw := f32(-math.PI / 2) // east
	east := game.Player_Input {
		move = {0, 0},
		yaw  = yaw,
	}
	for _ in 0 ..< 200 {
		z := m.prediction.state.position.z - f64(feet.z)
		if z >= 0.55 && z <= 0.9 {break}
		tick_once(sess, {move = {1 if z < 0.55 else -1, 0}, yaw = yaw})
	}
	for _ in 0 ..< 10 {tick_once(sess, east)}
	door_type := game.block_type_of(tb, block_named("voxiverse:planks_door"))
	floor := feet + {6, -1, 0}
	ctx := game.Place_Context {
		target = floor,
		face   = .Pos_Y,
		hit    = {8, 16, 8},
		yaw    = yaw,
	}
	at, lower, ok := game.placement(test_reg(), door_type, ctx, mirror_query(m))
	if !testing.expect(t, ok, "the rule refused the door") {return}
	testing.expect_value(t, at, feet + {6, 0, 0})
	seq = tick_once(sess, east)
	m.edit_id += 1
	mirror_send(m, game.Edit{m.edit_id, seq, at, lower, ctx.target, u8(ctx.face), ctx.hit})
	for _ in 0 ..< 10 {tick_once(sess, east)}
	testing.expect_value(t, server_block(sess, at), lower)
	cell, upper, _ := game.companion(test_reg(), lower, at)
	testing.expect_value(t, server_block(sess, cell), upper)
	testing.expect(t, chunks_agree(sess), "after the door was placed: the mirror's chunks differ")
	// Closed: walking east stops short of the door.
	for _ in 0 ..< 120 {tick_once(sess, {move = {0, 1}, yaw = yaw})}
	testing.expectf(
		t,
		m.prediction.state.position.x < f64(at.x) + 0.9,
		"through a closed door: x = %v",
		m.prediction.state.position.x,
	)
	// Open it (an edit of its state) and walk through.
	seq = tick_once(sess, east)
	opened, _ := game.state_set(tb, lower, "open", "true")
	m.edit_id += 1
	mirror_send(m, game.edit_plain(m.edit_id, seq, at, opened))
	for _ in 0 ..< 10 {tick_once(sess, east)}
	testing.expect_value(t, server_block(sess, at), opened)
	_, opened_upper, _ := game.companion(test_reg(), opened, at)
	testing.expect_value(t, server_block(sess, cell), opened_upper)
	testing.expect(t, chunks_agree(sess), "after the door opened: the mirror's chunks differ")
	for _ in 0 ..< 20 {tick_once(sess, {move = {0, 1}, yaw = yaw})}
	testing.expectf(
		t,
		m.prediction.state.position.x > f64(at.x) + 1.4,
		"stopped by an open door: x = %v",
		m.prediction.state.position.x,
	)
	// Close it behind, and bump it from the far side.
	seq = tick_once(sess, east)
	m.edit_id += 1
	closed_upper, _ := game.state_set(tb, opened_upper, "open", "false")
	mirror_send(m, game.edit_plain(m.edit_id, seq, cell, closed_upper))
	for _ in 0 ..< 10 {tick_once(sess, east)}
	testing.expectf(
		t,
		server_block(sess, at) == lower,
		"closed from the upper half (player at %v, door %v): %s and %s",
		m.prediction.state.position,
		at,
		text_of(server_block(sess, at)),
		text_of(server_block(sess, cell)),
	)
	for _ in 0 ..< 120 {tick_once(sess, {move = {0, 1}, yaw = yaw + math.PI})}
	testing.expectf(
		t,
		m.prediction.state.position.x > f64(at.x) + 1.2,
		"back through a closed door: x = %v",
		m.prediction.state.position.x,
	)
	for _ in 0 ..< 20 {tick_once(sess, {})}
	testing.expect_value(t, m.corrections, 0)
	testing.expect_value(t, m.mismatches, 0)
	for f in sess.failures {testing.expect(t, false, f)}
	testing.expect(t, chunks_agree(sess), "the mirror's chunks hash otherwise than the server's")
}
