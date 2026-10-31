package client

import "core:math"
import "core:math/rand"
import "core:testing"

import "common:game"

// F5 and the third person camera (view_camera.odin). A made-up world: a wall
// at x = -2 (when there is one) and a scatter of blocks by a hash.

Fake_World :: struct {
	wall:    bool,
	scatter: bool,
}

fake_get :: proc(data: rawptr, p: game.Block_Pos) -> (game.Block, bool) {
	w := (^Fake_World)(data)
	if w.wall && p.x == -2 {return .Stone, true}
	if w.scatter {
		h := u32(p.x) * 73856093 ~ u32(p.y) * 19349663 ~ u32(p.z) * 83492791
		if h % 5 == 0 {return .Stone, true}
	}
	return .Air, true
}

fake_query :: proc(w: ^Fake_World) -> game.Block_Query {
	return {w, fake_get, test_blocks()}
}

@(private = "file")
solid_at :: proc(w: ^Fake_World, p: [3]f64) -> bool {
	b, _ := fake_get(w, block_at(p))
	return b != .Air
}

@(private = "file")
session_at :: proc(eyes: [3]f64, yaw, pitch: f32) -> ^Session {
	s := new(Session)
	s.reg = test_reg()
	s.camera = {
		position = eyes,
		yaw      = yaw,
		pitch    = pitch,
	}
	return s
}

@(test)
test_camera_mode_cycle :: proc(t: ^testing.T) {
	m := Camera_Mode.First
	order: [4]Camera_Mode
	for i in 0 ..< 4 {
		order[i] = m
		m = camera_mode_next(m)
	}
	testing.expect_value(t, order, [4]Camera_Mode{.First, .Third_Behind, .Third_Facing, .First})
	// Through the key: one press, one step (nothing while a menu has the keys).
	s := session_at({0.5, 0.5, 0.5}, 0, 0)
	defer free(s)
	w := Fake_World{}
	a: Actions
	a.pressed = {.Camera}
	camera_update(s, &a, SETTINGS_DEFAULTS, fake_query(&w), 0.016, false)
	testing.expect_value(t, s.camera_mode, Camera_Mode.First)
	camera_update(s, &a, SETTINGS_DEFAULTS, fake_query(&w), 0.016, true)
	testing.expect_value(t, s.camera_mode, Camera_Mode.Third_Behind)
	camera_update(s, &a, SETTINGS_DEFAULTS, fake_query(&w), 0.016, true)
	camera_update(s, &a, SETTINGS_DEFAULTS, fake_query(&w), 0.016, true)
	testing.expect_value(t, s.camera_mode, Camera_Mode.First)
}

// Behind the head: 4 blocks in the open; with a wall behind, in against it
// (0.2 block off it); in front of the head when facing you, looking back.
@(test)
test_third_person_pulls_in :: proc(t: ^testing.T) {
	yaw := f32(-math.PI / 2) // looking along +x: behind is -x
	eyes := [3]f64{0.5, 0.5, 0.5}
	open := Fake_World{}
	view, used := camera_third_person(
		fake_query(&open),
		eyes,
		yaw,
		0,
		.Third_Behind,
		THIRD_DISTANCE,
	)
	testing.expect_value(t, used, THIRD_DISTANCE)
	testing.expect(t, abs(view.position.x - (eyes.x - THIRD_DISTANCE)) < 1e-9)
	testing.expect_value(t, view.yaw, yaw)
	walled := Fake_World {
		wall = true,
	}
	view, used = camera_third_person(
		fake_query(&walled),
		eyes,
		yaw,
		0,
		.Third_Behind,
		THIRD_DISTANCE,
	)
	// The wall's face is at x = -1: 1.5 from the eyes, less the margin.
	testing.expect(t, abs(used - (1.5 - THIRD_MARGIN)) < 1e-6, "pulled in to the margin")
	testing.expect(t, !solid_at(&walled, view.position))
	// Facing: in front of the head (+x), looking back (yaw turned, pitch mirrored).
	view, used = camera_third_person(
		fake_query(&walled),
		eyes,
		yaw,
		0.3,
		.Third_Facing,
		THIRD_DISTANCE,
	)
	testing.expect_value(t, used, THIRD_DISTANCE)
	testing.expect(t, view.position.x > eyes.x)
	testing.expect(t, abs(view.pitch + 0.3) < 1e-6)
	testing.expect(t, abs(math.mod(view.yaw - yaw, math.TAU) - math.PI) < 1e-5)
}

@(test)
test_third_person_never_inside_a_block :: proc(t: ^testing.T) {
	world := Fake_World {
		wall    = true,
		scatter = true,
	}
	r := rand.create(48)
	context.random_generator = rand.default_random_generator(&r)
	tried := 0
	for tried < 200 {
		eyes := [3]f64 {
			rand.float64_range(-8, 8),
			rand.float64_range(-8, 8),
			rand.float64_range(-8, 8),
		}
		if solid_at(&world, eyes) {continue} 	// (a head is not in a block)
		tried += 1
		yaw := rand.float32_range(-math.PI, math.PI)
		pitch := rand.float32_range(-1.5, 1.5)
		for mode in ([]Camera_Mode{.Third_Behind, .Third_Facing}) {
			view, used := camera_third_person(
				fake_query(&world),
				eyes,
				yaw,
				pitch,
				mode,
				THIRD_DISTANCE,
			)
			testing.expect(t, used <= THIRD_DISTANCE && used >= 0)
			if solid_at(&world, view.position) {
				testing.expectf(
					t,
					false,
					"inside a block: eyes %v yaw %v pitch %v %v",
					eyes,
					yaw,
					pitch,
					mode,
				)
				return
			}
		}
	}
}

// Pulled in at once, and back out over THIRD_EASE_SECONDS.
@(test)
test_third_person_eases_back_out :: proc(t: ^testing.T) {
	s := session_at({0.5, 0.5, 0.5}, f32(-math.PI / 2), 0)
	defer free(s)
	s.camera_mode = .Third_Behind
	s.pull = THIRD_DISTANCE
	a: Actions
	walled := Fake_World {
		wall = true,
	}
	camera_update(s, &a, SETTINGS_DEFAULTS, fake_query(&walled), 0.016, true)
	testing.expect(t, abs(s.pull - (1.5 - THIRD_MARGIN)) < 1e-6, "in at once")
	open := Fake_World{}
	camera_update(s, &a, SETTINGS_DEFAULTS, fake_query(&open), 0.05, true)
	testing.expect(t, s.pull > 1.3 && s.pull < THIRD_DISTANCE, "easing")
	for _ in 0 ..< 4 {camera_update(s, &a, SETTINGS_DEFAULTS, fake_query(&open), 0.05, true)}
	testing.expect_value(t, s.pull, THIRD_DISTANCE)
}

// The crosshair: always in first person; in third person only while aiming
// (the launcher with the use button held).
@(test)
test_crosshair_in_third_person :: proc(t: ^testing.T) {
	s := session_at({0.5, 0.5, 0.5}, 0, 0)
	defer free(s)
	launcher := game.item_of_tool(.Launcher)
	s.inventory.slots[0] = {launcher, 1, 0}
	w := Fake_World{}
	a: Actions
	camera_update(s, &a, SETTINGS_DEFAULTS, fake_query(&w), 0.016, true)
	testing.expect(t, crosshair_shown(s))
	s.camera_mode = .Third_Behind
	camera_update(s, &a, SETTINGS_DEFAULTS, fake_query(&w), 0.016, true)
	testing.expect(t, !crosshair_shown(s), "hidden in third person")
	a.down = {.Use}
	camera_update(s, &a, SETTINGS_DEFAULTS, fake_query(&w), 0.016, true)
	testing.expect(t, crosshair_shown(s), "shown while aiming")
	s.inventory.slots[0] = {game.item_of_block(test_reg(), .Stone), 1, 0}
	camera_update(s, &a, SETTINGS_DEFAULTS, fake_query(&w), 0.016, true)
	testing.expect(t, !crosshair_shown(s), "a block does not aim")
}
