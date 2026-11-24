package sandbox_server

import "core:encoding/json"
import "core:strings"
import "core:testing"

import "common:game"
import "common:protocol"
import "games:sandbox"
import "server:core"
import "server:playtest"

// The survival loop on a stepped server: the recipes the pack holds, crafting judged and
// timed, tools that gather by tier, consumables and worn gear, and what the remains hold.
// (Outposts: outposts_test.odin.)

// item_of: an item of the session's registry by id (the test fails without it).
item_of :: proc(t: ^testing.T, s: ^core.Server, id: string) -> game.Item {
	i, ok := game.registry_item(s.registry, id)
	testing.expectf(t, ok, "no item %s", id)
	return i
}

// recipe_of: a recipe's index in the session's registry by id.
recipe_of :: proc(t: ^testing.T, s: ^core.Server, id: string) -> u16 {
	i, ok := game.recipe_by_id(s.registry, id)
	testing.expectf(t, ok, "no recipe %s", id)
	return u16(i)
}

// survivor: the meadow (sheep_test.odin) with the host in survival, holding nothing.
survivor :: proc(t: ^testing.T, rig: ^Rig) -> bool {
	if !meadow(t, rig) {return false}
	s := playtest.srv(rig)
	h := playtest.host(rig)
	core.game_mode(s, h, "survival")
	for st in h.inventory.slots {if !game.stack_empty(st) {core.item_clear(s, h, st.item)}}
	return true
}

// break_at: the host breaks the block at p as its client does: it begins (an edit of face
// EDIT_FACE_BREAK_BEGIN), holds on for the block's ticks with what is in its hand, then asks
// for the break, and the server answers.
break_at :: proc(rig: ^Rig, p: game.Block_Pos) {
	s := playtest.srv(rig)
	h := playtest.host(rig)
	m := &rig.sess.mirror
	b, _ := core.block_at(s.home, p)
	abilities := game.derive_abilities(s.registry, h.mode, &h.inventory)
	need := game.break_ticks(
		s.registry,
		&h.world.rules,
		b,
		game.inventory_held(&h.inventory),
		abilities,
	)
	begin := protocol.Edit {
		after = m.prediction.next_sequence - 1,
		pos   = p,
		block = .Air,
		face  = game.EDIT_FACE_BREAK_BEGIN,
	}
	core.mirror_send(m, begin)
	playtest.step(rig, need + 2)
	m.edit_id += 1
	e := protocol.Edit {
		id    = m.edit_id,
		after = m.prediction.next_sequence - 1,
		pos   = p,
		block = .Air,
		face  = game.EDIT_FACE_BREAK,
	}
	core.mirror_send(m, e)
	playtest.step(rig, 40) // (and the drop picked up)
}

// Every recipe of the pack's is the sandbox's (made by hand or at a fabricator) and makes
// something, and a pack whose recipe names an item nobody has, or no station, is refused
// with the place and the fix.
@(test)
test_survival_recipes_load :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	ours := 0
	for &r in s.registry.recipes {
		if !strings.has_prefix(r.id, "sandbox:") {continue}
		ours += 1
		_, station := sandbox.recipe_station(&r)
		testing.expectf(t, station, "%s is made nowhere", r.id)
		testing.expectf(
			t,
			r.output.count > 0 && game.item_valid(s.registry, r.output.item),
			"%s makes nothing",
			r.id,
		)
		needs, _, n := game.recipe_needs(&r)
		testing.expectf(t, n > 0, "%s takes nothing", r.id)
		for k in 0 ..< n {testing.expectf(t, game.item_valid(s.registry, needs[k].item), "%s takes no item", r.id)}
	}
	testing.expectf(t, ours >= 50, "only %d recipes", ours)

	broken := []struct {
		text, want: string,
	} {
		{
			`{"x": {"type": "process", "machine": "sandbox:hand", "time": 1, "inputs": [{"item": "sandbox:unobtainium", "count": 1}], "output": {"item": "sandbox:cord", "count": 1}}}`,
			"sandbox:unobtainium",
		},
		{
			`{"x": {"type": "process", "time": 1, "inputs": [{"item": "sandbox:fibre", "count": 1}], "output": {"item": "sandbox:cord", "count": 1}}}`,
			"a process names its \"machine\"",
		},
		{
			`{"x": {"type": "process", "machine": "sandbox:hand", "time": 0, "inputs": [{"item": "sandbox:fibre", "count": 1}], "output": {"item": "sandbox:cord", "count": 1}}}`,
			"\"time\" of 0.05 to 600",
		},
	}
	for b in broken {
		files := make([dynamic]game.Pack_File, context.temp_allocator)
		append(&files, ..sandbox.PACK.files)
		append(&files, game.Pack_File{"data/recipes/broken.json", transmute([]u8)b.text})
		pack := game.Pack_Source {
			namespace = "sandbox",
			files     = files[:],
		}
		reg, errs := game.registry_build(
			{game.base_pack_source(context.temp_allocator), pack},
			.Server,
			context.temp_allocator,
		)
		text := make([dynamic]string, context.temp_allocator)
		for e in errs {append(&text, game.pack_error_text(e))}
		all := strings.join(text[:], "\n", context.temp_allocator)
		testing.expectf(
			t,
			reg == nil && strings.contains(all, "broken.json") && strings.contains(all, b.want),
			"%s: %s",
			b.want,
			all,
		)
	}
}

// Crafting: what a recipe takes is taken when it begins and what it makes is given when its
// time is up; one short of an input is refused and nothing is taken; a fabricator's recipe
// only near one; one at a time.
@(test)
test_survival_crafting :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !survivor(t, rig) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	h := playtest.host(rig)
	fibre, cord := item_of(t, s, "sandbox:fibre"), item_of(t, s, "sandbox:cord")
	ask := sandbox.Craft{recipe_of(t, s, "sandbox:cord")}

	// Exactly what it takes: 3 fibre make 2 cord in a second.
	core.item_give(s, h, fibre, 3)
	core.harness_request(s, h, &ask)
	testing.expect_value(t, core.item_count(h, fibre), 0)
	testing.expect_value(t, core.item_count(h, cord), 0)
	core.harness_request(s, h, &ask) // (one at a time)
	testing.expect(t, playtest.told(rig, "You are making something already"))
	playtest.step(rig, playtest.ticks(1.2))
	testing.expect_value(t, core.item_count(h, cord), 2)

	// Leaving with it being made gives back what it took, and nothing is made.
	core.item_give(s, h, fibre, 3)
	core.harness_request(s, h, &ask)
	testing.expect_value(t, core.item_count(h, fibre), 0)
	craft_left(s, h) // (the left hook's part)
	testing.expect_value(t, core.item_count(h, fibre), 3)
	playtest.step(rig, playtest.ticks(1.2))
	testing.expect_value(t, core.item_count(h, cord), 2)
	core.item_clear(s, h, fibre)

	// One short: refused, nothing taken.
	core.item_give(s, h, fibre, 2)
	core.harness_request(s, h, &ask)
	testing.expect(t, playtest.told(rig, "You do not carry what that takes"))
	playtest.step(rig, playtest.ticks(1.2))
	testing.expect_value(t, core.item_count(h, fibre), 2)
	testing.expect_value(t, core.item_count(h, cord), 2)

	// A fabricator's recipe: refused away from one, made beside one.
	ore, coal := item_of(t, s, "sandbox:raw_copper"), item_of(t, s, "sandbox:coal")
	ingot := item_of(t, s, "sandbox:copper_ingot")
	core.item_give(s, h, ore, 1)
	core.item_give(s, h, coal, 1)
	refine := sandbox.Craft{recipe_of(t, s, "sandbox:copper_ingot")}
	core.harness_request(s, h, &refine)
	testing.expect(t, playtest.told(rig, "That is made at a fabricator: stand near one"))
	core.set_block(
		s.home,
		{2, 0, 0},
		survival_of(s).fabricator,
		core.game_act(s, s.home, .Command),
	)
	core.harness_request(s, h, &refine)
	playtest.step(rig, playtest.ticks(2.2))
	testing.expect_value(t, core.item_count(h, ingot), 1)
	testing.expect_value(t, core.item_count(h, ore), 0)
	shown := playtest.host_record(rig, sandbox.Survival)
	testing.expect(t, shown != nil && shown.near_fabricator, "not shown the fabricator near")
}

// Tools: bare hands do not break stone (tier 1), a flint pick does; iron ore wants a copper
// pick; the alloy drill gets one more of each ore.
@(test)
test_survival_tools_gather_by_tier :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !survivor(t, rig) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	h := playtest.host(rig)
	w := s.home
	act := core.game_act(s, w, .Command)
	stone, _ := game.registry_block(s.registry, "stone")
	iron, _ := game.registry_block(s.registry, "iron_ore")
	copper, _ := game.registry_block(s.registry, "copper_ore")
	at := game.Block_Pos{1, 0, 0}

	core.set_block(w, at, stone, act)
	break_at(rig, at)
	testing.expect(t, playtest.told(rig, "That needs a tier 1 tool"))
	if b, _ := core.block_at(w, at); !testing.expect_value(t, b, stone) {return}

	core.item_give(s, h, item_of(t, s, "sandbox:flint_pick"), 1)
	core.hotbar_select(s, h, 0)
	break_at(rig, at)
	b, _ := core.block_at(w, at)
	testing.expect_value(t, b, game.Block.Air)
	testing.expect_value(t, core.item_count(h, game.item_of_block(s.registry, stone)), 1)

	core.set_block(w, at, iron, act)
	break_at(rig, at)
	testing.expect(t, playtest.told(rig, "That needs a tier 2 tool"))

	core.item_clear(s, h, item_of(t, s, "sandbox:flint_pick"))
	core.item_give(s, h, item_of(t, s, "sandbox:alloy_drill"), 1)
	core.hotbar_select(s, h, 0)
	core.set_block(w, at, copper, act)
	break_at(rig, at)
	testing.expect_value(t, core.item_count(h, item_of(t, s, "sandbox:raw_copper")), 2)

	// How long each takes on stone (break_time 1, the sandbox's): hands cannot; the drill is
	// the fastest; a knife is no quicker than hands on stone, and quick on a log.
	r := &w.rules
	testing.expect_value(t, r.break_time, 1)
	ticks :: proc(t: ^testing.T, s: ^core.Server, b: game.Block, item: string) -> int {
		held := game.Stack{}
		if item != "" {held = {item_of(t, s, item), 1, 0, 0}}
		return game.break_ticks(s.registry, &s.home.rules, b, held, {})
	}
	log, _ := game.registry_block(s.registry, "log")
	testing.expect_value(t, ticks(t, s, stone, "sandbox:flint_pick"), 30)
	testing.expect_value(t, ticks(t, s, stone, "sandbox:copper_pick"), 19)
	testing.expect_value(t, ticks(t, s, stone, "sandbox:alloy_drill"), 10)
	testing.expect_value(t, ticks(t, s, log, ""), 60)
	testing.expect_value(t, ticks(t, s, log, "sandbox:flint_knife"), 20)
	testing.expect_value(t, ticks(t, s, log, "sandbox:machete"), 10)
	testing.expect_value(t, ticks(t, s, log, "sandbox:flint_pick"), 60)
}

// What is worn turns harm aside while worn and not once taken off; a consumable used up
// heals and turns harm aside for its time.
@(test)
test_survival_gear_and_consumables :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !survivor(t, rig) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	h := playtest.host(rig)
	playtest.step(rig, 2) // (its most health as survival has it)
	h.protected_until = 0

	// Exo striders: a fall's harm is a fifth.
	h.inventory.equipment[game.Equip_Slot.Feet] = {item_of(t, s, "sandbox:exo_striders"), 1, 0, 0}
	h.health = 20
	core.damage(s, h, 10, {kind = .Fall})
	testing.expect_value(t, h.health, 18)
	h.inventory.equipment[game.Equip_Slot.Feet] = {}
	h.health = 20
	core.damage(s, h, 10, {kind = .Fall})
	testing.expect_value(t, h.health, 10)

	// A field dressing heals 4; a stim patch takes a quarter off for 30 seconds.
	core.item_give(s, h, item_of(t, s, "sandbox:field_dressing"), 1)
	core.hotbar_select(s, h, 0)
	use_held(s, h)
	testing.expect_value(t, h.health, 14)
	testing.expect_value(t, core.item_count(h, item_of(t, s, "sandbox:field_dressing")), 0)
	core.item_give(s, h, item_of(t, s, "sandbox:stim_patch"), 1)
	core.hotbar_select(s, h, 0)
	use_held(s, h)
	core.damage(s, h, 4, {kind = .Explosion})
	testing.expect_value(t, h.health, 11)
	playtest.step(rig, playtest.ticks(31))
	h.health = 14
	core.damage(s, h, 4, {kind = .Explosion})
	testing.expect_value(t, h.health, 10)
}

// The remains: a cache spills salvage and two draws more, a vault two draws beside its
// shard; every draw is an item of the pack's.
@(test)
test_survival_remains_loot :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	g := survival_of(s)
	salvage := item_of(t, s, "sandbox:salvage")
	for _ in 0 ..< 50 {
		loot: [MAX_LOOT]game.Stack
		n := remains_loot(g, &state(s).rng, false, &loot)
		testing.expect_value(t, n, 1 + CACHE_ROLLS)
		testing.expect(t, loot[0].item == salvage && loot[0].count >= 1 && loot[0].count <= 3)
		for st in loot[:n] {testing.expect(t, game.item_valid(s.registry, st.item) && st.count > 0)}
		n = remains_loot(g, &state(s).rng, true, &loot)
		testing.expect_value(t, n, VAULT_ROLLS)
	}
}

// Every item the survival loop adds is had somehow: from what the world's blocks leave when
// gathered, the remains' blocks and their loot, what the creatures leave where they die, and
// what the recipes make of those, again and again. An item nothing yields would be filler;
// and each thing a creature leaves goes into a recipe, or it would be filler too.
@(test)
test_survival_every_item_is_obtainable :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	reg := s.registry
	had := obtainable(t, s)
	dropped := make(map[game.Item]bool, context.temp_allocator)
	for &kind in reg.kinds {
		for d in kind.drops {dropped[d.item] = true}
	}
	for item in dropped {
		used := false
		for &r in reg.recipes {
			if _, ours := sandbox.recipe_station(&r); !ours {continue}
			needs, _, n := game.recipe_needs(&r)
			for k in 0 ..< n {used ||= needs[k].item == item}
		}
		testing.expectf(t, used, "no recipe takes %s", game.item_id(reg, item))
	}
	testing.expectf(t, len(dropped) >= 10, "the creatures leave %d things", len(dropped))
	for f in sandbox.PACK.files {
		switch f.path {
		case "data/items/survival.json",
		     "data/blocks/survival.json",
		     "data/items/creature_drops.json":
		case:
			continue
		}
		value, err := json.parse(f.data, .JSON5, allocator = context.temp_allocator)
		if !testing.expectf(t, err == nil, "%s: %v", f.path, err) {continue}
		for name in value.(json.Object) {
			if strings.contains(name, ":") {continue} 	// (an override of the base pack's)
			id := strings.concatenate({"sandbox:", name}, context.temp_allocator)
			item, is_item := game.registry_item(reg, id)
			if !is_item {continue} 	// (a block that is never placed: the remains)
			testing.expectf(t, had[item], "nothing yields %s", id)
		}
	}
}

// WORLD_BLOCKS: the blocks a survivor finds in the world to break (the land's and the
// remains'), by id.
WORLD_BLOCKS :: []string {
	"log",
	"spruce_log",
	"leaves",
	"spruce_leaves",
	"gravel",
	"sand",
	"stone",
	"dirt",
	"coal_ore",
	"copper_ore",
	"iron_ore",
	"amber_ore", // the world classes' rare resources (common/worldgen/classes.odin)
	"opal_ore",
	"cryolite_ore",
	"sulfur_ore",
	"ilmenite_ore",
	"jade_ore",
	"nacre",
	"glow_cap",
	"sandbox:salvage_heap",
	"sandbox:alloy_relic",
	"sandbox:relic_vault",
	"sandbox:remains_cache",
}

// obtainable: every item a survivor can come by: what the world's blocks leave, the farm's
// wheat, the remains' finds, what the creatures leave, and all the sandbox's recipes make
// of those (temporary memory).
obtainable :: proc(t: ^testing.T, s: ^core.Server) -> map[game.Item]bool {
	reg := s.registry
	had := make(map[game.Item]bool, context.temp_allocator)
	for name in WORLD_BLOCKS {
		b, ok := game.registry_block(reg, name)
		if !testing.expectf(t, ok, "no block %s", name) {continue}
		if d := game.block_drop(reg, b); d != game.NO_ITEM {had[d] = true}
	}
	had[game.item_of_material(.Wheat)] = true // (seeds from tall grass, farmed with a hoe)
	for l in CACHE_LOOT {had[survival_of(s).loot[l.what]] = true}
	for l in VAULT_LOOT {had[survival_of(s).loot[l.what]] = true}
	had[survival_of(s).loot[.Salvage]] = true
	for &kind in reg.kinds {
		for d in kind.drops {had[d.item] = true}
	}
	for grew := true; grew; {
		grew = false
		for &r in reg.recipes {
			if _, ours := sandbox.recipe_station(&r); !ours || had[r.output.item] {continue}
			needs, _, n := game.recipe_needs(&r)
			all := true
			for k in 0 ..< n {all &&= had[needs[k].item]}
			if all {had[r.output.item], grew = true, true}
		}
	}
	return had
}
