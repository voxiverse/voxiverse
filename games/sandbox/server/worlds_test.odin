package sandbox_server

import "core:testing"

import "common:game"
import "common:worldgen"
import "games:sandbox"
import "server:playtest"

// The creatures of each world class are kinds the session has, each with a spawn rule, and
// every class with any has its own ground among their grounds, so they come there by
// themselves; a moon has none; a world of no class (the home world, its camps' folk too)
// takes every kind but the gate worlds' own.
@(test)
test_world_class_creatures :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME) {return}
	defer playtest.stop(rig)
	reg := playtest.srv(rig).registry
	// The home world (no class) turns none away but the gate worlds' own: its camps' folk,
	// its sheep, every other kind.
	for &kind in reg.kinds {
		_, native := sandbox.native_class(kind.id)
		testing.expectf(
			t,
			sandbox.class_has_creature(.None, kind.id) != native,
			"%s refused at home, or a native let in",
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

// Each living class but the moon has creatures of its own, one or two, each a kind of the
// roster with a spawn rule on ground its class has (or in its sea), coming there and on no
// other class nor at home; one of each of the canyon's, frozen, ocean, volcanic, fungal and
// jungle worlds' fights.
@(test)
test_world_class_natives :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	reg := s.registry
	total := 0
	for class in worldgen.World_Class {
		natives := sandbox.CLASS_NATIVES[class]
		if class == .None || class == .Moon {
			testing.expect_value(t, len(natives), 0)
			continue
		}
		testing.expectf(
			t,
			len(natives) >= 1 && len(natives) <= 2,
			"%v has %d",
			class,
			len(natives),
		)
		total += len(natives)
		cb := worldgen.class_blocks(reg, class)
		grounds := [?]game.Block {
			cb.remap[.Grass],
			cb.remap[.Dirt],
			cb.remap[.Sand],
			cb.remap[.Gravel],
			cb.remap[.Stone],
			cb.remap[.Snow],
			cb.parts[0],
			cb.parts[1],
			cb.parts[2],
		}
		fights := false
		for id in natives {
			kind, found := game.registry_kind(reg, id)
			if !testing.expectf(t, found, "%v's %s is no kind", class, id) {continue}
			which, ours := wild_of(s, kind)
			testing.expectf(t, ours && which in NATIVES, "%s is not of the natives", id)
			info := game.kind_info(reg, kind)
			testing.expectf(
				t,
				info.hittable && len(info.drops) > 0,
				"%s: never hit, or leaves nothing",
				id,
			)
			if attack, armed := info.attack.?; armed {fights ||= attack.damage > 0}
			rule, has := info.spawn.?
			if !testing.expectf(t, has, "%s never comes by itself", id) {continue}
			on_ground := false
			for b in grounds {on_ground ||= b != .Air && game.rule_matcher_has(&rule.on, b)}
			testing.expectf(t, on_ground, "%s comes on no ground %v has", id, class)
			for other in worldgen.World_Class {
				testing.expectf(
					t,
					sandbox.class_has_creature(other, id) == (other == class),
					"%s on %v",
					id,
					other,
				)
			}
		}
		if class != .Temperate {testing.expectf(t, fights, "nothing of %v's own fights", class)}
	}
	testing.expectf(t, total >= 10 && total <= 12, "%d natives", total)
}
