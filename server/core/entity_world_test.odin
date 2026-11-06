package core

import "core:testing"

import "common:game"

@(private = "file")
test_registry :: proc() -> ^game.Registry {
	reg, _ := game.registry_build({game.base_pack_source(context.temp_allocator)})
	return reg
}

@(test)
test_spawn_tag_kill :: proc(t: ^testing.T) {
	reg := test_registry()
	if reg == nil {return}
	defer game.registry_destroy(reg)
	sheep, _ := game.registry_kind(reg, "sheep")
	rocket, _ := game.registry_kind(reg, "rocket")

	ew: Entity_World
	entity_world_init(&ew, 1, 8)
	defer entity_world_destroy(&ew)
	act := Act{}

	// errors
	_, _, err := entity_world_spawn(&ew, reg, 0, {}, act)
	testing.expect_value(t, err, Spawn_Error.Unknown_Kind)
	_, _, err = entity_world_spawn(&ew, reg, 99, {}, act)
	testing.expect_value(t, err, Spawn_Error.Unknown_Kind)

	id, h, e1 := entity_world_spawn(&ew, reg, sheep, {1, 2, 3}, act)
	testing.expect_value(t, e1, Spawn_Error.None)
	testing.expect(t, id != 0)
	game.store_apply(&ew.store)
	tf := game.store_get(&ew.store, h, game.C_TRANSFORM, game.Transform)
	testing.expect_value(t, tf.position, [3]f64{1, 2, 3})
	testing.expect_value(
		t,
		game.store_get(&ew.store, h, game.C_HEALTH, game.Entity_Health).health,
		4,
	)
	testing.expect_value(t, game.spatial_count_entries(&ew.spatial), 1)
	testing.expect_value(t, game.spatial_count(&ew.spatial, {1, 2, 3}, 2, {}), 1)

	// tags
	// the first tag adds the component, so it shows after store_apply
	testing.expect_value(t, entity_tag(&ew, h, "flock"), Tag_Error.None)
	game.store_apply(&ew.store)
	testing.expect_value(t, entity_tag(&ew, h, "flock"), Tag_Error.None)
	testing.expect(t, entity_has_tag(&ew, h, "flock"))
	testing.expect(t, !entity_has_tag(&ew, h, "herd"))
	testing.expect_value(t, entity_tag(&ew, h, "Bad Name"), Tag_Error.Bad_Name)
	testing.expect_value(t, entity_tag(&ew, h, ""), Tag_Error.Bad_Name)
	for n in ([?]string{"a", "b", "c"}) {
		testing.expect_value(t, entity_tag(&ew, h, n), Tag_Error.None)
	}
	testing.expect_value(t, entity_tag(&ew, h, "d"), Tag_Error.Tags_Full)
	entity_untag(&ew, h, "flock")
	testing.expect(t, !entity_has_tag(&ew, h, "flock"))

	// the 257th name is refused
	other, oh, _ := entity_world_spawn(&ew, reg, sheep, {}, act)
	_ = other
	game.store_apply(&ew.store)
	buf: [8]u8
	made := 0
	_ = entity_tag(&ew, oh, "x")
	game.store_apply(&ew.store)
	entity_untag(&ew, oh, "x")
	for i in 0 ..< 300 {
		buf[0] = 'n'
		buf[1] = u8('a' + i / 26 % 26)
		buf[2] = u8('a' + i % 26)
		if entity_tag(&ew, oh, string(buf[:3])) == .None {
			made += 1
			entity_untag(&ew, oh, string(buf[:3]))
		} else {
			testing.expect_value(t, len(ew.tag_names), MAX_TAG_NAMES)
			break
		}
	}
	testing.expect_value(t, made + 6, MAX_TAG_NAMES) // a, b, c, d, flock, x were interned first

	// a sheep hurt by a rocket dies with it as killer; with none 11 s later
	rid, _, _ := entity_world_spawn(&ew, reg, rocket, {}, act)
	game.store_apply(&ew.store)
	entity_world_begin_tick(&ew)
	testing.expect(t, entity_hurt(&ew, h, 4, act, rid, 7))
	testing.expect_value(t, len(ew.deaths), 1)
	testing.expect_value(t, ew.deaths[0].killer, rid)
	testing.expect_value(t, ew.deaths[0].id, id)
	testing.expect_value(t, ew.deaths[0].kind, sheep)
	testing.expect_value(t, ew.deaths[0].cause, u8(7))
	testing.expect_value(t, ew.deaths[0].position, [3]f64{1, 2, 3})
	game.store_apply(&ew.store)
	_, found := game.store_find(&ew.store, id)
	testing.expect(t, !found)
	testing.expect(t, entity_hurt(&ew, h, 1, act, 0) == false)

	entity_world_begin_tick(&ew)
	testing.expect_value(t, len(ew.deaths), 0)
	_, h2, _ := entity_world_spawn(&ew, reg, sheep, {}, act)
	game.store_apply(&ew.store)
	entity_hurt(&ew, h2, 1, act, rid)
	for _ in 0 ..< 11 * game.TICK_RATE {entity_world_begin_tick(&ew)}
	entity_kill(&ew, h2, 0, act)
	testing.expect_value(t, len(ew.deaths), 1)
	testing.expect_value(t, ew.deaths[0].killer, game.Entity_Id(0))
}

@(test)
test_spawn_full :: proc(t: ^testing.T) {
	reg := test_registry()
	if reg == nil {return}
	defer game.registry_destroy(reg)
	sheep, _ := game.registry_kind(reg, "sheep")
	ew: Entity_World
	entity_world_init(&ew, 1, 4)
	defer entity_world_destroy(&ew)
	for _ in 0 ..< 4 {
		_, _, err := entity_world_spawn(&ew, reg, sheep, {}, Act{})
		testing.expect_value(t, err, Spawn_Error.None)
	}
	_, _, err := entity_world_spawn(&ew, reg, sheep, {}, Act{})
	testing.expect_value(t, err, Spawn_Error.Full)
	game.store_apply(&ew.store)
	testing.expect_value(t, game.store_count(&ew.store), 4)
	testing.expect_value(t, game.spatial_count_entries(&ew.spatial), 4)
}

@(test)
test_world_holds_entity_world :: proc(t: ^testing.T) {
	// the world's entity world is live and counts ticks beside the fixed list
	h := new(Harness)
	defer free(h)
	if !testing.expect(t, harness_start(h, harness_world())) {return}
	defer harness_stop(h)
	w := h.srv.home
	before := w.entity_world.tick
	entities_tick(w)
	testing.expect_value(t, w.entity_world.tick, before + 1)
	testing.expect_value(t, game.store_count(&w.entity_world.store), 0)
}

@(test)
test_world_spawn_not_loaded :: proc(t: ^testing.T) {
	h := new(Harness)
	defer free(h)
	if !testing.expect(t, harness_start(h, harness_world())) {return}
	defer harness_stop(h)
	w := h.srv.home
	sheep, _ := game.registry_kind(h.srv.registry, "sheep")
	_, _, err := world_entity_spawn(w, sheep, {1e6, 64, 1e6}, Act{})
	testing.expect_value(t, err, Spawn_Error.Not_Loaded)
	testing.expect_value(t, game.store_count(&w.entity_world.store), 0)
	// a kill nobody knew of records the death and sends nothing
	id, eh, err2 := entity_world_spawn(w.entity_world, h.srv.registry, sheep, {1, 64, 1}, Act{})
	testing.expect_value(t, err2, Spawn_Error.None)
	game.store_apply(&w.entity_world.store)
	world_entity_kill(w, eh, 3, Act{})
	testing.expect_value(t, len(w.entity_world.deaths), 1)
	testing.expect_value(t, w.entity_world.deaths[0].id, id)
}

@(test)
test_tag_near :: proc(t: ^testing.T) {
	reg := test_registry()
	if reg == nil {return}
	defer game.registry_destroy(reg)
	sheep, _ := game.registry_kind(reg, "sheep")
	rocket, _ := game.registry_kind(reg, "rocket")
	ew: Entity_World
	entity_world_init(&ew, 1, 8)
	defer entity_world_destroy(&ew)
	_, near, _ := entity_world_spawn(&ew, reg, sheep, {1, 2, 3}, Act{})
	_, far, _ := entity_world_spawn(&ew, reg, sheep, {100, 2, 3}, Act{})
	_, rk, _ := entity_world_spawn(&ew, reg, rocket, {2, 2, 3}, Act{})
	game.store_apply(&ew.store)

	n, err := entity_tag_near(&ew, sheep, {0, 2, 3}, 10, true, "flock")
	testing.expect_value(t, err, Tag_Error.None)
	testing.expect_value(t, n, 1)
	game.store_apply(&ew.store)
	testing.expect(t, entity_has_tag(&ew, near, "flock"))
	testing.expect(t, !entity_has_tag(&ew, far, "flock"))
	testing.expect(t, !entity_has_tag(&ew, rk, "flock"))

	n, _ = entity_tag_near(&ew, 0, {0, 2, 3}, 10, true, "flock")
	testing.expect_value(t, n, 2)
	n, _ = entity_tag_near(&ew, 0, {0, 2, 3}, 10, false, "flock")
	testing.expect_value(t, n, 2)
	testing.expect(t, !entity_has_tag(&ew, near, "flock"))
	_, err = entity_tag_near(&ew, 0, {0, 2, 3}, 10, true, "Bad Name")
	testing.expect_value(t, err, Tag_Error.Bad_Name)
}
