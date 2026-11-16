package foundry_server

import "core:fmt"

import "common:game"
import "games:foundry"
import "server:core"

// The factory's machines (core's machines: a record on each, a schedule): every machine
// thinks every THINK ticks, each kind its own way, at the speed its part of the power grid
// gives it; arms and miners hand on what they hold to what they face; what a machine
// shows (foundry.Shown) is what its label and its panel say.

Machine :: struct {
	recipe:   u16, // its recipe's registry index plus one (an assembler's choice; a furnace's last)
	progress: f32, // of the round under way, 0 to 1
	state:    foundry.State,
	asks:     bool, // it wanted power at its last think: counted in the next balance
	fuel:     f32, // a generator's seconds of burning left
	toggle:   u8, // a splitter's next side
	ratio:    f32, // the power it got at its last think
}

// OUTPUT: the slot a kind's output is in (-1: all of them, a crate's; -2: none).
OUTPUT := [foundry.Kind]int {
	.None      = -2,
	.Miner     = 0,
	.Furnace   = 1,
	.Assembler = 4,
	.Crate     = -1,
	.Arm       = -2,
	.Splitter  = -2,
	.Generator = -2,
	.Lab       = -2,
}

kind_at :: proc(s: ^core.Server, w: ^core.World, p: game.Block_Pos) -> foundry.Kind {
	b, loaded := core.block_at(w, p)
	if !loaded {return .None}
	return state(s).kinds[s.registry.blocks.type_of[b]] or_else .None
}

is_belt :: proc(s: ^core.Server, w: ^core.World, p: game.Block_Pos) -> bool {
	b, loaded := core.block_at(w, p)
	t := &s.registry.blocks
	return loaded && t.type_of[b] == t.type_of[state(s).belt]
}

// power_ratio: what the part of the grid the machine at p is on gives of what it asks (0:
// none, or on no part).
power_ratio :: proc(s: ^core.Server, w: ^core.World, p: game.Block_Pos) -> f32 {
	f := state(s)
	part, on := core.grid_part_at(w, f.grid, p)
	if !on {return 0}
	return f.power[part].ratio if part in f.power else 0
}

// think: the machines of one kind whose time has come.
think :: proc(s: ^core.Server, w: ^core.World, type: game.Block_Type, at: []game.Block_Pos) {
	f := state(s)
	k := f.kinds[type] or_else .None
	if k == .None || k == .Crate {return} 	// (a crate does nothing by itself)
	for p in at {
		machine_step(s, w, k, p)
		core.machine_wake(w, p, foundry.THINK)
	}
}

// machine_step: one think of the machine at p.
machine_step :: proc(s: ^core.Server, w: ^core.World, k: foundry.Kind, p: game.Block_Pos) {
	f := state(s)
	reg := s.registry
	m := core.machine_data(w, p, Machine)
	slots := core.machine_slots(w, p)
	b, _ := core.block_at(w, p)
	dir, _ := game.facing_vector(&reg.blocks, b)
	dt := f32(foundry.THINK) / game.TICK_RATE
	ratio := power_ratio(s, w, p)
	m.ratio = ratio
	count: u16
	switch k {
	case .None, .Crate:
	case .Miner:
		ore := ore_under(s, w, p)
		if ore == game.NO_ITEM {
			m.state, m.asks = .No_Ore, false
			break
		}
		// What it holds goes out first.
		if !game.stack_empty(slots[0]) && give(s, w, p + dir, slots[0].item) {
			take_one(&slots[0])
		}
		if slots[0].count >= foundry.STACK {
			m.state, m.asks = .Output_Full, false
			break
		}
		m.asks = true
		if !progress(m, ratio, dt, foundry.MINE_SECONDS) {break}
		core.items_made(s, w, ore, 1)
		if !give(s, w, p + dir, ore) {put_one(&slots[0], ore)}
	case .Furnace:
		r, rid, found := furnace_recipe(s, slots[0])
		if !found {
			m.state, m.asks, m.progress =
				.No_Input if game.stack_empty(slots[0]) else .Idle, false, 0
			break
		}
		m.recipe = u16(rid) + 1
		run(s, w, m, r, slots[:1], &slots[1], ratio, dt)
	case .Assembler:
		if m.recipe == 0 || int(m.recipe) > len(reg.recipes) {
			m.state, m.asks = .Idle, false
			break
		}
		run(s, w, m, &reg.recipes[m.recipe - 1], slots[:4], &slots[4], ratio, dt)
	case .Arm:
		m.asks = true
		if ratio == 0 {
			m.state = .No_Power
			break
		}
		m.state = .Working if hand_on(s, w, p - dir, p + dir) else .Idle
	case .Splitter:
		m.state = .Idle
		items := core.belt_peek(w, p - dir)
		if len(items) == 0 {break}
		item := items[0].item
		side := foundry.side_of(dir)
		ways := [2]game.Block_Pos{p + side, p - side}
		for i in 0 ..< 2 {
			to := ways[(int(m.toggle) + i) % 2]
			if is_belt(s, w, to) && core.belt_put(w, to, item) {
				core.belt_take(w, p - dir)
				m.toggle = u8((int(m.toggle) + i + 1) % 2)
				m.state = .Working
				break
			}
		}
	case .Generator:
		part, _ := core.grid_part_at(w, f.grid, p)
		load := f.power[part].load if part in f.power else 0
		if m.fuel <= 0 && !game.stack_empty(slots[0]) && load > 0 {
			take_one(&slots[0])
			core.items_used(s, w, f.fuel, 1)
			m.fuel += foundry.FUEL_SECONDS
		}
		if m.fuel > 0 {m.fuel = max(m.fuel - dt * max(load, 0.05), 0)}
		m.state = .Working if m.fuel > 0 else .No_Input
		count = u16(slots[0].count)
	case .Lab:
		lab_step(s, w, m, slots, ratio, dt)
	}
	if k == .Crate {
		for st in slots {count += u16(st.count)}
	}
	shown := foundry.Shown {
		kind     = k,
		state    = m.state,
		recipe   = m.recipe,
		progress = u8(clamp(m.progress, 0, 1) * 100),
		power    = u8(clamp(ratio, 0, 1) * 100),
		count    = count,
	}
	core.machine_show(w, p, &shown)
}

// progress: a round goes on by what the power gives; true when it is done (its progress
// starts again).
progress :: proc(m: ^Machine, ratio, dt, seconds: f32) -> bool {
	if ratio <= 0 {
		m.state = .No_Power
		return false
	}
	m.state = .Working
	m.progress += dt * ratio / seconds
	if m.progress < 1 {return false}
	m.progress -= 1
	return true
}

// run: a furnace's or an assembler's round of recipe r, its inputs in `inputs` (in the
// order of recipe_needs), its output into out.
run :: proc(
	s: ^core.Server,
	w: ^core.World,
	m: ^Machine,
	r: ^game.Recipe_Def,
	inputs: []game.Stack,
	out: ^game.Stack,
	ratio, dt: f32,
) {
	needs, _, n := game.recipe_needs(r)
	for i in 0 ..< n {
		at := slot_for(inputs, needs[i].item, i)
		if at < 0 || inputs[at].count < needs[i].count {
			m.state, m.asks = .No_Input, false
			return
		}
	}
	if !game.stack_empty(out^) &&
	   (out.item != r.output.item || out.count + r.output.count > foundry.STACK) {
		m.state, m.asks = .Output_Full, false
		return
	}
	m.asks = true
	if !progress(m, ratio, dt, r.time) {return}
	for i in 0 ..< n {
		at := slot_for(inputs, needs[i].item, i)
		inputs[at].count -= needs[i].count
		if inputs[at].count == 0 {inputs[at] = {}}
		core.items_used(s, w, needs[i].item, needs[i].count)
	}
	if game.stack_empty(out^) {out^ = {r.output.item, 0, 0, 0}}
	out.count += r.output.count
	core.items_made(s, w, r.output.item, r.output.count)
	if r.output.item == state(s).goal_item {goal_made(s, r.output.count)}
}

// slot_for: where an input goes: a furnace's one slot; an assembler's slot for its i-th need.
slot_for :: proc(inputs: []game.Stack, item: game.Item, i: int) -> int {
	if len(inputs) == 1 {return 0 if inputs[0].item == item else -1}
	return i if i < len(inputs) else -1
}

// furnace_recipe: the furnace's recipe for what its input holds.
furnace_recipe :: proc(s: ^core.Server, input: game.Stack) -> (^game.Recipe_Def, int, bool) {
	if game.stack_empty(input) {return nil, 0, false}
	for &r, i in s.registry.recipes {
		if r.machine != foundry.BY_FURNACE || !recipe_open(s, &r) {continue}
		needs, _, n := game.recipe_needs(&r)
		if n == 1 && needs[0].item == input.item {return &r, i, true}
	}
	return nil, 0, false
}

recipe_open :: proc(s: ^core.Server, r: ^game.Recipe_Def) -> bool {
	return foundry.recipe_open(r.id, transmute(bit_set[foundry.Research])state(s).status.studied)
}

ore_under :: proc(s: ^core.Server, w: ^core.World, p: game.Block_Pos) -> game.Item {
	f := state(s)
	b, _ := core.block_at(w, p - {0, 1, 0})
	for ore in f.ores {
		if b == ore {return game.item_of_block(s.registry, ore)}
	}
	return game.NO_ITEM
}

take_one :: proc(st: ^game.Stack) {
	st.count -= 1
	if st.count <= 0 {st^ = {}}
}

put_one :: proc(st: ^game.Stack, item: game.Item) {
	if game.stack_empty(st^) {st^ = {item, 0, 0, 0}}
	st.count += 1
}

// give: one item to what is at `to`: a belt's start, or a machine that takes it.
give :: proc(s: ^core.Server, w: ^core.World, to: game.Block_Pos, item: game.Item) -> bool {
	if is_belt(s, w, to) {return core.belt_put(w, to, item)}
	return insert(s, w, to, item, false)
}

// insert: one item into the machine at p, if it takes it (dry: only whether it would).
insert :: proc(
	s: ^core.Server,
	w: ^core.World,
	p: game.Block_Pos,
	item: game.Item,
	dry: bool,
) -> bool {
	f := state(s)
	k := kind_at(s, w, p)
	slot := -1
	switch k {
	case .None, .Arm, .Splitter, .Miner:
		return false
	case .Furnace:
		slots := core.machine_slots(w, p)
		probe := game.Stack{item, 1, 0, 0}
		if _, _, found := furnace_recipe(s, probe); !found {return false}
		if game.stack_empty(slots[0]) ||
		   (slots[0].item == item && slots[0].count < foundry.STACK) {slot = 0}
	case .Assembler:
		m := core.machine_data(w, p, Machine)
		if m.recipe == 0 {return false}
		slots := core.machine_slots(w, p)
		needs, _, n := game.recipe_needs(&s.registry.recipes[m.recipe - 1])
		for i in 0 ..< n {
			if needs[i].item != item {continue}
			if game.stack_empty(slots[i]) ||
			   slots[i].count < needs[i].count * foundry.INPUT_ROOM {slot = i}
		}
	case .Crate:
		slots := core.machine_slots(w, p)
		for st, i in slots {
			if st.item == item && st.count < foundry.STACK {slot = i; break}
		}
		if slot < 0 {for st, i in slots {if game.stack_empty(st) {slot = i; break}}}
	case .Generator:
		slots := core.machine_slots(w, p)
		if item == f.fuel && slots[0].count < 20 {slot = 0}
	case .Lab:
		slots := core.machine_slots(w, p)
		if item == f.insight && slots[0].count < 20 {slot = 0}
		if item == f.theory && slots[1].count < 20 {slot = 1}
	}
	if slot < 0 {return false}
	if !dry {put_one(&core.machine_slots(w, p)[slot], item)}
	return true
}

// hand_on: an arm moves one item from what is behind it to what is ahead: off a belt's front
// or out of a machine's output, into what takes it.
hand_on :: proc(s: ^core.Server, w: ^core.World, from, to: game.Block_Pos) -> bool {
	if is_belt(s, w, from) {
		items := core.belt_peek(w, from)
		if len(items) == 0 || items[0].at < game.LANE_END / 2 {return false}
		item := items[0].item
		if is_belt(s, w, to) {
			if !belt_room(w, to) {return false}
		} else if !insert(s, w, to, item, true) {return false}
		core.belt_take(w, from)
		return give(s, w, to, item)
	}
	out := OUTPUT[kind_at(s, w, from)]
	if out == -2 {return false}
	slots := core.machine_slots(w, from)
	for &st, i in slots {
		if (out >= 0 && i != out) || game.stack_empty(st) {continue}
		if give(s, w, to, st.item) {
			take_one(&st)
			return true
		}
	}
	return false
}

// belt_room: a belt's start has room for an item.
belt_room :: proc(w: ^core.World, p: game.Block_Pos) -> bool {
	items := core.belt_peek(w, p)
	n := len(items)
	return n == 0 || (n < game.LANE_ITEMS && items[n - 1].at >= game.LANE_SPACING)
}

// lab_step: a lab studies the research under way, a unit at a time, using an insight (and
// a theory where the research asks for them).
lab_step :: proc(
	s: ^core.Server,
	w: ^core.World,
	m: ^Machine,
	slots: []game.Stack,
	ratio, dt: f32,
) {
	f := state(s)
	st := &f.status
	studied := transmute(bit_set[foundry.Research])st.studied
	if studied ==
	   {.Assembly, .Circuits, .Frames, .Splitting, .Optics, .Theory, .Rotors, .Lodestar} {
		m.state, m.asks = .Idle, false
		return
	}
	info := foundry.RESEARCH[st.studying]
	if slots[0].count < 1 || (info.theory > 0 && slots[1].count < 1) {
		m.state, m.asks = .No_Input, false
		return
	}
	m.asks = true
	if !progress(m, ratio, dt, foundry.LAB_SECONDS) {return}
	take_one(&slots[0])
	core.items_used(s, w, f.insight, 1)
	if info.theory > 0 {
		take_one(&slots[1])
		core.items_used(s, w, f.theory, 1)
	}
	st.progress += 1
	if st.progress >= info.insight {
		studied += {st.studying}
		st.studied = transmute(u8)studied
		core.announce(s, fmt.tprintf("Foundry: %s researched", info.name))
		study_next(f)
	}
}

// study_next: the next research the tree allows, in its order (its progress from nothing).
study_next :: proc(f: ^Foundry) {
	studied := transmute(bit_set[foundry.Research])f.status.studied
	f.status.progress = 0
	for info, r in foundry.RESEARCH {
		if r in studied || info.needs > studied {continue}
		f.status.studying = r
		return
	}
}

// goal_made: lodestars came off an assembler; the goal reached ends the run's clock.
goal_made :: proc(s: ^core.Server, n: int) {
	st := &state(s).status
	st.made = u16(min(int(st.made) + n, 1000))
	if st.done || int(st.made) < state(s).settings.goal {return}
	st.done = true
	core.announce(
		s,
		fmt.tprintf("Foundry: the lodestar is made, in %d:%02d", st.seconds / 60, st.seconds % 60),
	)
	reached := foundry.Goal_Reached{st.seconds}
	for &c in s.clients {if c.state == .Playing {core.game_event(s, &c, &reached)}}
}

// power_balance (once a second): each part of the grid: its burning generators' supply
// against what its machines asked; what the machines get is in proportion.
power_balance :: proc(s: ^core.Server) {
	f := state(s)
	w := s.home
	clear(&f.power)
	st := &f.status
	st.supply, st.demand, st.parts = 0, 0, 0
	for part in core.grid_parts(w, f.grid) {
		pp: Part_Power
		for p in part.members {
			if !core.grid_node(w, f.grid, p) {continue}
			k := kind_at(s, w, p)
			m := core.machine_data(w, p, Machine)
			if m == nil {continue}
			if k == .Generator {
				if m.fuel > 0 ||
				   !game.stack_empty(
						   core.machine_slots(w, p)[0],
					   ) {pp.supply += foundry.GENERATOR_KW}
			} else if m.asks {
				pp.demand += foundry.DRAW_KW[k]
			}
		}
		pp.ratio = 1 if pp.demand == 0 else min(f32(pp.supply) / f32(pp.demand), 1)
		pp.load = 0 if pp.supply == 0 else min(f32(pp.demand) / f32(pp.supply), 1)
		// (an idle part keeps its machines able to start: they ask when they have work)
		if pp.demand == 0 && pp.supply > 0 {pp.ratio = 1}
		if pp.supply == 0 {pp.ratio = 0}
		f.power[part.id] = pp
		st.supply += pp.supply
		st.demand += pp.demand
		st.parts += 1
	}
}
