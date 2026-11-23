package sandbox_server

import "core:fmt"
import "core:math"

import "common:base"
import "common:game"
import "games:sandbox"
import "server:core"

// The survival loop's server side (README.md, "Gathering, crafting and outposts"): a
// player's crafting, judged and timed here (one recipe at a time, its inputs taken when it
// begins and its output given when its time is up); the Use action (a consumable used up,
// the survey scanner, the recall unit); what the remains spill when they are broken open
// (remains_spill, which the spawn area's code may call too); and what each player is shown
// of it (sandbox.Survival). The outposts are outposts.odin.

SCAN_RADIUS :: 24 // blocks each way the survey scanner looks
SCAN_COOLDOWN :: 2 * game.TICK_RATE
SURVIVAL_EVERY :: 8 // ticks between looks at what a player is shown
MAX_LOOT :: 8 // stacks a cache or vault spills at most

// Seat_Survival: a seat's crafting and scanner, for the player in it (`who`; another in
// the seat finds it reset).
Seat_Survival :: struct {
	who:       core.Player_Ref,
	making:    int, // the recipe being made: its index + 1 (0: none)
	began:     u64,
	done:      u64, // the tick it is made
	scan_from: u64, // the tick the scanner works again
	taken:     [game.MAX_PROCESS_INPUTS]game.Stack, // what the recipe being made took (given back if it leaves first)
}

// Survival_State: the session's: the registry's names the loop uses, and each seat's.
Survival_State :: struct {
	fabricator, beacon:                                    game.Block,
	salvage_heap, alloy_relic, relic_vault, remains_cache: game.Block,
	scan_targets:                                          [8]game.Block,
	scanner, recall:                                       game.Item,
	loot:                                                  [Loot]game.Item,
	seats:                                                 [dynamic]Seat_Survival,
}

// Loot: what the remains may hold, by the item's name in the pack.
Loot :: enum u8 {
	Salvage,
	Ancient_Alloy,
	Data_Shard,
	Charge_Cell,
	Circuit_Board,
	Med_Gel,
	Stim_Patch,
	Rivets,
	Recall_Unit,
	Restorer,
	Relic_Blade,
	Ward_Emitter,
	Phase_Lattice,
	Coil_Charge,
}

@(rodata)
LOOT_NAMES := [Loot]string {
	.Salvage       = "sandbox:salvage",
	.Ancient_Alloy = "sandbox:ancient_alloy",
	.Data_Shard    = "sandbox:data_shard",
	.Charge_Cell   = "sandbox:charge_cell",
	.Circuit_Board = "sandbox:circuit_board",
	.Med_Gel       = "sandbox:med_gel",
	.Stim_Patch    = "sandbox:stim_patch",
	.Rivets        = "sandbox:rivets",
	.Recall_Unit   = "sandbox:recall_unit",
	.Restorer      = "sandbox:restorer",
	.Relic_Blade   = "sandbox:relic_blade",
	.Ward_Emitter  = "sandbox:ward_emitter",
	.Phase_Lattice = "sandbox:phase_lattice",
	.Coil_Charge   = "sandbox:coil_charge",
}

// Loot_Roll: one line of a loot table: what, how many (lo..hi) and its weight.
Loot_Roll :: struct {
	what:   Loot,
	lo, hi: int,
	weight: int,
}

// CACHE_LOOT, VAULT_LOOT: what a remains cache (broken open with any tier 1 tool) and a
// sealed relic vault (tier 3) spill beside their sure finds (a cache 1-3 salvage, a vault
// the data shard its block leaves): CACHE_ROLLS and VAULT_ROLLS draws by weight.
@(rodata)
CACHE_LOOT := []Loot_Roll {
	{.Ancient_Alloy, 1, 2, 15},
	{.Charge_Cell, 1, 1, 15},
	{.Med_Gel, 1, 2, 12},
	{.Data_Shard, 1, 1, 10},
	{.Circuit_Board, 1, 1, 10},
	{.Rivets, 8, 16, 10},
	{.Stim_Patch, 1, 2, 8},
	{.Recall_Unit, 1, 1, 4},
	{.Restorer, 1, 1, 4},
	{.Relic_Blade, 1, 1, 2},
	{.Ward_Emitter, 1, 1, 2},
}
CACHE_ROLLS :: 2
@(rodata)
VAULT_LOOT := []Loot_Roll {
	{.Ancient_Alloy, 2, 3, 20},
	{.Restorer, 1, 1, 12},
	{.Coil_Charge, 6, 6, 10},
	{.Data_Shard, 1, 2, 10},
	{.Relic_Blade, 1, 1, 8},
	{.Ward_Emitter, 1, 1, 8},
	{.Phase_Lattice, 1, 1, 6},
}
VAULT_ROLLS :: 2

survival_of :: proc(s: ^core.Server) -> ^Survival_State {return &state(s).survival}

// survival_start: the names the loop uses, from the session's registry.
survival_start :: proc(s: ^core.Server) -> bool {
	g := survival_of(s)
	reg := s.registry
	g.fabricator = game.registry_block(reg, sandbox.FABRICATOR) or_return
	g.beacon = game.registry_block(reg, sandbox.BEACON_BLOCK) or_return
	g.salvage_heap = game.registry_block(reg, "sandbox:salvage_heap") or_return
	g.alloy_relic = game.registry_block(reg, "sandbox:alloy_relic") or_return
	g.relic_vault = game.registry_block(reg, "sandbox:relic_vault") or_return
	g.remains_cache = game.registry_block(reg, "sandbox:remains_cache") or_return
	g.scanner = game.registry_item(reg, "sandbox:survey_scanner") or_return
	g.recall = game.registry_item(reg, "sandbox:recall_unit") or_return
	for name, l in LOOT_NAMES {g.loot[l] = game.registry_item(reg, name) or_return}
	g.scan_targets = {
		g.salvage_heap,
		g.alloy_relic,
		g.relic_vault,
		g.remains_cache,
		game.registry_block(reg, "coal_ore") or_return,
		game.registry_block(reg, "copper_ore") or_return,
		game.registry_block(reg, "iron_ore") or_return,
		g.salvage_heap, // (a spare slot: the heap again)
	}
	return true
}

// survival_stop: what the loop allocated.
survival_stop :: proc(s: ^core.Server) {delete(survival_of(s).seats)}

// seat_survival: c's seat's, reset for a player new to the seat.
seat_survival :: proc(s: ^core.Server, c: ^core.Client) -> ^Seat_Survival {
	g := survival_of(s)
	seat := int(core.player_id(s, c))
	if seat >= len(g.seats) {resize(&g.seats, seat + 1)}
	ss := &g.seats[seat]
	if ref := core.player_ref(s, c); ss.who != ref {ss^ = {
			who = ref,
		}}
	return ss
}

// near_block: a block of type b within FABRICATOR_REACH of c's feet, each way.
near_block :: proc(c: ^core.Client, b: game.Block) -> bool {
	p := c.player.position
	feet := [3]i32{i32(math.floor(p.x)), i32(math.floor(p.y)), i32(math.floor(p.z))}
	r :: i32(sandbox.FABRICATOR_REACH)
	for y in feet.y - r ..= feet.y + r {
		for z in feet.z - r ..= feet.z + r {
			for x in feet.x - r ..= feet.x + r {
				if there, ok := core.block_at(c.world, {x, y, z}); ok && there == b {return true}
			}
		}
	}
	return false
}

// craft_ask: c asks to make a recipe: one of the sandbox's, at its station, with what it
// takes carried, and nothing else being made. Its inputs are taken now; it is made in its
// time (survival_tick).
craft_ask :: proc(s: ^core.Server, c: ^core.Client, ask: sandbox.Craft) {
	g := survival_of(s)
	ss := seat_survival(s, c)
	i := int(ask.recipe)
	if c.dead || i >= len(s.registry.recipes) {return}
	r := &s.registry.recipes[i]
	station, ours := sandbox.recipe_station(r)
	switch {
	case !ours:
		return
	case ss.making != 0:
		core.notice(s, c, "You are making something already")
	case station == .Fabricator && !near_block(c, g.fabricator):
		core.notice(s, c, "That is made at a fabricator: stand near one")
	case !sandbox.can_make(s.registry, r, &c.inventory):
		core.notice(s, c, "You do not carry what that takes")
	case:
		needs, tags, n := game.recipe_needs(r)
		ss.taken = {}
		at := 0
		for k in 0 ..< n {take(s, c, needs[k], tags[k], ss.taken[:], &at)}
		ss.making, ss.began = i + 1, s.tick
		ss.done = s.tick + u64(math.ceil(f64(r.time) * game.TICK_RATE))
	}
}

// take: count of an item, or of the items of a tag, out of c's slots, each stack taken
// noted in taken (from `at` on).
@(private = "file")
take :: proc(
	s: ^core.Server,
	c: ^core.Client,
	need: game.Stack,
	tag: i32,
	taken: []game.Stack,
	at: ^int,
) {
	note :: proc(taken: []game.Stack, at: ^int, item: game.Item, n: int) {
		if n <= 0 || at^ >= len(taken) {return}
		taken[at^] = {item, n, 0, 0}
		at^ += 1
	}
	if tag == game.NO_TAG {
		note(taken, at, need.item, core.item_take(s, c, need.item, need.count))
		return
	}
	left := need.count
	for st in c.inventory.slots {
		if left <= 0 {break}
		if game.stack_empty(st) || !game.registry_item_in_tag(s.registry, st.item, tag) {continue}
		item := st.item
		n := core.item_take(s, c, item, min(left, st.count))
		note(taken, at, item, n)
		left -= n
	}
}

// craft_left: a player who leaves with a recipe being made gets back what it took.
craft_left :: proc(s: ^core.Server, c: ^core.Client) {
	ss := seat_survival(s, c)
	if ss.making == 0 {return}
	for st in ss.taken {
		if game.stack_empty(st) {continue}
		if given := core.item_give(s, c, st.item, st.count); given < st.count {
			core.item_drop(s, c.world, c.player.position, {st.item, st.count - given, 0, 0})
		}
	}
	ss.making, ss.taken = 0, {}
}

// survival_tick: each player's recipe made when its time is up (what does not fit is
// dropped at its feet), and what it is shown, looked at every SURVIVAL_EVERY ticks.
survival_tick :: proc(s: ^core.Server) {
	g := survival_of(s)
	for &c in s.clients {
		if c.state != .Playing {continue}
		ss := seat_survival(s, &c)
		if ss.making != 0 && s.tick >= ss.done {
			r := &s.registry.recipes[ss.making - 1]
			ss.making = 0
			out := r.output
			if given := core.item_give(s, &c, out.item, out.count); given < out.count {
				core.item_drop(s, c.world, c.player.position, {out.item, out.count - given, 0, 0})
			}
			ss.taken = {}
			made := sandbox.Made{u16(out.item), u16(out.count)}
			core.game_event(s, &c, &made)
		}
		if (s.tick + u64(core.player_id(s, &c))) % SURVIVAL_EVERY != 0 {continue}
		shown := sandbox.Survival {
			near_fabricator = near_block(&c, g.fabricator),
		}
		if ss.making != 0 {
			shown.making = u16(ss.making)
			span := max(ss.done - ss.began, 1)
			shown.progress = u8(min(100 * (s.tick - ss.began) / span, 100))
		}
		outposts_shown(s, &c, &shown)
		core.game_put(s, &c, &shown)
	}
}

// use_held: the Use action: the gadget in c's hand works (the scanner, the recall unit), or
// the consumable there is used up.
use_held :: proc(s: ^core.Server, c: ^core.Client) {
	g := survival_of(s)
	held := game.inventory_held(&c.inventory)
	switch {
	case game.stack_empty(held):
		core.notice(s, c, "Hold something to use")
	case held.item == g.scanner:
		scan(s, c)
	case held.item == g.recall:
		recall(s, c)
	case:
		if why := core.item_consume(s, c); why != "" {core.notice(s, c, why)}
	}
}

// scan: the survey scanner tells c the nearest ore, salvage or relic within SCAN_RADIUS
// and which way it lies; then it rests SCAN_COOLDOWN.
@(private = "file")
scan :: proc(s: ^core.Server, c: ^core.Client) {
	g := survival_of(s)
	ss := seat_survival(s, c)
	if s.tick < ss.scan_from {
		core.notice(s, c, "The scanner is still charging")
		return
	}
	ss.scan_from = s.tick + SCAN_COOLDOWN
	p := c.player.position
	feet := [3]i32{i32(math.floor(p.x)), i32(math.floor(p.y)), i32(math.floor(p.z))}
	best, best_d := game.Block_Pos{}, i32(max(i32))
	found: game.Block
	r :: i32(SCAN_RADIUS)
	for y in feet.y - r ..= feet.y + r {
		for z in feet.z - r ..= feet.z + r {
			for x in feet.x - r ..= feet.x + r {
				b, ok := core.block_at(c.world, {x, y, z})
				if !ok || b == .Air || b == .Stone {continue}
				hit := false
				for t in g.scan_targets {if b == t {hit = true}}
				if !hit {continue}
				d :=
					(x - feet.x) * (x - feet.x) +
					(y - feet.y) * (y - feet.y) +
					(z - feet.z) * (z - feet.z)
				if d < best_d {best, best_d, found = {x, y, z}, d, b}
			}
		}
	}
	if found == .Air {
		core.notice(s, c, fmt.tprintf("Nothing within %d blocks", SCAN_RADIUS))
		return
	}
	core.notice(s, c, scan_text(block_label(s.registry, found), best - feet))
}

// scan_text: "Iron ore 14 blocks north-east, 6 down".
scan_text :: proc(what: string, d: [3]i32) -> string {
	across := int(math.round(math.sqrt(f64(d.x * d.x + d.z * d.z))))
	way := compass(d.x, d.z)
	level := ""
	switch {
	case d.y > 0:
		level = fmt.tprintf(", %d up", d.y)
	case d.y < 0:
		level = fmt.tprintf(", %d down", -d.y)
	}
	if across == 0 {return fmt.tprintf("%s right here%s", what, level)}
	return fmt.tprintf("%s %d blocks %s%s", what, across, way, level)
}

// compass: the way of a step dx, dz on the map as one of eight (north is -z).
compass :: proc(dx, dz: i32) -> string {
	WAYS :: [8]string {
		"east",
		"south-east",
		"south",
		"south-west",
		"west",
		"north-west",
		"north",
		"north-east",
	}
	angle := math.atan2(f64(dz), f64(dx)) // 0: east, pi/2: south (+z)
	at := int(math.round(angle / (math.PI / 4))) %% 8
	ways := WAYS
	return ways[at]
}

// block_label: a block's name as a player reads it ("voxiverse:iron_ore": "Iron ore").
block_label :: proc(reg: ^game.Registry, b: game.Block) -> string {
	return sandbox.id_label(game.block_id(reg, b))
}

// recall: the recall unit takes c to its outpost, used up; refused with none.
@(private = "file")
recall :: proc(s: ^core.Server, c: ^core.Client) {
	place, ok := outpost_home(s, c)
	if !ok {
		core.notice(s, c, "You have no outpost to go back to")
		return
	}
	if !core.item_spend(s, c, survival_of(s).recall, 1) {return}
	if why := core.go_to(s, c, place); why != "" {core.notice(s, c, why)}
}

// remains_loot: what one cache (vault false) or sealed vault spills, drawn from rng, into
// out; how many stacks.
remains_loot :: proc(
	g: ^Survival_State,
	rng: ^base.Rng,
	vault: bool,
	out: ^[MAX_LOOT]game.Stack,
) -> int {
	n := 0
	table, rolls := CACHE_LOOT, CACHE_ROLLS
	if vault {
		table, rolls = VAULT_LOOT, VAULT_ROLLS
	} else {
		out[n] = {g.loot[.Salvage], base.rng_int_range(rng, 1, 4), 0, 0}
		n += 1
	}
	total := 0
	for l in table {total += l.weight}
	for _ in 0 ..< rolls {
		pick := base.rng_int_max(rng, total)
		for l in table {
			if pick < l.weight {
				out[n] = {g.loot[l.what], base.rng_int_range(rng, l.lo, l.hi + 1), 0, 0}
				n += 1
				break
			}
			pick -= l.weight
		}
	}
	return n
}

// remains_spill: a cache or vault broken open at `at` spills its loot there (the spawn
// area's code may call it for remains it opens its own way).
remains_spill :: proc(s: ^core.Server, w: ^core.World, at: game.Block_Pos, vault: bool) {
	loot: [MAX_LOOT]game.Stack
	n := remains_loot(survival_of(s), &state(s).rng, vault, &loot)
	centre := [3]f64{f64(at.x) + 0.5, f64(at.y) + 0.5, f64(at.z) + 0.5}
	for st in loot[:n] {core.item_drop(s, w, centre, st)}
}
