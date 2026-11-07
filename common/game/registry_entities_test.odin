package game

import "core:strings"
import "core:testing"

// The base pack's kinds carry today's numbers (the Entity_Info table, ROCKET_* and ITEM_*
// constants they replaced).
@(test)
test_entity_kinds :: proc(t: ^testing.T) {
	reg, errs0 := registry_build({base_pack_source(context.temp_allocator)})
	testing.expect_value(t, errors_text(errs0), "")
	if reg == nil {return}
	defer registry_destroy(reg)
	testing.expect_value(t, len(reg.kinds), 4)

	sheep_id, ok := registry_kind(reg, "sheep")
	testing.expect(t, ok)
	testing.expect_value(t, sheep_id, Kind_Id(1))
	testing.expect_value(t, kind_info(reg, sheep_id).id, "voxiverse:sheep")
	by_full, _ := registry_kind(reg, "voxiverse:sheep")
	testing.expect_value(t, by_full, sheep_id)
	_, missing := registry_kind(reg, "cow")
	testing.expect(t, !missing)
	testing.expect(t, kind_info(reg, 0) == nil)
	testing.expect(t, kind_info(reg, 5) == nil)

	s := kind_info(reg, sheep_id)
	testing.expect_value(t, s.box, [2]f32{0.8, 0.9})
	testing.expect_value(t, s.health, 4)
	testing.expect(t, s.saved && s.summonable && s.hittable)
	testing.expect_value(t, s.physics, Entity_Physics.Walker)
	testing.expect_value(t, s.walker, Kind_Walker_Info{1.4, 4.2, 1.2, 0})
	testing.expect_value(t, s.brain, Entity_Brain.Grazer)
	testing.expect_value(t, s.with, Entity_Parts{.Wool, .Genes, .Breeding})
	testing.expect_value(t, len(s.looks), 5)
	testing.expect_value(t, s.model, Entity_Model.Sheep)
	rule, spawns := s.spawn.?
	testing.expect(t, spawns)
	grass, _ := registry_block(reg, "grass")
	testing.expect(t, rule_matcher_has(&rule.on, grass))
	stone, _ := registry_block(reg, "stone")
	testing.expect(t, !rule_matcher_has(&rule.on, stone))
	testing.expect_value(t, rule.day, [2]f32{0.27, 0.73})
	testing.expect_value(t, rule.every, TICK_RATE * 2) // SPAWN_EVERY
	testing.expect_value(t, rule.chance, f32(0.5))
	testing.expect_value(t, rule.cap, 6)
	testing.expect_value(t, rule.within, 48)
	testing.expect_value(t, rule.distance, [2]f32{16, 40})
	testing.expect_value(t, rule.group, [2]int{1, 3})

	rocket_id, _ := registry_kind(reg, "rocket")
	r := kind_info(reg, rocket_id)
	testing.expect_value(t, r.box, [2]f32{0.3, 0.3})
	testing.expect_value(t, r.health, 1)
	testing.expect(t, !r.saved && !r.hittable && !r.summonable)
	testing.expect_value(t, r.physics, Entity_Physics.Projectile)
	testing.expect_value(t, r.projectile, Kind_Projectile_Info{32, 3, 6, 4})
	testing.expect_value(t, r.model, Entity_Model.Rocket)
	_, spawns = r.spawn.?
	testing.expect(t, !spawns)

	item_id, _ := registry_kind(reg, "item")
	it := kind_info(reg, item_id)
	testing.expect_value(t, it.box, [2]f32{0.25, 0.25})
	testing.expect_value(t, it.health, 1)
	testing.expect(t, it.saved && !it.hittable)
	testing.expect_value(t, it.physics, Entity_Physics.Item)
	testing.expect_value(t, it.item, Kind_Item_Info{0.5, 2, 1.5, 1.0, 300, 9})
	testing.expect_value(t, it.model, Entity_Model.Item)

	player_id, _ := registry_kind(reg, "player")
	p := kind_info(reg, player_id)
	testing.expect_value(t, p.box, [2]f32{0.6, 1.8})
	testing.expect_value(t, p.physics, Entity_Physics.None)
	testing.expect(t, !p.saved)
	testing.expect_value(t, p.model, Entity_Model.Player)

	// A pack adds a kind with no engine code, and the hash covers it.
	cube := `{"cube": {"box": [0.5, 0.5], "physics": "walker", "walker": {"walk_speed": 1, "run_speed": 2, "jump": 0, "step": 0.6},
		"model": {"box": [200, 40, 40]}, "fields": {"mood": {"type": "u8", "min": 0, "max": 10}}}}`
	pack := pack_of("testpack", []File{{"data/entities/cube.json", cube}})
	with, errs := build_with(pack)
	testing.expect_value(t, errors_text(errs), "")
	if with == nil {return}
	testing.expect_value(t, len(with.kinds), 5)
	cube_id, found := registry_kind(with, "testpack:cube")
	testing.expect(t, found)
	testing.expect_value(t, cube_id, Kind_Id(5))
	c := kind_info(with, cube_id)
	testing.expect_value(t, c.model, Entity_Model.Box)
	testing.expect_value(t, c.color, [3]u8{200, 40, 40})
	testing.expect_value(t, c.walker.step, f32(0.6))
	testing.expect_value(t, len(c.fields), 1)
	testing.expect_value(t, c.fields[0], Kind_Field{"mood", .U8, 0, 10})
	testing.expect(t, with.hash != reg.hash, "a kind changes the registry's hash")
}

@(test)
test_entity_kind_refusals :: proc(t: ^testing.T) {
	Case :: struct {
		name: string,
		json: string,
		want: string,
	}
	WALKER :: `"physics": "walker", "walker": {"walk_speed": 1, "run_speed": 2, "jump": 1, "step": 0}`
	cases := []Case {
		{
			"unknown physics",
			`{"k": {"box": [1, 1], "physics": "swimmer", "model": "item"}}`,
			`testpack/data/entities/k.json:1:34: physics is one of "none", "walker", "item", "projectile"; got "swimmer"`,
		},
		{
			"unknown brain",
			`{"k": {"box": [1, 1], ` + WALKER + `, "brain": "hunter", "model": "item"}}`,
			`testpack/data/entities/k.json:1:120: brain is one of "none", "grazer"; got "hunter"`,
		},
		{
			"unknown model",
			`{"k": {"box": [1, 1], "model": "cow"}}`,
			`testpack/data/entities/k.json:1:32: model is one of "sheep", "rocket", "item", "player" or {"box": [r, g, b]}; got "cow"`,
		},
		{
			"grazer without walker",
			`{"k": {"box": [1, 1], "brain": "grazer", "model": "item"}}`,
			`testpack/data/entities/k.json:1:32: brain "grazer" needs physics "walker"`,
		},
		{
			"black without genes",
			`{"k": {"box": [1, 1], "looks": ["black"], "model": "item"}}`,
			`testpack/data/entities/k.json:1:33: look "black" is computed from "genes"; add it to "with"`,
		},
		{
			"a box of 5",
			`{"k": {"box": [5, 1], "model": "item"}}`,
			`testpack/data/entities/k.json:1:15: box is [width, height], each a number 0.1..4`,
		},
		{
			"nine fields",
			`{"k": {"box": [1, 1], "model": "item", "fields": {"a": {"type": "u8", "min": 0, "max": 1}, "b": {"type": "u8", "min": 0, "max": 1}, "c": {"type": "u8", "min": 0, "max": 1}, "d": {"type": "u8", "min": 0, "max": 1}, "e": {"type": "u8", "min": 0, "max": 1}, "f": {"type": "u8", "min": 0, "max": 1}, "g": {"type": "u8", "min": 0, "max": 1}, "h": {"type": "u8", "min": 0, "max": 1}, "i": {"type": "u8", "min": 0, "max": 1}}}}`,
			`testpack/data/entities/k.json:1:50: 9 fields; the limit is 8`,
		},
		{
			"a field min over max",
			`{"k": {"box": [1, 1], "model": "item", "fields": {"a": {"type": "u8", "min": 5, "max": 1}}}}`,
			`testpack/data/entities/k.json:1:78: min 5 is above max 1; swap them`,
		},
		{
			"a u8 field over 255",
			`{"k": {"box": [1, 1], "model": "item", "fields": {"a": {"type": "u8", "min": 0, "max": 300}}}}`,
			`testpack/data/entities/k.json:1:88: a u8 field's max is at most 255`,
		},
		{
			"spawn on an unknown block",
			`{"k": {"box": [1, 1], "model": "item", "spawn": {"on": "voxiverse:granite", "day": [0, 1], "every": 60, "chance": 0.5, "cap": 6, "within": 48, "distance": [16, 40], "group": [1, 3]}}}`,
			`testpack/data/entities/k.json:1:56: "voxiverse:granite" is not a block matcher: name a block, #tag, @flag or $list that exists`,
		},
		{
			"projectile without its numbers",
			`{"k": {"box": [1, 1], "physics": "projectile", "model": "rocket"}}`,
			`testpack/data/entities/k.json:1:2: physics "projectile" needs its numbers: add "projectile": {"speed", "gravity", "life", "explode"}`,
		},
		{
			"numbers without their physics",
			`{"k": {"box": [1, 1], "walker": {"walk_speed": 1, "run_speed": 2, "jump": 1, "step": 0}, "model": "item"}}`,
			`testpack/data/entities/k.json:1:33: "walker" holds the numbers of physics "walker", but this kind's physics is "none"; set that physics or remove "walker"`,
		},
		{
			"a walker number missing",
			`{"k": {"box": [1, 1], "physics": "walker", "walker": {"walk_speed": 1}, "model": "item"}}`,
			`testpack/data/entities/k.json:1:54: walker needs "run_speed"; add it
testpack/data/entities/k.json:1:54: walker needs "jump"; add it
testpack/data/entities/k.json:1:54: walker needs "step"; add it`,
		},
		{
			"seventeen looks",
			`{"k": {"box": [1, 1], "with": ["wool"], "looks": ["shorn","shorn","shorn","shorn","shorn","shorn","shorn","shorn","shorn","shorn","shorn","shorn","shorn","shorn","shorn","shorn","shorn"], "model": "item"}}`,
			`testpack/data/entities/k.json:1:50: 17 looks; the limit is 16`,
		},
		{
			"a day outside 0..1",
			`{"k": {"box": [1, 1], "model": "item", "spawn": {"on": "voxiverse:grass", "day": [0.2, 1.5], "every": 60, "chance": 0.5, "cap": 6, "within": 48, "distance": [16, 40], "group": [1, 3]}}}`,
			`testpack/data/entities/k.json:1:82: day is [low, high], numbers 0..1, low not above high`,
		},
		{
			"no box",
			`{"k": {"model": "item"}}`,
			`testpack/data/entities/k.json:1:2: a kind needs "box": [width, height]`,
		},
		{
			"no model",
			`{"k": {"box": [1, 1]}}`,
			`testpack/data/entities/k.json:1:2: a kind needs a "model": one of "sheep", "rocket", "item", "player" or {"box": [r, g, b]}`,
		},
		{
			"a spawn number missing",
			`{"k": {"box": [1, 1], "model": "item", "spawn": {"on": "voxiverse:grass"}}}`,
			`testpack/data/entities/k.json:1:49: spawn needs "day"; add it
testpack/data/entities/k.json:1:49: spawn needs "every"; add it
testpack/data/entities/k.json:1:49: spawn needs "chance"; add it
testpack/data/entities/k.json:1:49: spawn needs "cap"; add it
testpack/data/entities/k.json:1:49: spawn needs "within"; add it
testpack/data/entities/k.json:1:49: spawn needs "distance"; add it
testpack/data/entities/k.json:1:49: spawn needs "group"; add it`,
		},
		{
			"a colour of 300",
			`{"k": {"box": [1, 1], "model": {"box": [300, 0, 0]}}}`,
			`testpack/data/entities/k.json:1:32: model is a name or {"box": [r, g, b]}, each colour a whole number 0..255`,
		},
		{
			"an unknown field",
			`{"k": {"box": [1, 1], "model": "item", "helth": 3}}`,
			`testpack/data/entities/k.json:1:40: "helth" is not a kind field; did you mean "health"?`,
		},
	}
	for c in cases {
		reg, errs := build_with(pack_of("testpack", []File{{"data/entities/k.json", c.json}}))
		testing.expectf(t, reg == nil, "%s: should be refused", c.name)
		got := errors_text(errs)
		matched := got == c.want
		if strings.has_suffix(
			c.want,
			"~",
		) {matched = strings.has_prefix(got, c.want[:len(c.want) - 1])}
		testing.expectf(t, matched, "%s:\n--- got:\n%s\n--- want:\n%s", c.name, got, c.want)
	}
}
