package foundry_server

import "core:os"
import "core:testing"

import "common:game"
import "common:protocol"
import "games:foundry"
import "server:core"
import "server:playtest"

// Foundry's rules on the stepped harness: miners, belts, arms, furnaces and assemblers at
// work; the power grid; research; the factory kept whole through a save and working with
// nobody near; two builders together; what a player is shown of a machine.

@(private = "file")
built :: proc(t: ^testing.T, rig: ^playtest.Rig) -> bool {
	return testing.expect(t, playtest.until(rig, proc(data: rawptr) -> bool {
				return state(playtest.srv((^playtest.Rig)(data))).built
			}, rig, 60), "the map was never built")
}

@(private = "file")
block_of :: proc(s: ^core.Server, k: foundry.Kind, facing := "") -> game.Block {
	b, _ := game.registry_block(s.registry, foundry.KIND_BLOCKS[k])
	if facing != "" {b, _ = game.state_set(&s.registry.blocks, b, "facing", facing)}
	return b
}

@(private = "file")
place :: proc(s: ^core.Server, p: game.Block_Pos, b: game.Block) {
	w := s.home
	core.set_block(w, p, b, core.game_act(s, w, .Structure))
	core.machine_wake(w, p, 1)
}

@(private = "file")
item :: proc(s: ^core.Server, id: string) -> game.Item {
	i, _ := game.registry_item(s.registry, id)
	return i
}

// powered: a generator with peat and a pole at `at`, reaching what is within five.
@(private = "file")
powered :: proc(s: ^core.Server, at: game.Block_Pos) {
	f := state(s)
	place(s, at, block_of(s, .Generator))
	core.machine_slots(s.home, at)[0] = {f.fuel, 20, 0, 0}
	core.items_made(s, s.home, f.fuel, 20)
	core.set_block(s.home, at + {0, 0, 1}, f.pole, core.game_act(s, s.home, .Structure))
}

@(private = "file")
count_in :: proc(s: ^core.Server, at: game.Block_Pos, it: game.Item) -> (n: int) {
	for st in core.machine_slots(s.home, at) {if st.item == it {n += st.count}}
	return
}

// The demo line: a miner fills its belt, an arm feeds the furnace, the furnace's bars go
// to a crate; the assembler makes gears from a crate of bars.
@(test)
test_a_line_mines_smelts_and_assembles :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME) {return}
	defer playtest.stop(rig)
	if !built(t, rig) {return}
	s := playtest.srv(rig)
	playtest.say(rig, "foundry demo")
	playtest.step(rig, playtest.ticks(6))
	on_belt := 0
	for x in i32(53) ..= 56 {on_belt += len(core.belt_peek(s.home, {x, 0, 40}))}
	testing.expect(t, on_belt > 0, "the miner put no ore on its belt")
	playtest.step(rig, playtest.ticks(30))
	testing.expect(
		t,
		count_in(s, {60, 0, 40}, item(s, "foundry:ember_bar")) > 0,
		"no bars came out of the furnace",
	)
	testing.expect(
		t,
		count_in(s, {56, 0, 46}, item(s, "foundry:gear")) > 0,
		"the assembler made no gears",
	)
	shown, told := rig.sess.mirror.machines[{58, 0, 40}]
	testing.expect(t, told, "the player was not shown the furnace")
	if told {testing.expect_value(t, (^foundry.Shown)(&shown).kind, foundry.Kind.Furnace)}
}

// A belt carries what is put on it in order, round a corner, and stops when its end is
// blocked.
@(test)
test_a_belt_carries_in_order_and_stops_when_blocked :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME) {return}
	defer playtest.stop(rig)
	if !built(t, rig) {return}
	s := playtest.srv(rig)
	f := state(s)
	w := s.home
	act := core.game_act(s, w, .Structure)
	east, _ := game.state_set(&s.registry.blocks, f.belt, "facing", "east")
	south, _ := game.state_set(&s.registry.blocks, f.belt, "facing", "south")
	for x in i32(30) ..< 34 {core.set_block(w, {x, 0, 30}, east, act)}
	for z in i32(30) ..< 33 {core.set_block(w, {34, 0, z}, south, act)}
	a, b := item(s, "foundry:ember_ore"), item(s, "foundry:tide_ore")
	sent := [6]game.Item{a, b, a, a, b, b}
	for it in sent {
		for !core.belt_put(w, {30, 0, 30}, it) {playtest.step(rig, 1)}
	}
	playtest.step(rig, playtest.ticks(12))
	// The last belt faces grass: the items wait, the first at its end, in order behind.
	got := make([dynamic]game.Item, context.temp_allocator)
	for z := i32(32);
	    z >= 30;
	    z -= 1 {for li in core.belt_peek(w, {34, 0, z}) {append(&got, li.item)}}
	for x := i32(33);
	    x >= 30;
	    x -= 1 {for li in core.belt_peek(w, {x, 0, 30}) {append(&got, li.item)}}
	testing.expect_value(t, len(got), len(sent))
	for i in 0 ..< min(len(got), len(sent)) {testing.expect_value(t, got[i], sent[i])}
	end := core.belt_peek(w, {34, 0, 32})
	testing.expect(
		t,
		len(end) > 0 && end[0].at == game.LANE_END,
		"nothing waits at the blocked end",
	)
}

// An arm feeds a furnace, which smelts at its recipe's time.
@(test)
test_an_arm_feeds_a_furnace_at_its_recipes_time :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME) {return}
	defer playtest.stop(rig)
	if !built(t, rig) {return}
	s := playtest.srv(rig)
	w := s.home
	ore, bar := item(s, "foundry:ember_ore"), item(s, "foundry:ember_bar")
	place(s, {20, 0, 20}, block_of(s, .Crate))
	core.machine_slots(w, {20, 0, 20})[0] = {ore, 5, 0, 0}
	core.items_made(s, w, ore, 5)
	place(s, {21, 0, 20}, block_of(s, .Arm, "east"))
	place(s, {22, 0, 20}, block_of(s, .Furnace))
	powered(s, {21, 0, 22})
	// Working once the ore is in and the power balanced; then a bar a recipe's time later.
	ok := playtest.until(rig, proc(data: rawptr) -> bool {
			s := playtest.srv((^playtest.Rig)(data))
			return core.machine_data(s.home, {22, 0, 20}, Machine).state == .Working
		}, rig, 5)
	if !testing.expect(t, ok, "the furnace never worked") {return}
	recipe, _ := game.recipe_by_id(s.registry, "foundry:smelt_ember")
	seconds := f64(s.registry.recipes[recipe].time)
	playtest.step(rig, playtest.ticks(seconds - 0.5))
	testing.expect_value(t, count_in(s, {22, 0, 20}, bar), 0)
	playtest.step(rig, playtest.ticks(1))
	testing.expect_value(t, count_in(s, {22, 0, 20}, bar), 1)
	testing.expect(t, count_in(s, {20, 0, 20}, ore) < 5, "the arm took no ore")
}

// An assembler makes the recipe chosen for it (by a player's request), from what is put in.
@(test)
test_an_assembler_makes_its_chosen_recipe :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME) {return}
	defer playtest.stop(rig)
	if !built(t, rig) {return}
	s := playtest.srv(rig)
	c := playtest.host(rig)
	at := game.Block_Pos{44, 0, 44}
	place(s, at, block_of(s, .Assembler))
	powered(s, {44, 0, 41})
	coil, _ := game.recipe_by_id(s.registry, "foundry:coil")
	c.player.position = {44.5, 0, 46.5}
	choose := foundry.Choose{at, u16(coil) + 1}
	core.harness_request(s, c, &choose)
	tide := item(s, "foundry:tide_bar")
	core.item_give(s, c, tide, 3)
	put := foundry.Put{at}
	core.harness_request(s, c, &put)
	testing.expect_value(t, core.item_count(c, tide), 1) // (it takes two rounds' worth)
	playtest.step(rig, playtest.ticks(4))
	testing.expect_value(t, count_in(s, at, item(s, "foundry:coil")), 4)
	take := foundry.Take{at}
	core.harness_request(s, c, &take)
	testing.expect_value(t, core.item_count(c, item(s, "foundry:coil")), 4)
}

// A machine on no powered part stops; a generator joined to it by a pole starts it; the
// pole broken splits the grid and stops it again.
@(test)
test_power_starts_and_stops_machines :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME) {return}
	defer playtest.stop(rig)
	if !built(t, rig) {return}
	s := playtest.srv(rig)
	w := s.home
	f := state(s)
	ore := item(s, "foundry:tide_ore")
	at := game.Block_Pos{60, 0, 60}
	place(s, at, block_of(s, .Furnace))
	core.machine_slots(w, at)[0] = {ore, 10, 0, 0}
	core.items_made(s, w, ore, 10)
	playtest.step(rig, playtest.ticks(2))
	testing.expect_value(t, core.machine_data(w, at, Machine).state, foundry.State.No_Power)
	// A generator eight blocks off, joined by two poles.
	place(s, {68, 0, 60}, block_of(s, .Generator))
	core.machine_slots(w, {68, 0, 60})[0] = {f.fuel, 10, 0, 0}
	core.items_made(s, w, f.fuel, 10)
	act := core.game_act(s, w, .Structure)
	core.set_block(w, {61, 0, 61}, f.pole, act)
	core.set_block(w, {66, 0, 61}, f.pole, act)
	playtest.step(rig, playtest.ticks(2))
	testing.expect_value(t, core.machine_data(w, at, Machine).state, foundry.State.Working)
	a, _ := core.grid_part_at(w, f.grid, at)
	b, _ := core.grid_part_at(w, f.grid, {68, 0, 60})
	testing.expect_value(t, a, b)
	// The far pole broken: two parts, the furnace without power.
	core.set_block(w, {66, 0, 61}, .Air, act)
	playtest.step(rig, playtest.ticks(2))
	a, _ = core.grid_part_at(w, f.grid, at)
	b, _ = core.grid_part_at(w, f.grid, {68, 0, 60})
	testing.expect(t, a != b, "the grid did not split")
	testing.expect_value(t, core.machine_data(w, at, Machine).state, foundry.State.No_Power)
}

// A lab studies with insight; its research done, the recipe it unlocks may be made by hand.
@(test)
test_research_unlocks_a_recipe :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME) {return}
	defer playtest.stop(rig)
	if !built(t, rig) {return}
	s := playtest.srv(rig)
	w := s.home
	f := state(s)
	c := playtest.host(rig)
	assembler, _ := game.recipe_by_id(s.registry, "foundry:assembler")
	r := &s.registry.recipes[assembler]
	needs, _, n := game.recipe_needs(r)
	for i in 0 ..< n {core.item_give(s, c, needs[i].item, needs[i].count * 2)}
	out := r.output.item
	craft := foundry.Craft{u16(assembler)}
	core.harness_request(s, c, &craft)
	testing.expect_value(t, core.item_count(c, out), 0) // (not researched)
	place(s, {40, 0, 60}, block_of(s, .Lab))
	core.machine_slots(w, {40, 0, 60})[0] = {f.insight, 12, 0, 0}
	core.items_made(s, w, f.insight, 12)
	powered(s, {42, 0, 60})
	playtest.step(
		rig,
		playtest.ticks(f64(foundry.RESEARCH[.Assembly].insight) * f64(foundry.LAB_SECONDS) + 4),
	)
	studied := transmute(bit_set[foundry.Research])f.status.studied
	testing.expect(t, .Assembly in studied, "the lab did not finish Assembly")
	core.harness_request(s, c, &craft)
	testing.expect_value(t, core.item_count(c, out), 1)
}

// snapshot: every machine's record and slots and every belt's items in the demo's area.
@(private = "file")
Snapshot :: struct {
	data:  [dynamic]Machine,
	slots: [dynamic]game.Stack,
	lanes: [dynamic]game.Lane_Item,
}

@(private = "file")
snapshot :: proc(s: ^core.Server) -> (out: Snapshot) {
	out.data = make([dynamic]Machine, context.temp_allocator)
	out.slots = make([dynamic]game.Stack, context.temp_allocator)
	out.lanes = make([dynamic]game.Lane_Item, context.temp_allocator)
	for z in i32(38) ..= 48 {
		for x in i32(50) ..= 62 {
			p := game.Block_Pos{x, 0, z}
			if m := core.machine_data(s.home, p, Machine); m != nil {
				append(&out.data, m^)
				for st in core.machine_slots(s.home, p) {append(&out.slots, st)}
			}
			for li in core.belt_peek(s.home, p) {append(&out.lanes, li)}
		}
	}
	return
}

// The factory, saved mid-production and opened again, is what it was, and works on: with
// nobody near it too.
@(test)
test_the_factory_is_kept_and_works_with_nobody_near :: proc(t: ^testing.T) {
	dir :: "build/test/foundry_kept"
	os.remove_all(dir)
	defer os.remove_all(dir)
	before: Snapshot
	made: int
	{
		rig := new(playtest.Rig)
		defer free(rig)
		if !playtest.start(t, rig, GAME, {save_dir = dir}) {return}
		if !built(t, rig) {
			playtest.stop(rig)
			return
		}
		s := playtest.srv(rig)
		playtest.say(rig, "foundry demo")
		playtest.step(rig, playtest.ticks(12))
		// Far off: the line works on.
		bar := item(s, "foundry:ember_bar")
		made = count_in(s, {60, 0, 40}, bar)
		core.teleport(s, playtest.host(rig), {2000.5, 0, 2000.5}, {})
		playtest.step(rig, playtest.ticks(20))
		testing.expect(
			t,
			count_in(s, {60, 0, 40}, bar) > made,
			"the line stopped with nobody near",
		)
		made = count_in(s, {60, 0, 40}, bar)
		before = snapshot(s) // (the last save is of this tick: none runs after it)
		playtest.stop(rig)
	}
	// Opened again: after its first tick, before its machines think, as it was.
	h := new(core.Harness)
	defer free(h)
	config := core.harness_world()
	config.game = GAME
	config.save_dir = dir
	if !testing.expect(t, core.harness_start(h, config)) {return}
	defer core.harness_stop(h)
	core.harness_step(h, 1)
	after := snapshot(&h.srv)
	testing.expect(t, len(before.data) > 5, "the factory was not kept")
	testing.expect_value(t, len(after.data), len(before.data))
	for i in 0 ..< min(len(after.data), len(before.data)) {testing.expect_value(t, after.data[i], before.data[i])}
	testing.expect_value(t, len(after.slots), len(before.slots))
	for i in 0 ..< min(len(after.slots), len(before.slots)) {testing.expect_value(t, after.slots[i], before.slots[i])}
	testing.expect_value(t, len(after.lanes), len(before.lanes))
	for i in 0 ..< min(len(after.lanes), len(before.lanes)) {testing.expect_value(t, after.lanes[i], before.lanes[i])}
	// And it works on, with nobody in the world at all.
	core.harness_step(h, playtest.ticks(15))
	testing.expect(
		t,
		count_in(&h.srv, {60, 0, 40}, item(&h.srv, "foundry:ember_bar")) > made,
		"the line did not go on",
	)
}

// Two builders: each one's machines counted as its own, and each shown the other's.
@(test)
test_two_builders_build_together :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME, {guests = 1}) {return}
	defer playtest.stop(rig)
	if !built(t, rig) {return}
	s := playtest.srv(rig)
	w := s.home
	a, b := playtest.host(rig), playtest.guest(rig)
	act := core.game_act(s, w, .Hand)
	core.set_block(w, {40, 0, 30}, block_of(s, .Crate), act, a)
	core.set_block(w, {41, 0, 30}, block_of(s, .Arm, "east"), act, b)
	core.set_block(w, {42, 0, 30}, block_of(s, .Furnace), act, b)
	playtest.step(rig, playtest.ticks(2))
	host_row := playtest.host_record(
		rig,
		foundry.Builder,
		protocol.key_player(core.player_id(s, a)),
	)
	guest_row := playtest.guest_record(
		rig,
		foundry.Builder,
		protocol.key_player(core.player_id(s, b)),
	)
	testing.expect(t, host_row != nil && host_row.placed == 1, "the host's machine not counted")
	testing.expect(
		t,
		guest_row != nil && guest_row.placed == 2,
		"the guest's machines not counted",
	)
	seen := playtest.guest_record(rig, foundry.Builder, protocol.key_player(core.player_id(s, a)))
	testing.expect(t, seen != nil && seen.placed == 1, "the guest not shown the host's")
}
