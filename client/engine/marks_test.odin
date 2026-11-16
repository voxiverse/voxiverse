package engine

import "core:testing"

import "client:render"
import "client:testkit"
import "client:ui"
import "common:access"
import "common:game"
import "server:core"

// Marks: an entity's health reaches the client with it (Entity_Record), a point in the
// world lands where the camera shows it, and outlines wait for the frame's debug lines.

@(private = "file")
Rig :: struct {
	h: core.Harness,
	s: ^Session,
}

@(private = "file")
rig_tick :: proc(data: rawptr) {
	rig := (^Rig)(data)
	input: Input_State
	actions: Actions
	session_update(rig.s, &input, &actions, {}, {}, game.TICK_SECONDS, false)
}

@(test)
test_marks_show_health_and_points :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	config := core.harness_world()
	config.listen = true
	if !testing.expect(t, core.harness_start(&rig.h, config)) {return}
	defer core.harness_stop(&rig.h)
	key: access.Account_Key
	access.account_key_set(&key, {0 ..< 32 = 7})
	rig.s = new(Session)
	defer free(rig.s)
	defer session_end(rig.s, nil, nil)
	session_start(
		rig.s,
		{
			name = "marker",
			key = key,
			join = Join{address = core.harness_address(&rig.h)},
			games = HARNESS_GAMES,
			view_radius = 2,
			view_height = 1,
			registry = testkit.test_reg(),
			net = &rig.h.net,
		},
	)
	core.harness_add(&rig.h, rig_tick, rig)
	_, joined := core.harness_step_until(&rig.h, proc(data: rawptr) -> bool {
			return (^Rig)(data).s.state == .Playing
		}, rig, 600)
	if !testing.expect(t, joined, "never joined") {return}
	s := rig.s
	w := rig.h.srv.home
	sheep := core.entity_spawn(w, rig.h.srv.registry.engine.sheep, {4.5, 0, 0.5}, false)
	id := core.entity_id(w, sheep)
	core.entity_harm(w, sheep, {amount = 1, kind = .Game})
	core.harness_step(&rig.h, 10)
	e, known := &s.entities[id]
	if !testing.expect(t, known, "the sheep never came") {return}
	testing.expect_value(t, e.health, 3)
	testing.expect_value(t, e.max_health, 4)

	// Eyes at the origin looking down -z: a point ahead is in the middle of the screen,
	// one behind is nowhere, one too far is not drawn.
	s.camera.position = {0.5, 1.6, 0.5}
	view := View {
		position = s.camera.position,
	}
	s.screen_view = {
		camera = camera_render(&view, 1280, 720, 70),
		size   = {1280, 720},
		set    = true,
	}
	ctx: ui.Context
	ctx.scale = 2
	at, ok := world_point(s, &ctx, {0.5, 1.6, -9.5})
	testing.expectf(t, ok && abs(at.x - 320) < 1 && abs(at.y - 180) < 1, "ahead at %v", at)
	_, ok = world_point(s, &ctx, {0.5, 1.6, 9.5})
	testing.expect(t, !ok, "a point behind was on the screen")
	_, ok = world_point(s, &ctx, {0.5, 1.6, -(MARK_DISTANCE + 10)})
	testing.expect(t, !ok, "a point too far was drawn")

	// An entity's marks go just over its box (a sheep's is 0.9 high).
	top, over := entity_top(s, id)
	feet, _ := entity_place(s, id)
	testing.expectf(
		t,
		over && top.xz == feet.xz && abs(top.y - feet.y - (0.9 + ENTITY_MARK_LIFT)) < 1e-6,
		"over the sheep at %v, its feet at %v",
		top,
		feet,
	)
	_, over = entity_top(s, id + 1000)
	testing.expect(t, !over, "a mark over an entity nobody knows")

	// Outlines: queued, drawn into the debug lines once, then gone.
	world_box(s, {1, 0, 1}, {2, 1, 2}, {255, 200, 0, 255})
	testing.expect_value(t, s.world_box_count, 1)
	d: render.Debug_Draw
	render.debug_draw_init(&d)
	defer render.debug_draw_destroy(&d)
	world_boxes_draw(s, &d)
	testing.expect_value(t, s.world_box_count, 0)
	testing.expect_value(t, len(d.vertices), 2 * 2 * 12) // (two boxes of 12 edges)
}
