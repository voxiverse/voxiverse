package game

import "core:math"
import "core:testing"

import "../base"

// A test world: listed blocks are stone, the rest air; everything is
// loaded unless unloaded_below is set (then y < it is "not loaded").
@(private = "file")
Test_World :: struct {
	solid:          map[Block_Pos]bool,
	water:          map[Block_Pos]bool,
	unloaded_below: Maybe(i32),
}

@(private = "file")
query :: proc(w: ^Test_World) -> Block_Query {
	return {w, proc(data: rawptr, p: Block_Pos) -> (Block, bool) {
			w := (^Test_World)(data)
			if limit, ok := w.unloaded_below.?; ok && p.y < limit {return .Air, false}
			if p in w.water {return .Water, true}
			return .Stone if p in w.solid else .Air, true
		}}
}

@(private = "file")
floor :: proc(w: ^Test_World, y: i32, size: i32 = 8) {
	for x in -size ..= size {
		for z in -size ..= size {w.solid[{x, y, z}] = true}
	}
}

@(private = "file")
DT :: f32(1) / TICK_RATE

@(private = "file")
run :: proc(
	s: ^Player_State,
	input: Player_Input,
	w: ^Test_World,
	ticks: int,
	rules := RULES_DEFAULTS,
) {
	rules := rules
	for _ in 0 ..< ticks {player_step(s, input, &rules, query(w), DT)}
}

@(test)
test_falls_and_lands :: proc(t: ^testing.T) {
	w: Test_World
	defer delete(w.solid)
	floor(&w, 0)
	s := Player_State {
		position = {0.5, 10, 0.5},
	}
	run(&s, {}, &w, 60)
	testing.expectf(
		t,
		abs(s.position.y - 1) < 1e-6,
		"feet at %v, want 1 (top of the floor)",
		s.position.y,
	)
	testing.expect(t, s.on_ground && s.velocity.y == 0)
	// Standing still stays put and grounded.
	run(&s, {}, &w, 30)
	testing.expect(t, abs(s.position.y - 1) < 1e-6 && s.on_ground)
}

@(test)
test_no_tunnelling :: proc(t: ^testing.T) {
	// From very high at terminal speed (~2.6 blocks per tick) onto a floor
	// one block thick: it still lands on top.
	w: Test_World
	defer delete(w.solid)
	floor(&w, -100, 2)
	s := Player_State {
		position = {0.5, 200, 0.5},
	}
	run(&s, {}, &w, 400)
	testing.expectf(t, abs(s.position.y - (-99)) < 1e-6, "feet at %v, want -99", s.position.y)
	// Sideways into a one-block wall at sprinting-flight speed.
	w2: Test_World
	defer delete(w2.solid)
	floor(&w2, 0, 40)
	for y in i32(1) ..= 3 {
		for z in i32(-3) ..= 3 {w2.solid[{20, y, z}] = true}
	}
	p := Player_State {
		position = {0.5, 1, 0.5},
	}
	rules := RULES_DEFAULTS
	rules.walk_speed = 200 // ~6.7 blocks per tick
	run(&p, {move = {0, 1}, yaw = -math.PI / 2}, &w2, 60, rules) // facing +x
	testing.expectf(
		t,
		abs(p.position.x - (20 - PLAYER_WIDTH / 2)) < 1e-6,
		"stopped at x %v",
		p.position.x,
	)
}

@(test)
test_walls_and_corners :: proc(t: ^testing.T) {
	w: Test_World
	defer delete(w.solid)
	floor(&w, 0)
	for y in i32(1) ..= 2 {
		for i in i32(-8) ..= 8 {
			w.solid[{3, y, i}] = true // wall at x = 3
			w.solid[{i, y, -3}] = true // wall at z = -3
		}
	}
	s := Player_State {
		position = {0.5, 1, 0.5},
	}
	// Diagonally into the corner (+x, -z): stops against both walls.
	run(&s, {move = {1, 1}, yaw = 0}, &w, 90) // yaw 0: forward is -z, right is +x
	testing.expectf(
		t,
		abs(s.position.x - (3 - 0.3)) < 1e-6 && abs(s.position.z - (-2 + 0.3)) < 1e-6,
		"at %v",
		s.position,
	)
	testing.expect(t, s.on_ground)
}

@(test)
test_jump_height_and_ceiling :: proc(t: ^testing.T) {
	w: Test_World
	defer delete(w.solid)
	floor(&w, 0)
	s := Player_State {
		position = {0.5, 1, 0.5},
	}
	run(&s, {}, &w, 2) // settle
	peak := s.position.y
	defaults := RULES_DEFAULTS
	player_step(&s, {buttons = {.Jump}}, &defaults, query(&w), DT)
	for _ in 0 ..< 30 {
		player_step(&s, {}, &defaults, query(&w), DT)
		peak = max(peak, s.position.y)
	}
	rise := peak - 1
	testing.expectf(t, rise > 1.22 && rise <= 1.25 + 1e-4, "jumped %v blocks, want 1.25", rise)

	// A ceiling two blocks above the floor: the head stops at it.
	w.solid[{0, 3, 0}] = true
	c := Player_State {
		position  = {0.5, 1, 0.5},
		on_ground = true,
	}
	rules := RULES_DEFAULTS
	rules.jump_height = 5
	player_step(&c, {buttons = {.Jump}}, &rules, query(&w), DT)
	for _ in 0 ..< 10 {player_step(&c, {}, &rules, query(&w), DT)}
	testing.expect(t, c.position.y + PLAYER_HEIGHT <= 3 + 1e-6, "head went into the ceiling")
}

@(test)
test_unloaded_is_solid :: proc(t: ^testing.T) {
	w := Test_World {
		unloaded_below = 5,
	}
	defer delete(w.solid)
	s := Player_State {
		position = {0.5, 20, 0.5},
	}
	run(&s, {}, &w, 90)
	testing.expectf(t, abs(s.position.y - 5) < 1e-6, "fell into unloaded chunks: %v", s.position.y)
}

@(test)
test_flying :: proc(t: ^testing.T) {
	w: Test_World
	defer delete(w.solid)
	floor(&w, 0)
	s := Player_State {
		position = {0.5, 10, 0.5},
	}
	run(&s, {buttons = {.Toggle_Fly}}, &w, 1)
	testing.expect(t, s.flying)
	start := s.position.y
	run(&s, {}, &w, 30)
	testing.expectf(t, abs(s.position.y - start) < 0.5, "flying but fell to %v", s.position.y)
	run(&s, {buttons = {.Jump}}, &w, 30) // up
	testing.expect(t, s.position.y > start + 3)
	run(&s, {buttons = {.Sneak}}, &w, 120) // down to the ground: landing ends flight
	testing.expect(t, !s.flying && s.on_ground)
	// Not allowed: no flight.
	rules := RULES_DEFAULTS
	rules.allow_flying = false
	run(&s, {buttons = {.Toggle_Fly}}, &w, 1, rules)
	testing.expect(t, !s.flying)
}

@(test)
test_rules_table :: proc(t: ^testing.T) {
	testing.expect(t, base.var_table_check(rules_table()))
}

// A pool: water from y -6 to 0 (its surface at 1) over a stone floor at
// -7, x and z -6..6; stone around it up to y 1 (a ledge one above the
// water) from x 7 on.
@(private = "file")
pool :: proc(w: ^Test_World) {
	floor(w, -7, 12)
	for y in i32(-6) ..= 0 {
		for z in i32(-6) ..= 6 {
			for x in i32(-6) ..= 6 {w.water[{x, y, z}] = true}
		}
	}
	for y in i32(-6) ..= 1 {
		for z in i32(-12) ..= 12 {
			for x in i32(7) ..= 12 {w.solid[{x, y, z}] = true}
		}
	}
}

@(test)
test_swimming :: proc(t: ^testing.T) {
	w: Test_World
	defer delete(w.solid)
	defer delete(w.water)
	pool(&w)

	// Sinks slowly: far less than a fall.
	s := Player_State {
		position = {0.5, -2, 0.5},
	}
	run(&s, {}, &w, TICK_RATE, RULES_DEFAULTS)
	testing.expectf(
		t,
		s.position.y > -3.5 && s.position.y < -2.5,
		"sank to %v in a second",
		s.position.y,
	)
	testing.expectf(t, abs(s.velocity.y + SWIM_SINK) < 0.1, "sinking at %v", s.velocity.y)

	// Jump swims up, and it floats at the surface (feet in the water).
	run(&s, {buttons = {.Jump}}, &w, 3 * TICK_RATE, RULES_DEFAULTS)
	testing.expectf(t, s.position.y > -0.5 && s.position.y < 1.0, "swam up to %v", s.position.y)

	// Across: slower than walking.
	start := s.position
	run(&s, {move = {0, 1}, yaw = math.PI / 2, buttons = {.Jump}}, &w, TICK_RATE, RULES_DEFAULTS) // west
	across := start.x - s.position.x
	testing.expectf(
		t,
		across > 1.2 && across < SWIM_SPEED * 1.05,
		"swam %v blocks in a second",
		across,
	)

	// Out onto the ledge at x 7 (its top at y 2): forward and jump.
	s = {
		position = {4.5, 0, 0.5},
	}
	for tick := 0; tick < 3 * TICK_RATE && s.position.x < 7.5; tick += 1 {
		run(&s, {move = {0, 1}, yaw = -math.PI / 2, buttons = {.Jump}}, &w, 1, RULES_DEFAULTS) // east
	}
	run(&s, {}, &w, TICK_RATE, RULES_DEFAULTS) // and stand
	testing.expectf(
		t,
		s.position.x > 7 && abs(s.position.y - 2) < 1e-6 && s.on_ground,
		"did not climb out: at %v",
		s.position,
	)
}
