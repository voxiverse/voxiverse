package synth

import "core:testing"

// The base pack's recipes against the targets of their classes: what `build sfx`
// reports, as a test.

@(private = "file")
RECIPES :: [?]struct {
	file: string,
	text: string,
} {
	{"dirt.recipe", #load("../../../assets/sounds/dirt.recipe", string)},
	{"effects.recipe", #load("../../../assets/sounds/effects.recipe", string)},
	{"glass.recipe", #load("../../../assets/sounds/glass.recipe", string)},
	{"grass.recipe", #load("../../../assets/sounds/grass.recipe", string)},
	{"gravel.recipe", #load("../../../assets/sounds/gravel.recipe", string)},
	{"leaves.recipe", #load("../../../assets/sounds/leaves.recipe", string)},
	{"sand.recipe", #load("../../../assets/sounds/sand.recipe", string)},
	{"sheep.recipe", #load("../../../assets/sounds/sheep.recipe", string)},
	{"snow.recipe", #load("../../../assets/sounds/snow.recipe", string)},
	{"stone.recipe", #load("../../../assets/sounds/stone.recipe", string)},
	{"wood.recipe", #load("../../../assets/sounds/wood.recipe", string)},
	{"wool.recipe", #load("../../../assets/sounds/wool.recipe", string)},
}

@(private = "file")
TARGETS :: #load("../../../assets/sounds/targets.txt", string)

@(test)
test_base_recipes_meet_their_targets :: proc(t: ^testing.T) {
	targets, err := parse_targets(TARGETS, "targets.txt")
	defer targets_destroy(&targets)
	testing.expectf(t, err == "", "%s", err)
	if err != "" {return}
	seen: [Class]bool
	for r in RECIPES {
		set, ok := parse(r.text, r.file)
		defer recipes_destroy(&set)
		if !testing.expectf(t, ok, "%s", error_string(set.error)) {continue}
		for &s in set.sounds {
			seen[s.class] = true
			testing.expectf(t, s.variants == 8, "%s: %d variants, want 8", s.name, s.variants)
			for v in 0 ..< s.variants {
				x := generate(&s, v)
				defer delete(x)
				m := measure(x)
				for bad in check_targets(&targets, &s, m) {
					testing.expectf(t, false, "%s.%d: %s", s.name, v, bad)
				}
			}
		}
	}
	for c in Class {
		testing.expectf(t, seen[c], "no recipe of class %v", c)
	}
}
