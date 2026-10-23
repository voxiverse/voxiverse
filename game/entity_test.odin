package game

import "core:math"
import "core:testing"

@(private = "file")
Flat :: struct {
	ground: i32, // solid at and below this y
	wall_x: Maybe(i32), // a wall of blocks at this x, one block high above the ground
}

@(private = "file")
flat_query :: proc(f: ^Flat) -> Block_Query {
	return {f, proc(data: rawptr, p: Block_Pos) -> (Block, bool) {
			f := (^Flat)(data)
			if p.y <= f.ground {return .Stone, true}
			if x, ok := f.wall_x.?; ok && p.x == x && p.y == f.ground + 1 {return .Stone, true}
			return .Air, true
		}}
}

// A critter falls, lands, walks, stops at a step it does not jump, and
// gets over it when it jumps.
@(test)
test_entity_body :: proc(t: ^testing.T) {
	rules := RULES_DEFAULTS
	f := Flat {
		ground = 10,
	}
	q := flat_query(&f)
	b := Entity_Body {
		position = {0.5, 15, 0.5},
	}
	for _ in 0 ..< 60 {body_step(&b, .Critter, {}, false, &rules, q, TICK_SECONDS)}
	testing.expect(t, b.on_ground && abs(b.position.y - 11) < 1e-9, "landed on the ground")

	f.wall_x = 3
	for _ in 0 ..< 90 {body_step(&b, .Critter, {2, 0}, false, &rules, q, TICK_SECONDS)}
	half := ENTITY_INFO[.Critter].width / 2
	testing.expectf(
		t,
		abs(b.position.x - (3 - half)) < 1e-6,
		"stopped at the wall: x %v",
		b.position.x,
	)
	for i in 0 ..< 60 {body_step(&b, .Critter, {2, 0}, i == 0, &rules, q, TICK_SECONDS)}
	// Over the one-block wall and down the far side.
	testing.expectf(t, b.position.x > 4 + half, "did not get over the step: %v", b.position)
}

@(test)
test_ray_box :: proc(t: ^testing.T) {
	lo, hi := entity_box(.Critter, {5.5, 0, 0.5})
	d, hit := ray_box({0.5, 0.5, 0.5}, {1, 0, 0}, lo, hi, 10)
	testing.expectf(t, hit && abs(d - (5.5 - 0.4 - 0.5)) < 1e-9, "hit at %v", d)
	_, hit = ray_box({0.5, 0.5, 0.5}, {1, 0, 0}, lo, hi, 4)
	testing.expect(t, !hit, "out of reach")
	_, hit = ray_box({0.5, 0.5, 0.5}, {0, 0, 1}, lo, hi, 10)
	testing.expect(t, !hit, "looking past it")
	s2 := math.SQRT_TWO / 2
	_, hit = ray_box({0.5, 0.5, 0.5}, {s2, s2, 0}, lo, hi, 10)
	testing.expect(t, !hit, "over its back")
}
