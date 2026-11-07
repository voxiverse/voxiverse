package core

import "core:os"
import "core:testing"

import "common:game"

// A kind is the components its pack data gives it, not its name: a sheep that never
// grazes (a walker with the sheep's parts and no brain) falls and rests by the walkers'
// physics, and is never moved by a brain, with no code naming it.
@(test)
test_kind_behaves_by_its_components :: proc(t: ^testing.T) {
	dir := "build/test_entity_systems"
	os.remove_all(dir)
	defer os.remove_all(dir)
	cfg := grief_config(dir)
	cfg.extra_packs = make([]game.Pack_Source, 1, context.temp_allocator)
	cfg.extra_packs[0] = game.sim_test_pack(
		[]game.Pack_File {
			{
				"data/entities/stoic.json",
				transmute([]u8)string(
					`{"stoic": {"box": [0.8, 0.9], "health": 4, "hittable": true,
					"physics": "walker",
					"walker": {"walk_speed": 1.4, "run_speed": 4.2, "jump": 1.2, "step": 0},
					"with": ["wool", "genes", "breeding"], "model": {"box": [255, 255, 255]}}}`,
				),
			},
		},
	)
	g, opened := grief_open(t, dir, cfg)
	defer grief_close(g)
	if !opened {return}
	w := grief_world(g)
	reg := grief_srv(g).registry
	stoic, found := game.registry_kind(reg, "sim_test:stoic")
	if !testing.expect(t, found) {return}
	sheep := reg.engine.sheep
	here := game.kind_info(reg, stoic)
	testing.expect_value(t, here.brain, game.Entity_Brain.None)
	testing.expect_value(t, game.kind_info(reg, sheep).brain, game.Entity_Brain.Grazer)

	at := [3]f64{f64(g.f.x) + 3.5, f64(g.f.y) + 6, f64(g.f.z) + 3.5}
	a := entity_spawn(w, stoic, at, false)
	b := entity_spawn(w, sheep, at + {2, 0, 0}, false)
	if !testing.expect(t, a != 0 && b != 0) {return}
	testing.expect(t, game.store_get(&w.entity_world.store, a, C_BRAIN, Brain) == nil)
	testing.expect(t, game.store_get(&w.entity_world.store, b, C_BRAIN, Brain) != nil)
	for _ in 0 ..< 200 {entities_tick(w)}
	now := entity_pos(w, a)
	testing.expect(t, now.y < at.y, "the walker fell")
	testing.expect_value(t, now.x, at.x) // no brain: it never walks
	testing.expect_value(t, now.z, at.z)
	testing.expect(t, entity_on_ground(w, a))
}
