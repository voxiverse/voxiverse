package foundry_server

import "common:game"
import "games:foundry"
import "server:core"

// What players ask of the factory: a machine's panel (opened by using it), its recipe or
// research, its output taken and what it takes put in, a part crafted by hand, a machine
// or belt turned. The server judges each: where the player stands, what it carries, what
// is researched.

REACH :: 8 // blocks from a machine a player may work its panel within

// machine_use: a player used a machine: its panel opens (its client part is told; the
// player is put the panel's record while it stays open and near).
machine_use :: proc(s: ^core.Server, c: ^core.Client, at: game.Block_Pos) -> string {
	f := state(s)
	ref := core.player_ref(s, c)
	for &p in f.panels {
		if p.who == ref {
			p.at = at
			opened(s, c, at)
			return ""
		}
	}
	append(&f.panels, Open_Panel{ref, at})
	opened(s, c, at)
	return ""
}

opened :: proc(s: ^core.Server, c: ^core.Client, at: game.Block_Pos) {
	open := foundry.Panel_Open{at}
	core.game_event(s, c, &open)
}

// panel_of: what a player with the machine at `at` open sees of it.
panel_of :: proc(s: ^core.Server, at: game.Block_Pos) -> (out: foundry.Panel) {
	w := s.home
	m := core.machine_data(w, at, Machine)
	if m == nil {return}
	k := kind_at(s, w, at)
	slots := core.machine_slots(w, at)
	out = {
		at       = at,
		kind     = k,
		state    = m.state,
		recipe   = m.recipe,
		progress = u8(clamp(m.progress, 0, 1) * 100),
		power    = u8(clamp(m.ratio, 0, 1) * 100),
		count    = u8(min(len(slots), len(out.slots))),
		open     = true,
	}
	if k == .Lab {out.recipe = u16(state(s).status.studying) + 1}
	copy(out.slots[:], slots)
	return
}

near :: proc(c: ^core.Client, at: [3]i32) -> bool {
	d := c.player.position - {f64(at.x) + 0.5, f64(at.y) + 0.5, f64(at.z) + 0.5}
	return d.x * d.x + d.y * d.y + d.z * d.z <= REACH * REACH
}

request :: proc(s: ^core.Server, c: ^core.Client, r: core.Request) {
	f := state(s)
	w := s.home
	if c.world != w {return}
	if v, ok := core.request_value(s, r, foundry.Choose); ok {
		if near(c, v.at) {choose(s, c, v.at, v.recipe)}
		return
	}
	if v, ok := core.request_value(s, r, foundry.Take); ok {
		if near(c, v.at) {take_output(s, c, v.at)}
		return
	}
	if v, ok := core.request_value(s, r, foundry.Put); ok {
		if near(c, v.at) {put_in(s, c, v.at)}
		return
	}
	if v, ok := core.request_value(s, r, foundry.Craft); ok {
		craft(s, c, int(v.recipe))
		return
	}
	if v, ok := core.request_value(s, r, foundry.Turn); ok {
		if near(c, v.at) {turn(s, c, v.at)}
		return
	}
	if _, ok := core.request_value(s, r, foundry.Close); ok {
		ref := core.player_ref(s, c)
		for p, i in f.panels {
			if p.who == ref {
				unordered_remove(&f.panels, i)
				closed := foundry.Panel{}
				core.game_put(s, c, &closed)
				break
			}
		}
	}
}

// choose: an assembler's recipe (what it held for the last one goes to the player), or
// the research a lab's factory studies.
choose :: proc(s: ^core.Server, c: ^core.Client, at: game.Block_Pos, recipe: u16) {
	w := s.home
	f := state(s)
	switch kind_at(s, w, at) {
	case .Assembler:
		if recipe != 0 {
			if int(recipe) > len(s.registry.recipes) {return}
			r := &s.registry.recipes[recipe - 1]
			if r.machine != foundry.BY_ASSEMBLER {return}
			if !recipe_open(s, r) {
				core.notice(s, c, "Foundry: that recipe is not researched yet")
				return
			}
		}
		m := core.machine_data(w, at, Machine)
		if m.recipe == recipe {return}
		slots := core.machine_slots(w, at)
		for &st in slots[:4] {
			if game.stack_empty(st) {continue}
			core.items_used(s, w, st.item, st.count)
			core.item_give(s, c, st.item, st.count)
			st = {}
		}
		m.recipe, m.progress = recipe, 0
	case .Lab:
		if recipe == 0 || int(recipe) > len(foundry.Research) {return}
		r := foundry.Research(recipe - 1)
		studied := transmute(bit_set[foundry.Research])f.status.studied
		if r in studied || foundry.RESEARCH[r].needs > studied || r == f.status.studying {return}
		f.status.studying, f.status.progress = r, 0
	case .None, .Miner, .Furnace, .Crate, .Arm, .Splitter, .Generator:
	}
}

// take_output: what the machine made (a crate's all) into the player's pockets, as far as
// they hold it.
take_output :: proc(s: ^core.Server, c: ^core.Client, at: game.Block_Pos) {
	w := s.home
	out := OUTPUT[kind_at(s, w, at)]
	if out == -2 {return}
	slots := core.machine_slots(w, at)
	for &st, i in slots {
		if (out >= 0 && i != out) || game.stack_empty(st) {continue}
		given := core.item_give(s, c, st.item, st.count)
		core.items_used(s, w, st.item, given)
		st.count -= given
		if st.count <= 0 {st = {}}
	}
}

// put_in: what the player carries that the machine takes, into it, as far as it takes it.
put_in :: proc(s: ^core.Server, c: ^core.Client, at: game.Block_Pos) {
	w := s.home
	seen := make([dynamic]game.Item, context.temp_allocator)
	for st in c.inventory.slots {
		if game.stack_empty(st) {continue}
		already := false
		for x in seen {if x == st.item {already = true}}
		if already {continue}
		append(&seen, st.item)
		moved := 0
		for moved < core.item_count(c, st.item) && insert(s, w, at, st.item, false) {moved += 1}
		if moved > 0 {
			core.item_take(s, c, st.item, moved)
			core.items_made(s, w, st.item, moved)
		}
	}
}

// craft: one of a hand recipe, from what the player carries.
craft :: proc(s: ^core.Server, c: ^core.Client, index: int) {
	if index < 0 || index >= len(s.registry.recipes) {return}
	r := &s.registry.recipes[index]
	if r.machine != foundry.BY_HAND {return}
	if !recipe_open(s, r) {
		core.notice(s, c, "Foundry: that recipe is not researched yet")
		return
	}
	needs, _, n := game.recipe_needs(r)
	for i in 0 ..< n {
		if core.item_count(c, needs[i].item) < needs[i].count {
			core.notice(s, c, "Foundry: you lack what that takes")
			return
		}
	}
	for i in 0 ..< n {core.item_take(s, c, needs[i].item, needs[i].count)}
	core.item_give(s, c, r.output.item, r.output.count)
	core.stat_count(s, c, "foundry.crafted", r.output.count)
	f := state(s)
	if row := play_row(f, c); row != nil {row.crafted += u32(r.output.count)}
}

// turn: a machine or belt of the game's that faces a way, a quarter turn clockwise.
turn :: proc(s: ^core.Server, c: ^core.Client, at: game.Block_Pos) {
	w := s.home
	b, loaded := core.block_at(w, at)
	if !loaded || (kind_at(s, w, at) == .None && !is_belt(s, w, at)) {return}
	t := &s.registry.blocks
	for name, i in game.ROTATE_VALUES {
		if !game.state_is(t, b, "facing", name) {continue}
		turned, ok := game.state_set(t, b, "facing", game.ROTATE_VALUES[foundry.facing_turn(i)])
		if ok {core.set_block(w, at, turned, core.game_act(s, w, .Hand), c)}
		return
	}
}
