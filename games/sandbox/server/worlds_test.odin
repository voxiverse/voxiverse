package sandbox_server

import "core:testing"

import "common:game"
import "common:worldgen"
import "games:sandbox"
import "server:playtest"

// The creatures of each world class are kinds the session has, each with a spawn rule, and
// every class with any has its own ground among their grounds, so they come there by
// themselves; a moon has none; a world of no class (the home world, its camps' folk too)
// takes every kind.
@(test)
test_world_class_creatures :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME) {return}
	defer playtest.stop(rig)
	reg := playtest.srv(rig).registry
	// The home world (no class) turns none away: its camps' folk, its sheep, every kind.
	for &kind in reg.kinds {
		testing.expectf(
			t,
			sandbox.class_has_creature(.None, kind.id),
			"%s refused at home",
			kind.id,
		)
	}
	for class in worldgen.World_Class {
		if class == .None || class == .Moon {continue}
		ground := worldgen.class_blocks(reg, class).remap[.Grass]
		comes := false
		for id in sandbox.CLASS_CREATURES[class] {
			kind, found := game.registry_kind(reg, id)
			if !testing.expectf(t, found, "%v lists %s, no kind", class, id) {continue}
			rule, has := game.kind_info(reg, kind).spawn.?
			if !testing.expectf(
				t,
				has,
				"%v lists %s, which never comes by itself",
				class,
				id,
			) {continue}
			comes ||= game.rule_matcher_has(&rule.on, ground)
			testing.expect(t, sandbox.class_has_creature(class, id))
		}
		testing.expectf(
			t,
			comes,
			"no creature of %v comes on its ground (%s)",
			class,
			game.block_id(reg, ground),
		)
	}
	testing.expect_value(t, len(sandbox.CLASS_CREATURES[.Moon]), 0)
}
