package game

import "core:math"
import "core:math/rand"
import "core:testing"

// Physics over shapes: the sweep over cubes equals what it was before shapes,
// and stairs, slabs and ladders collide as they should.

@(private = "file")
Shaped_World :: struct {
	blocks: map[Block_Pos]Block,
	floor:  i32, // y below this: stone (a floor under the test)
}

@(private = "file")
shaped_query :: proc(w: ^Shaped_World, reg: ^Registry) -> Block_Query {
	return {w, proc(data: rawptr, p: Block_Pos) -> (Block, bool) {
			w := (^Shaped_World)(data)
			if b, ok := w.blocks[p]; ok {return b, true}
			return .Stone if p.y < w.floor else .Air, true
		}, &reg.blocks}
}

// --- The frozen sweep: what it was before shapes (one layer at a time). ---

@(private = "file")
frozen_solid_at :: proc(q: Block_Query, p: Block_Pos) -> bool {
	if p.y >= WORLD_MAX_Y {return false}
	if p.y < WORLD_MIN_Y {return true}
	b, loaded := q.get(q.data, p)
	return !loaded || block_collides(q.table, b)
}

@(private = "file")
frozen_box_blocked :: proc(q: Block_Query, position: [3]f64, width, height: f64) -> bool {
	EPS :: 1e-7
	half := width / 2
	lo := [3]f64{position.x - half, position.y, position.z - half} + EPS
	hi := [3]f64{position.x + half, position.y + height, position.z + half} - EPS
	for y in i32(math.floor(lo.y)) ..= i32(math.floor(hi.y)) {
		for z in i32(math.floor(lo.z)) ..= i32(math.floor(hi.z)) {
			for x in i32(math.floor(lo.x)) ..= i32(math.floor(hi.x)) {
				if frozen_solid_at(q, {x, y, z}) {return true}
			}
		}
	}
	return false
}

@(private = "file")
frozen_sweep :: proc(
	position: [3]f64,
	width, height: f64,
	axis: int,
	delta: f64,
	q: Block_Query,
) -> (
	moved: f64,
	hit: bool,
) {
	if delta == 0 {return 0, false}
	EPS :: 1e-7
	half := width / 2
	lo, hi := position - {half, 0, half}, position + {half, height, half}
	a1, a2 := (axis + 1) % 3, (axis + 2) % 3
	from1, to1 := i32(math.floor(lo[a1] + EPS)), i32(math.floor(hi[a1] - EPS))
	from2, to2 := i32(math.floor(lo[a2] + EPS)), i32(math.floor(hi[a2] - EPS))
	layer_solid :: proc(
		q: Block_Query,
		axis, a1, a2: int,
		layer, from1, to1, from2, to2: i32,
	) -> bool {
		for i in from1 ..= to1 {
			for j in from2 ..= to2 {
				p: Block_Pos
				p[axis], p[a1], p[a2] = layer, i, j
				if frozen_solid_at(q, p) {return true}
			}
		}
		return false
	}
	if delta > 0 {
		face := hi[axis]
		first := i32(math.floor(face - EPS)) + 1
		last := i32(math.ceil(face + delta)) - 1
		for layer in first ..= last {
			if layer_solid(q, axis, a1, a2, layer, from1, to1, from2, to2) {
				return f64(layer) - face, true
			}
		}
	} else {
		face := lo[axis]
		first := i32(math.floor(face + EPS)) - 1
		last := i32(math.floor(face + delta))
		for layer := first; layer >= last; layer -= 1 {
			if layer_solid(q, axis, a1, a2, layer, from1, to1, from2, to2) {
				return f64(layer + 1) - face, true
			}
		}
	}
	return delta, false
}

@(test)
test_sweep_cubes_unchanged :: proc(t: ^testing.T) {
	reg := states_registry(t)
	if reg == nil {return}
	w: Shaped_World
	defer delete(w.blocks)
	r := rand.create(48)
	context.random_generator = rand.default_random_generator(&r)
	// A random world of cubes (and water, which does not collide) in 8x8x8.
	for x in i32(-4) ..< 4 {
		for y in i32(0) ..< 8 {
			for z in i32(-4) ..< 4 {
				switch rand.int_max(5) {
				case 0, 1:
					w.blocks[{x, y, z}] = .Stone
				case 2:
					w.blocks[{x, y, z}] = .Water
				case 3:
					w.blocks[{x, y, z}] = .Glass
				}
			}
		}
	}
	q := shaped_query(&w, reg)
	mismatches := 0
	for _ in 0 ..< 10_000 {
		pos := [3]f64 {
			rand.float64_range(-4, 4),
			rand.float64_range(-1, 9),
			rand.float64_range(-4, 4),
		}
		// Some on exact integers and tenths: touching faces.
		if rand.int_max(3) == 0 {pos.x = math.round(pos.x * 2) / 2}
		if rand.int_max(3) == 0 {pos.y = math.round(pos.y)}
		width := rand.float64_range(0.1, 1.5)
		height := rand.float64_range(0.1, 2.5)
		axis := rand.int_max(3)
		delta := rand.float64_range(-3, 3)
		m1, h1 := sweep(pos, width, height, axis, delta, q)
		m2, h2 := frozen_sweep(pos, width, height, axis, delta, q)
		if m1 != m2 || h1 != h2 {mismatches += 1}
		if box_blocked(q, pos, width, height) != frozen_box_blocked(q, pos, width, height) {
			mismatches += 1
		}
	}
	testing.expect_value(t, mismatches, 0)
}

@(private = "file")
set :: proc(w: ^Shaped_World, reg: ^Registry, p: Block_Pos, text: string) {
	b, ok := state_parse(reg, text)
	if !ok {panic(text)}
	w.blocks[p] = b
}

@(private = "file")
DT :: f32(1) / TICK_RATE

@(private = "file")
walk :: proc(s: ^Player_State, input: Player_Input, w: ^Shaped_World, reg: ^Registry, ticks: int) {
	rules := RULES_DEFAULTS
	for _ in 0 ..< ticks {player_step(s, input, &rules, shaped_query(w, reg), DT)}
}

@(test)
test_stand_on_slab_and_bump_top_slab :: proc(t: ^testing.T) {
	reg := states_registry(t)
	if reg == nil {return}
	w := Shaped_World {
		floor = 0,
	}
	defer delete(w.blocks)
	set(&w, reg, {0, 0, 0}, "testpack:planks_slab[type=bottom]")
	s := Player_State {
		position = {0.5, 5, 0.5},
	}
	walk(&s, {}, &w, reg, 60)
	testing.expectf(t, abs(s.position.y - 0.5) < 1e-9, "feet at %v, want 0.5", s.position.y)
	testing.expect(t, s.on_ground)
	// A top slab: standing under it. A jump bumps its underside at y = 1.5.
	set(&w, reg, {0, 3, 0}, "testpack:planks_slab[type=top]")
	s = {
		position = {0.5, 1, 0.5},
	}
	w.blocks[{0, 0, 0}] = .Stone
	for _ in 0 ..< 40 {
		walk(&s, {buttons = {.Jump}}, &w, reg, 1)
		testing.expectf(
			t,
			s.position.y + PLAYER_HEIGHT <= 3.5 + 1e-9,
			"head through the slab: %v",
			s.position.y,
		)
	}
}

@(test)
test_walk_up_stairs_and_slabs :: proc(t: ^testing.T) {
	reg := states_registry(t)
	if reg == nil {return}
	// A stair flight going east (+x): each step a stair facing east ("ascending
	// toward +x" is the stair whose high side is at +x: facing=east here).
	w := Shaped_World {
		floor = 0,
	}
	defer delete(w.blocks)
	for i in i32(0) ..< 4 {
		set(&w, reg, {2 + i, i, 0}, "testpack:planks_stairs[facing=east,half=bottom]")
		for k in i32(0) ..< i {w.blocks[{2 + i, k, 0}] = .Stone}
		// Keep the walker in a corridor.
		for y in i32(0) ..< 8 {
			w.blocks[{2 + i, y, -1}] = .Stone
			w.blocks[{2 + i, y, 1}] = .Stone
		}
	}
	s := Player_State {
		position = {0.5, 0, 0.5},
	}
	walk(&s, {}, &w, reg, 30)
	// Walk east without jumping: up the flight.
	input := Player_Input {
		move = {0, 1},
		yaw  = -math.PI / 2, // forward is +x
	}
	top := f64(0)
	for _ in 0 ..< 120 {
		walk(&s, input, &w, reg, 1)
		top = max(top, s.position.y)
	}
	testing.expectf(t, s.position.x > 5, "stuck at x = %v", s.position.x)
	testing.expectf(t, top >= 4, "reached y = %v, want the top of the flight (4)", top)
	// A slab staircase: bottom slab, full block, ... each half a block up.
	w2 := Shaped_World {
		floor = 0,
	}
	defer delete(w2.blocks)
	for y in i32(0) ..< 8 {
		for x in i32(0) ..< 12 {
			w2.blocks[{x, y, -1}] = .Stone
			w2.blocks[{x, y, 1}] = .Stone
		}
	}
	for i in i32(0) ..< 4 {
		set(&w2, reg, {2 + 2 * i, i, 0}, "testpack:planks_slab[type=bottom]")
		set(&w2, reg, {3 + 2 * i, i, 0}, "testpack:planks_slab[type=double]")
		for k in i32(0) ..< i {
			w2.blocks[{2 + 2 * i, k, 0}] = .Stone
			w2.blocks[{3 + 2 * i, k, 0}] = .Stone
		}
	}
	s = {
		position = {0.5, 0, 0.5},
	}
	walk(&s, {}, &w2, reg, 30)
	top = 0
	for _ in 0 ..< 200 {
		walk(&s, input, &w2, reg, 1)
		top = max(top, s.position.y)
	}
	testing.expectf(t, s.position.x > 9, "slabs: stuck at x = %v", s.position.x)
	testing.expectf(t, top >= 3.5, "slabs: reached y = %v", top)
	// A wall one block high is not stepped onto.
	w3 := Shaped_World {
		floor = 0,
	}
	defer delete(w3.blocks)
	for x in i32(3) ..< 6 {w3.blocks[{x, 0, 0}] = .Stone}
	s = {
		position = {0.5, 0, 0.5},
	}
	walk(&s, {}, &w3, reg, 30)
	walk(&s, input, &w3, reg, 120)
	testing.expectf(t, s.position.x < 3 - 0.3 + 1e-6 && s.position.y == 0, "at %v", s.position)
}

@(test)
test_ladder :: proc(t: ^testing.T) {
	reg := states_registry(t)
	if reg == nil {return}
	// A wall at z = 1 (x 0..2, y 0..20) with ladders in front of it at z = 0,
	// facing north: the board at z = 13..16 sixteenths, against the wall.
	w := Shaped_World {
		floor = 0,
	}
	defer delete(w.blocks)
	for y in i32(0) ..< 20 {
		w.blocks[{0, y, 1}] = .Stone
		set(&w, reg, {0, y, 0}, "testpack:lad[facing=north]")
	}
	// Facing north has the board at the south (z 13..16) in this test pack: it is
	// written for north.
	s := Player_State {
		position = {0.5, 0, 0.3},
	}
	walk(&s, {}, &w, reg, 10)
	y0 := s.position.y
	// Holding jump climbs at LADDER_CLIMB_SPEED.
	walk(&s, {buttons = {.Jump}}, &w, reg, 20)
	rise := s.position.y - y0
	testing.expectf(
		t,
		abs(rise - LADDER_CLIMB_SPEED * 20 * f64(DT)) < 0.2,
		"rose %v in 20 ticks",
		rise,
	)
	// Sneaking holds still.
	walk(&s, {buttons = {.Sneak}}, &w, reg, 6) // the rise dies down
	at := s.position.y
	walk(&s, {buttons = {.Sneak}}, &w, reg, 30)
	testing.expectf(
		t,
		abs(s.position.y - at) < 1e-9,
		"slid from %v to %v while sneaking",
		at,
		s.position.y,
	)
	// Letting go: falls no faster than LADDER_FALL_SPEED.
	walk(&s, {}, &w, reg, 10)
	testing.expectf(t, s.velocity.y >= -LADDER_FALL_SPEED - 1e-6, "falls at %v", s.velocity.y)
	testing.expect(t, s.position.y < at)
	// A player moving into the wall climbs without jumping.
	s = {
		position = {0.5, 0, 0.3},
	}
	walk(&s, {}, &w, reg, 5)
	z0 := s.position.y
	walk(&s, {move = {0, -1}, yaw = 0}, &w, reg, 40) // backward: into the wall (+z)
	testing.expectf(t, s.position.y > z0 + 1, "climbed to %v from %v", s.position.y, z0)
}
