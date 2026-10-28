package server

import "core:fmt"

import "../base"
import "../common/game"

// Items on the server: inventory requests (applied by the shared rules,
// common/game/inventory.odin), placing blocks from the stack in hand, what
// breaking leaves, dropped stacks (thrown, falling, merging, picked up by
// walking over them), and the give, clear and item commands. A player with
// the infinite_items ability places without using anything up and breaks without
// leaving anything (they can have anything: the catalog ability).

// inventory_request: the client did something in its inventory. The answer
// (the inventory, and how far it got) goes out at the end of the tick,
// refused or not, so a refused prediction is rolled back.
@(private)
inventory_request :: proc(s: ^Server, c: ^Client, q: game.Inventory_Request) {
	chest_refresh(s, c)
	before := c.inventory.cursor
	dropped, ok := game.inventory_apply(
		s.registry,
		&c.inventory,
		q.action,
		has_ability(s, c, .Catalog),
	)
	if ok && q.action.kind == .Take {
		// The catalog makes the stack, and takes back what was on the cursor.
		ledger_stack(s, c.world, .Catalog_Return, before, -1)
		ledger_stack(s, c.world, .Catalog, c.inventory.cursor)
	}
	chest_keep(s, c)
	c.inv_acked = q.sequence
	c.inv_changed = true
	if ok && !game.stack_empty(dropped) {drop_stack(s, c, dropped)}
}

// used_to_place: c placed block (from slot): one used up.
@(private)
used_to_place :: proc(s: ^Server, c: ^Client, slot: int) {
	st := &c.inventory.slots[slot]
	ledger(s, c.world, .Place, st.item, -1)
	st.count -= 1
	game.inventory_tidy(&c.inventory)
	c.inv_changed = true
}

// broken_drop: what a player breaking block at pos leaves.
@(private)
broken_drop :: proc(s: ^Server, c: ^Client, pos: game.Block_Pos, block: game.Block) {
	if has_ability(s, c, .Infinite_Items) {return}
	block_drop(c.world, pos, block)
}

// block_drop: what block, gone from pos (broken by hand, or losing its
// support), leaves: its item, hopping out; nothing if the world has no
// drops. Tall grass gives seeds 1 time in 8; wheat gives seeds, and once ripe
// wheat as well.
@(private)
block_drop :: proc(w: ^World, pos: game.Block_Pos, block: game.Block) {
	if !w.rules.drops {return}
	r := &w.entities.rng
	seeds, wheat := game.item_of_material(.Seeds), game.item_of_material(.Wheat)
	drops := make([dynamic]game.Stack, context.temp_allocator)
	if stage, is_wheat := game.wheat_stage(block); is_wheat {
		if stage == game.WHEAT_STAGES - 1 {
			append(&drops, game.Stack{wheat, 1}, game.Stack{seeds, base.rng_int_range(r, 1, 4)})
		} else {
			append(&drops, game.Stack{seeds, 1})
		}
	} else if block == .Tall_Grass {
		if base.rng_int_max(r, 8) == 0 {append(&drops, game.Stack{seeds, 1})}
	} else if item := game.block_drop(w.server.registry, block); item != game.NO_ITEM {
		t := &w.server.registry.blocks
		double :=
			t.types[t.type_of[block]].place == .Slab && game.state_is(t, block, "type", "double")
		append(&drops, game.Stack{item, 2 if double else 1}) // (a double slab leaves two)
	}
	at := [3]f64{f64(pos.x) + 0.5, f64(pos.y) + 0.3, f64(pos.z) + 0.5}
	for st in drops {
		v := [3]f32{base.rng_f32_range(r, -1, 1), 2.5, base.rng_f32_range(r, -1, 1)}
		ledger_stack(w.server, w, .Drop_Block, st)
		spawn_item(w, at, st, v, -1)
	}
}

// drop_stack: c throws stack ahead of it.
@(private)
drop_stack :: proc(s: ^Server, c: ^Client, stack: game.Stack) {
	record(s, c, .Item_Dropped, game.item_name(s.registry, stack.item), i64(stack.count))
	yaw, pitch := c.look[0], c.look[1]
	cp := base.cos(pitch)
	dir := [3]f32{-base.sin(yaw) * cp, base.sin(pitch), -base.cos(yaw) * cp}
	eye := game.player_eye(c.player)
	at := eye + {f64(dir.x), f64(dir.y), f64(dir.z)} * 0.4 - {0, 0.3, 0}
	spawn_item(c.world, at, stack, dir * game.ITEM_THROW + {0, 2, 0}, int(player_id(s, c)))
}

// spawn_item: a dropped stack at position (its bottom centre).
@(private)
spawn_item :: proc(
	w: ^World,
	position: [3]f64,
	stack: game.Stack,
	velocity: [3]f32,
	owner: int,
) -> ^Entity {
	ent := entity_spawn(w, .Item, position, false)
	if ent == nil {
		ledger_stack(w.server, w, .Void, stack, -1)
		return nil
	}
	ent.stack = stack
	ent.body.velocity = velocity
	ent.owner = owner
	return ent
}

// item_tick moves the dropped stack at index, merges into it the stacks of
// its item near it, and gives it to a player walking over it. True when it
// is gone (picked up, or old).
@(private)
item_tick :: proc(w: ^World, index: int) -> bool {
	s := w.server
	ent := &w.entities.list[index]
	if f32(ent.age) * game.TICK_SECONDS > game.ITEM_LIFE {
		ledger_stack(s, w, .Expire, ent.stack, -1)
		return true
	}
	if !chunk_ready(w, ent.body.position) {return false} 	// its ground is not loaded: it waits
	query := game.Block_Query{&w.chunks, chunks_block, &w.server.registry.blocks}
	game.body_step(&ent.body, .Item, {}, false, &w.rules, query, game.TICK_SECONDS)
	if ent.body.on_ground {ent.body.velocity.x, ent.body.velocity.z = 0, 0}
	size := game.item_stack_size(s.registry, ent.stack.item)
	if ent.age % 10 == 0 {
		// Those after it in the list (not yet moved this tick) join it.
		for j := len(w.entities.list) - 1; j > index; j -= 1 {
			other := &w.entities.list[j]
			if other.kind != .Item || other.stack.item != ent.stack.item {continue}
			if ent.stack.count + other.stack.count > size {continue}
			d := other.body.position - ent.body.position
			if d.x * d.x + d.y * d.y + d.z * d.z >
			   game.ITEM_MERGE_RANGE * game.ITEM_MERGE_RANGE {continue}
			ent.stack.count += other.stack.count
			ent.age = min(ent.age, other.age)
			entity_gone(w, j)
			ent = &w.entities.list[index]
		}
	}
	for &c in s.clients {
		if c.state != .Playing || c.world != w {continue}
		delay := f32(2 if ent.owner == int(player_id(s, &c)) else game.ITEM_PICKUP_DELAY)
		if f32(ent.age) * game.TICK_SECONDS < delay {continue}
		d := c.player.position + {0, 0.5, 0} - ent.body.position
		if d.x * d.x + d.y * d.y + d.z * d.z >
		   game.ITEM_PICKUP_RANGE * game.ITEM_PICKUP_RANGE {continue}
		left := game.inventory_add(s.registry, &c.inventory, ent.stack)
		if left.count == ent.stack.count {continue} 	// no room
		record(
			s,
			&c,
			.Item_Picked,
			game.item_name(s.registry, ent.stack.item),
			i64(ent.stack.count - left.count),
		)
		ent.stack = left
		c.inv_changed = true
		if game.stack_empty(left) {return true}
	}
	return false
}

// --- Commands ---

// admin_give: give <player> <item> [count]; what does not fit is dropped
// at their feet.
@(private)
admin_give :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	targets := players_matching(s, c, args[0])
	if len(targets) == 0 {
		notice(s, c, fmt.tprintf("&c%s is not here", args[0]))
		return true
	}
	item, known := game.item_by_name(s.registry, args[1])
	if !known {
		notice(s, c, fmt.tprintf("&cNo item %s", args[1]))
		return true
	}
	count := 1
	if len(args) == 3 {
		n, ok := parse_count(args[2])
		if !ok {return false}
		count = n
	}
	size := game.item_stack_size(s.registry, item)
	for to in targets {
		ledger(s, to.world, .Give, item, count)
		for left := count; left > 0; left -= size {
			rest := game.inventory_add(s.registry, &to.inventory, {item, min(left, size)})
			if !game.stack_empty(
				rest,
			) {spawn_item(to.world, to.player.position + {0, 0.5, 0}, rest, {}, -1)}
		}
		to.inv_changed = true
	}
	notice(s, c, fmt.tprintf("Gave %d %s to %s", count, args[1], args[0]))
	return true
}

// admin_clear: clear [player] [item]: empty an inventory (of one item).
@(private)
admin_clear :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	who := c
	item := game.NO_ITEM
	for a in args {
		if i, ok := game.item_by_name(s.registry, a); ok {
			item = i
		} else if other := find_player(s, c, a); other != nil {
			who = other
		} else {
			return false
		}
	}
	if who != c && !allowed(s, c, "items.clear.others") {
		notice(s, c, "You may not clear others here (items.clear.others)")
		return true
	}
	before := who.inventory
	taken := game.inventory_remove(&who.inventory, item, max(int))
	if item == game.NO_ITEM && !game.stack_empty(who.inventory.cursor) {
		taken += who.inventory.cursor.count
		who.inventory.cursor = {}
	}
	for st, i in before.slots {
		ledger_stack(s, who.world, .Clear, {st.item, st.count - who.inventory.slots[i].count}, -1)
	}
	ledger_stack(
		s,
		who.world,
		.Clear,
		{before.cursor.item, before.cursor.count - who.inventory.cursor.count},
		-1,
	)
	who.inv_changed = true
	notice(s, c, fmt.tprintf("Cleared %d item(s) from %s", taken, client_name(who)))
	return true
}

// admin_item: what you hold.
@(private)
admin_item :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	held := game.inventory_held(&c.inventory)
	if game.stack_empty(held) {
		notice(s, c, "Your hand is empty")
	} else {
		notice(
			s,
			c,
			fmt.tprintf(
				"%d %s (item %d; %d per stack)",
				held.count,
				game.item_name(s.registry, held.item),
				int(held.item),
				game.item_stack_size(s.registry, held.item),
			),
		)
	}
	return true
}
