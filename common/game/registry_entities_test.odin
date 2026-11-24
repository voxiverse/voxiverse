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
	// (the engine's four, then the hostile creatures and their spit: hostile.json)
	testing.expect_value(t, len(reg.kinds), 10)

	dummy_id, ok := registry_kind(reg, "dummy")
	testing.expect(t, ok)
	testing.expect_value(t, dummy_id, Kind_Id(3))
	testing.expect_value(t, kind_info(reg, dummy_id).id, "voxiverse:dummy")
	by_full, _ := registry_kind(reg, "voxiverse:dummy")
	testing.expect_value(t, by_full, dummy_id)
	testing.expect_value(t, reg.engine.dummy, dummy_id)
	_, missing := registry_kind(reg, "cow")
	testing.expect(t, !missing, "the base pack has a cow")
	testing.expect(t, kind_info(reg, 0) == nil)
	testing.expect(t, kind_info(reg, 11) == nil)

	d := kind_info(reg, dummy_id)
	testing.expect_value(t, d.box, [2]f32{0.8, 0.9})
	testing.expect_value(t, d.health, 4)
	testing.expect(t, d.saved && d.summonable && d.hittable)
	testing.expect_value(t, d.physics, Entity_Physics.Walker)
	testing.expect_value(t, d.walker, Kind_Walker_Info{1.4, 4.2, 1.2, 0})
	testing.expect_value(t, d.brain, Entity_Brain.Steered)
	testing.expect_value(t, d.voice, Entity_Voice.Bleat) // (a kind that names none)
	testing.expect_value(t, d.model, Entity_Model.Box)
	_, dummy_spawns := d.spawn.?
	testing.expect(t, !dummy_spawns)

	// A spawn rule, as data.
	wild := pack_of(
		"testpack",
		[]File {
			{
				"data/entities/wild.json",
				`{"wild": {"box": [1, 1], "physics": "walker", "walker": {"walk_speed": 1, "run_speed": 2, "jump": 1, "step": 0}, "brain": "game", "voice": "growl", "model": {"box": [1, 2, 3]},
				"spawn": {"on": "voxiverse:grass", "day": [0.27, 0.73], "every": 60, "chance": 0.5, "cap": 6, "within": 48, "distance": [16, 40], "group": [1, 3], "sky": true}}}`,
			},
		},
	)
	with_wild, errs_wild := build_with(wild)
	testing.expect_value(t, errors_text(errs_wild), "")
	if with_wild == nil {return}
	defer registry_destroy(with_wild)
	wild_id, _ := registry_kind(with_wild, "testpack:wild")
	rule, spawns := kind_info(with_wild, wild_id).spawn.?
	testing.expect_value(t, kind_info(with_wild, wild_id).voice, Entity_Voice.Growl)
	testing.expect(t, spawns)
	grass, _ := registry_block(with_wild, "grass")
	testing.expect(t, rule_matcher_has(&rule.on, grass))
	stone, _ := registry_block(with_wild, "stone")
	testing.expect(t, !rule_matcher_has(&rule.on, stone))
	testing.expect_value(t, rule.day, [2]f32{0.27, 0.73})
	testing.expect_value(t, rule.every, TICK_RATE * 2)
	testing.expect_value(t, rule.chance, f32(0.5))
	testing.expect_value(t, rule.cap, 6)
	testing.expect_value(t, rule.within, 48)
	testing.expect_value(t, rule.distance, [2]f32{16, 40})
	testing.expect_value(t, rule.group, [2]int{1, 3})
	testing.expect(t, rule.sky)
	testing.expect_value(t, rule.despawn, SPAWN_DESPAWN)
	testing.expect_value(t, rule.place, Spawn_Place.Surface) // (a rule that names none)

	rocket_id, _ := registry_kind(reg, "rocket")
	r := kind_info(reg, rocket_id)
	testing.expect_value(t, r.box, [2]f32{0.3, 0.3})
	testing.expect_value(t, r.health, 1)
	testing.expect(t, !r.saved && !r.hittable && !r.summonable)
	testing.expect_value(t, r.physics, Entity_Physics.Projectile)
	testing.expect_value(t, r.projectile, Kind_Projectile_Info{32, 3, 6, 4})
	testing.expect_value(t, r.model, Entity_Model.Rocket)
	_, rocket_spawns := r.spawn.?
	testing.expect(t, !rocket_spawns)

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
	testing.expect_value(t, len(with.kinds), len(reg.kinds) + 1)
	cube_id, found := registry_kind(with, "testpack:cube")
	testing.expect(t, found)
	testing.expect_value(t, cube_id, Kind_Id(len(reg.kinds) + 1))
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
			`testpack/data/entities/k.json:1:120: brain is one of "none", "steered", "game"; got "hunter"`,
		},
		{
			"unknown voice",
			`{"k": {"box": [1, 1], "voice": "moo", "model": "item"}}`,
			`testpack/data/entities/k.json:1:32: voice is one of "bleat", "none", "growl", "squeak", "groan", "croak", "grunt", "chirp", "chitter", "whir", "bellow"; got "moo"`,
		},
		{
			"unknown model",
			`{"k": {"box": [1, 1], "model": "cow"}}`,
			`testpack/data/entities/k.json:1:32: model is one of "rocket", "item", "player" or {"box": [r, g, b]}; got "cow"`,
		},
		{
			"a game's brain without walker",
			`{"k": {"box": [1, 1], "brain": "game", "model": "item"}}`,
			`testpack/data/entities/k.json:1:32: brain "game" needs physics "walker"`,
		},
		{
			"steered without walker",
			`{"k": {"box": [1, 1], "brain": "steered", "model": "item"}}`,
			`testpack/data/entities/k.json:1:32: brain "steered" needs physics "walker"`,
		},
		{
			"a look named twice",
			`{"k": {"box": [1, 1], "looks": ["black", "black"], "model": "item"}}`,
			`testpack/data/entities/k.json:1:42: look "black" is named twice`,
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
			`{"k": {"box": [1, 1], "looks": ["a","b","c","d","e","f","g","h","i","j","k","l","m","n","o","p","q"], "model": "item"}}`,
			`testpack/data/entities/k.json:1:32: 17 looks; the limit is 16`,
		},
		{
			"a day outside 0..1",
			`{"k": {"box": [1, 1], "model": "item", "spawn": {"on": "voxiverse:grass", "day": [0.2, 1.5], "every": 60, "chance": 0.5, "cap": 6, "within": 48, "distance": [16, 40], "group": [1, 3]}}}`,
			`testpack/data/entities/k.json:1:82: day is [from, to], fractions of the day 0..1 from midnight (from above to: across midnight)`,
		},
		{
			"no box",
			`{"k": {"model": "item"}}`,
			`testpack/data/entities/k.json:1:2: a kind needs "box": [width, height]`,
		},
		{
			"no model",
			`{"k": {"box": [1, 1]}}`,
			`testpack/data/entities/k.json:1:2: a kind needs a "model": one of "rocket", "item", "player", {"box": [r, g, b]} or {"parts": [...]}`,
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
			"an attack on a walker with no steering",
			`{"k": {"box": [1, 1], ` +
			WALKER +
			`, "attack": {"damage": 1, "reach": 1, "cooldown": 1}, "model": "item"}}`,
			`testpack/data/entities/k.json:1:121: an attack is a steered walker's: set "brain": "steered" or "game"`,
		},
		{
			"an attack number missing",
			`{"k": {"box": [1, 1], ` +
			WALKER +
			`, "brain": "steered", "attack": {"damage": 1, "reach": 1}, "model": "item"}}`,
			`testpack/data/entities/k.json:1:141: attack needs "cooldown"; add it`,
		},
		{
			"a shot that is no projectile",
			`{"k": {"box": [1, 1], ` +
			WALKER +
			`, "brain": "steered", "attack": {"damage": 1, "reach": 1, "cooldown": 1, "shot": "voxiverse:dummy"}, "model": "item"}}`,
			`testpack/data/entities/k.json:1:2: attack shot "voxiverse:dummy" is not a projectile kind`,
		},
		{
			"striking with no attack",
			`{"k": {"box": [1, 1], "looks": ["striking"], "model": "item"}}`,
			`testpack/data/entities/k.json:1:33: look "striking" is its attack's; add an "attack"`,
		},
		{
			"a part with its box inside out",
			`{"k": {"box": [1, 1], "model": {"parts": [{"box": [0, 1, 0, 0.5, 0.5, 0.5], "color": [1, 2, 3]}]}}}`,
			`testpack/data/entities/k.json:1:51: a part's box is [x0, y0, z0, x1, y1, z1], -4..4, each low below its high`,
		},
		{
			"a part with no colour",
			`{"k": {"box": [1, 1], "model": {"parts": [{"box": [0, 0, 0, 0.5, 0.5, 0.5], "swing": "walk"}]}}}`,
			`testpack/data/entities/k.json:1:43: a part needs a "box" and a "color"`,
		},
		{
			"a part that swings oddly",
			`{"k": {"box": [1, 1], "model": {"parts": [{"box": [0, 0, 0, 0.5, 0.5, 0.5], "color": [1, 2, 3], "swing": "wave"}]}}}`,
			`testpack/data/entities/k.json:1:106: swing is one of "none", "walk", "walk_back", "strike", "pitch", "flap"; got "wave"; did you mean "walk"?`,
		},
		{
			"a part shown by a look the kind has not",
			`{"k": {"box": [1, 1], "looks": ["shorn"], "model": {"parts": [{"box": [0, 0, 0, 1, 1, 1], "color": [1, 2, 3], "shown": ["lamb"]}]}}}`,
			`testpack/data/entities/k.json:1:121: not one of the kind's looks (its "looks")`,
		},
		{
			"a spawn in an unknown place",
			`{"k": {"box": [1, 1], "model": "item", "spawn": {"on": "voxiverse:grass", "day": [0, 1], "every": 60, "chance": 1, "cap": 1, "within": 8, "distance": [4, 8], "group": [1, 1], "place": "sky"}}}`,
			`testpack/data/entities/k.json:1:185: place is one of "surface", "water", "cave"; got "sky"`,
		},
		{
			"a drop of an item no pack has",
			`{"k": {"box": [1, 1], "model": "item", "drops": [{"item": "voxiverse:gold"}]}}`,
			`testpack/data/entities/k.json:1:59: a drop's item is an item id that exists`,
		},
		{
			"a drop more than certain",
			`{"k": {"box": [1, 1], "model": "item", "drops": [{"item": "voxiverse:wheat", "chance": 2}]}}`,
			`testpack/data/entities/k.json:1:88: a drop's chance is a number 0..1`,
		},
		{
			"a drop of nothing",
			`{"k": {"box": [1, 1], "model": "item", "drops": [{"count": [1, 2]}]}}`,
			`testpack/data/entities/k.json:1:50: a drop needs an "item"`,
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

// A shaped fighter: its parts and its attack, as the pack wrote them.
@(test)
test_entity_kind_shape_and_attack :: proc(t: ^testing.T) {
	json := `{
		"orc": {"box": [0.8, 1.8], "physics": "walker",
		        "walker": {"walk_speed": 2, "run_speed": 2, "jump": 1, "step": 0}, "brain": "steered",
		        "attack": {"damage": 3, "reach": 1.2, "cooldown": 0.8, "shot": "testpack:spit"},
		        "looks": ["striking"],
		        "drops": [{"item": "voxiverse:wheat", "count": [1, 3], "chance": 0.5}, {"item": "voxiverse:seeds"}],
		        "model": {"parts": [
		            {"box": [-0.3, 0.8, -0.2, 0.3, 1.5, 0.2], "color": [80, 120, 60]},
		            {"box": [-0.3, 0, -0.1, -0.05, 0.8, 0.1], "color": [40, 40, 40], "skin": "legs", "swing": "walk"},
		            {"box": [0.3, 0.7, -0.1, 0.5, 1.5, 0.1], "color": [80, 120, 60], "swing": "strike"},
		            {"box": [-0.9, 1.3, -0.1, -0.3, 1.4, 0.3], "color": [90, 90, 90], "swing": "flap", "hinge": [-0.3, 1.4, 0.1]}]}},
		"spit": {"box": [0.2, 0.2], "physics": "projectile",
		         "projectile": {"speed": 20, "gravity": 0, "life": 2, "explode": 0}, "model": "rocket"}
	}`
	reg, errs := build_with(pack_of("testpack", []File{{"data/entities/k.json", json}}))
	testing.expect_value(t, errors_text(errs), "")
	if reg == nil {return}
	defer registry_destroy(reg)
	orc, _ := registry_kind(reg, "testpack:orc")
	spit, _ := registry_kind(reg, "testpack:spit")
	info := kind_info(reg, orc)
	testing.expect_value(t, info.model, Entity_Model.Parts)
	if !testing.expect_value(t, len(info.parts), 4) {return}
	testing.expect_value(t, info.parts[1].skin, Part_Skin.Legs)
	testing.expect_value(t, info.parts[2].swing, Part_Swing.Strike)
	testing.expect_value(t, info.parts[3].swing, Part_Swing.Flap)
	testing.expect_value(t, info.parts[3].hinge, [3]f32{-0.3, 1.4, 0.1})
	testing.expect_value(t, info.parts[0].hi, [3]f32{0.3, 1.5, 0.2})
	a, fights := info.attack.?
	testing.expect(t, fights)
	testing.expect_value(t, a.shot, spit)
	testing.expect_value(t, a.reach, 1.2)
	wheat, _ := registry_item(reg, "voxiverse:wheat")
	seeds, _ := registry_item(reg, "voxiverse:seeds")
	if !testing.expect_value(t, len(info.drops), 2) {return}
	testing.expect_value(t, info.drops[0].item, wheat)
	testing.expect_value(t, info.drops[0].count, [2]int{1, 3})
	testing.expect_value(t, info.drops[0].chance, 0.5)
	testing.expect_value(t, info.drops[1].item, seeds)
	testing.expect_value(t, info.drops[1].count, [2]int{1, 1})
	testing.expect_value(t, info.drops[1].chance, 1)
	testing.expect_value(t, len(kind_info(reg, spit).drops), 0)
}

// How a fighter hunts, as its attack says or by default: the band it keeps, where a
// shooter shoots from, how far it notices a player; a "shoot" needs a shot.
@(test)
test_attack_hunting_data :: proc(t: ^testing.T) {
	reg := registry_base(context.temp_allocator)
	if !testing.expect(t, reg != nil) {return}
	attack :: proc(reg: ^Registry, id: string) -> Kind_Attack_Info {
		k, _ := registry_kind(reg, id)
		return kind_info(reg, k).attack.? or_else {}
	}
	spitter := attack(reg, "spitter")
	testing.expect_value(t, spitter.keep, [2]f32{5, 8})
	testing.expect_value(t, spitter.shoot, [2]f32{0, 12})
	testing.expect_value(t, spitter.notice, f32(ATTACK_NOTICE))
	testing.expect_value(t, attack(reg, "matriarch").shoot, [2]f32{4, 64})
	testing.expect_value(t, attack(reg, "shambler").shoot, [2]f32{})

	json := `{"orc": {"box": [0.8, 1.8], "physics": "walker",
		"walker": {"walk_speed": 2, "run_speed": 2, "jump": 1, "step": 0}, "brain": "steered",
		"attack": {"damage": 3, "reach": 1.2, "cooldown": 0.8, "notice": 30}, "model": "item"}}`
	with, errs := build_with(pack_of("testpack", []File{{"data/entities/k.json", json}}))
	testing.expect_value(t, errors_text(errs), "")
	if with == nil {return}
	orc := attack(with, "testpack:orc")
	testing.expect_value(t, orc.keep, [2]f32{0, 1.2}) // (by default: up to its reach)
	testing.expect_value(t, orc.notice, f32(30))

	shooting := `{"orc": {"box": [0.8, 1.8], "physics": "walker",
		"walker": {"walk_speed": 2, "run_speed": 2, "jump": 1, "step": 0}, "brain": "steered",
		"attack": {"damage": 3, "reach": 1.2, "cooldown": 0.8, "shoot": [0, 9]}, "model": "item"}}`
	refused, errs2 := build_with(pack_of("testpack", []File{{"data/entities/k.json", shooting}}))
	testing.expect(t, refused == nil)
	testing.expect_value(
		t,
		errors_text(errs2),
		`testpack/data/entities/k.json:3:13: attack shoot is a shooter's; add its "shot"`,
	)
}

// A #tag matcher matches each state of every block type in the tag, by the block's number:
// a block numbered after the base pack's many-stated ones (stairs, fences) as well as
// grass (a tag's members are types; reading them as numbers matched fence states).
@(test)
test_tag_matcher_states :: proc(t: ^testing.T) {
	reg := test_reg()
	m, ok := matcher_compile(reg, "#voxiverse:wild_plant_soil")
	if !testing.expect(t, ok) {return}
	defer delete(m.bits)
	for id in ([]string{"voxiverse:grass", "voxiverse:sand", "voxiverse:mycelium"}) {
		b, found := registry_block(reg, id)
		testing.expectf(t, found && rule_matcher_has(&m, b), "%s not matched", id)
	}
	for b in 0 ..< reg.blocks.count {
		if !rule_matcher_has(&m, Block(b)) {continue}
		in_tag := false
		for x in reg.blocks.defs[reg.blocks.types[reg.blocks.type_of[b]].first_state].tags {
			tag, _ := registry_block_tag(reg, "voxiverse:wild_plant_soil")
			in_tag ||= i32(x) == tag
		}
		testing.expectf(t, in_tag, "%s matched, not in the tag", block_id(reg, Block(b)))
	}
}
