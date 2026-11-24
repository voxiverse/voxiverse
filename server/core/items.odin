package core

import "core:fmt"
import "core:slice"

import "common:base"
import "common:game"
import "common:protocol"

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
inventory_request :: proc(s: ^Server, c: ^Client, q: protocol.Inventory_Request) {
	chest_refresh(s, c)
	before := c.inventory.cursor
	was := c.inventory
	dropped, ok := game.inventory_apply(
		s.registry,
		&c.inventory,
		q.action,
		has_ability(s, c, .Catalog),
	)
	if ok && !game.stack_empty(dropped) && s.config.game.dropping != nil {
		// The game may keep a stack in: the request is undone (its answer rolls the
		// client's prediction back), and nothing is thrown.
		if why := s.config.game.dropping(s, c, dropped); why != "" {
			c.inventory = was
			dropped, ok = {}, false
			notice(s, c, why)
		}
	}
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

// hotbar_select: c holds hotbar slot `slot` (0 ..< game.HOTBAR_SLOTS), as if it had
// chosen it (the Select its client sends). false, and nothing changes, for a slot out
// of range. The Inventory record tells the player at the end of the tick, and its
// client takes it over its own choice. For a game (docs/games.md): the weapon a round
// starts with in hand.
hotbar_select :: proc(s: ^Server, c: ^Client, slot: int) -> bool {
	if _, ok := game.inventory_apply(s.registry, &c.inventory, {.Select, 0, slot}, false); !ok {
		return false
	}
	c.inv_changed = true
	return true
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
	more := 0
	if game.block_tier(s.registry, block) >= 1 {
		more = int(game.gather_of(s.registry, game.inventory_held(&c.inventory)).yield)
		chance := game.skill_value(s.registry, &c.skills, .Yield_Chance, 0) // (no draw without the skill)
		if chance > 0 && base.rng_f32(&c.world.entities.rng) < chance {more += 1}
	}
	block_drop(c.world, pos, block, more)
}

// block_drop: what block, gone from pos (broken by hand, or losing its
// support), leaves: its item, hopping out; nothing if the world has no
// drops. Tall grass gives seeds 1 time in 8; wheat gives seeds, and once ripe
// wheat as well. `more`: that many more of a block's own drop (a tool's yield).
@(private)
block_drop :: proc(w: ^World, pos: game.Block_Pos, block: game.Block, more := 0) {
	if !w.rules.drops {return}
	r := &w.entities.rng
	seeds, wheat := game.item_of_material(.Seeds), game.item_of_material(.Wheat)
	drops := make([dynamic]game.Stack, context.temp_allocator)
	if stage, is_wheat := game.wheat_stage(block); is_wheat {
		if stage == game.WHEAT_STAGES - 1 {
			append(
				&drops,
				game.Stack{wheat, 1, 0, 0},
				game.Stack{seeds, base.rng_int_range(r, 1, 4), 0, 0},
			)
		} else {
			append(&drops, game.Stack{seeds, 1, 0, 0})
		}
	} else if block == .Tall_Grass {
		if base.rng_int_max(r, 8) == 0 {append(&drops, game.Stack{seeds, 1, 0, 0})}
	} else if item := game.block_drop(w.server.registry, block); item != game.NO_ITEM {
		t := &w.server.registry.blocks
		double :=
			t.types[t.type_of[block]].place == .Slab && game.state_is(t, block, "type", "double")
		append(&drops, game.Stack{item, (2 if double else 1) + more, 0, 0}) // (a double slab leaves two)
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
	throw := game.kind_info(s.registry, s.registry.engine.item).item.throw
	spawn_item(c.world, at, stack, dir * throw + {0, 2, 0}, int(player_id(s, c)))
}

// spawn_item: a dropped stack at position (its bottom centre).
@(private)
spawn_item :: proc(
	w: ^World,
	position: [3]f64,
	stack: game.Stack,
	velocity: [3]f32,
	owner: int,
) -> game.Entity_Handle {
	ent := entity_spawn(w, w.server.registry.engine.item, position, false)
	if ent == 0 {
		ledger_stack(w.server, w, .Void, stack, -1)
		return 0
	}
	entity_stack(w, ent)^ = stack
	entity_set_velocity(w, ent, velocity)
	entity_owner(w, ent).client = i32(owner)
	return ent
}

// PICKUP_SLACK: how far a player can have moved since the spatial service
// last saw them (a tick of running is well under this).
PICKUP_SLACK :: 2

// item_tick moves the dropped stack at index, merges into it the stacks of
// its item near it, and gives it to a player walking over it. True when it
// is gone (picked up, or old).
@(private)
item_tick :: proc(w: ^World, ent: game.Entity_Handle) -> bool {
	s := w.server
	ekind := entity_kind(w, ent)
	kind := game.kind_info(s.registry, ekind)
	if f32(entity_age_of(w, ent)) * game.TICK_SECONDS > kind.item.life {
		ledger_stack(s, w, .Expire, entity_stack(w, ent)^, -1)
		return true
	}
	if !chunk_ready(w, entity_pos(w, ent)) {return false} 	// its ground is not loaded: it waits
	query := game.Block_Query{&w.chunks, chunks_block, &w.server.registry.blocks, {}}
	entity_body_step(w, ent, kind, {}, false, query)
	if entity_on_ground(w, ent) {
		v := entity_velocity(w, ent)
		entity_set_velocity(w, ent, {0, v.y, 0})
	}
	size := game.item_stack_size(s.registry, entity_stack(w, ent)^.item)
	if entity_age_of(w, ent) % 10 == 0 {
		// Those after it in id order (not yet moved this tick) join it. The
		// spatial service names the item stacks near it (asking a little wider,
		// as their boxes are where they were at the end of the last tick); the
		// store says where each is now and whether it comes after.
		if item_kind := s.registry.engine.item; item_kind != 0 {
			ew := w.entity_world
			near := make([dynamic]game.Entity_Id, context.temp_allocator)
			game.spatial_sphere(
				&ew.spatial,
				entity_pos(w, ent),
				f64(kind.item.merge) + PICKUP_SLACK,
				{kind = u16(item_kind), exclude = game.Entity_Id(entity_id(w, ent))},
				&near,
			)
			// highest id first
			slice.sort(near[:])
			own := entity_id(w, ent)
			#reverse for id in near {
				other, found := entity_find(w, u32(id))
				if !found || u32(id) < own {continue}
				if entity_kind(w, other) != ekind ||
				   !game.stacks_alike(entity_stack(w, other)^, entity_stack(w, ent)^) {continue}
				if entity_stack(w, ent)^.count + entity_stack(w, other)^.count > size {continue}
				d := entity_pos(w, other) - entity_pos(w, ent)
				if d.x * d.x + d.y * d.y + d.z * d.z >
				   f64(kind.item.merge * kind.item.merge) {continue}
				entity_stack(w, ent)^.count += entity_stack(w, other)^.count
				// (the age system has run for every entity: this one before it was
				// walked, so those after it count one tick less, as before the systems)
				entity_set_age(w, ent, min(entity_age_of(w, ent), entity_age_of(w, other) - 1))
				entity_gone(w, other)
			}
		}
	}
	// The players near it come from the spatial service (their boxes are where
	// they stood at the end of the last tick, so it asks a little wider); the
	// client says where each is now. Clients in order, as the loop over all did.
	ew := w.entity_world
	near := make([dynamic]game.Entity_Id, context.temp_allocator)
	game.spatial_sphere(
		&ew.spatial,
		entity_pos(w, ent),
		f64(kind.item.range) + PICKUP_SLACK,
		{all = {.Player}},
		&near,
	)
	who := make([dynamic]int, context.temp_allocator)
	for id in near {
		h, live := game.store_find(&ew.store, id)
		if !live {continue}
		link := game.store_get(&ew.store, h, game.C_PLAYER_LINK, game.Player_Link)
		if link != nil && int(link.client) < len(s.clients) {append(&who, int(link.client))}
	}
	slice.sort(who[:])
	for ci in who {
		c := &s.clients[ci]
		if c.state != .Playing || c.world != w {continue}
		delay :=
			kind.item.owner_delay if int(entity_owner(w, ent).client) == int(player_id(s, c)) else kind.item.pickup_delay
		if f32(entity_age_of(w, ent)) * game.TICK_SECONDS < delay {continue}
		d := c.player.position + {0, 0.5, 0} - entity_pos(w, ent)
		if d.x * d.x + d.y * d.y + d.z * d.z > f64(kind.item.range * kind.item.range) {continue}
		if g := &s.config.game; g.picking != nil {
			switch g.picking(s, c, entity_stack(w, ent)^) {
			case .Take:
			case .Leave:
				continue
			case .Taken:
				// The game took it its own way (a purse, a potion drunk): gone.
				record(
					s,
					c,
					.Item_Picked,
					game.item_name(s.registry, entity_stack(w, ent)^.item),
					i64(entity_stack(w, ent)^.count),
				)
				ledger_stack(s, w, .Game, entity_stack(w, ent)^, -1)
				return true
			}
		}
		left := game.inventory_add(s.registry, &c.inventory, entity_stack(w, ent)^)
		if left.count == entity_stack(w, ent)^.count {continue} 	// no room
		record(
			s,
			c,
			.Item_Picked,
			game.item_name(s.registry, entity_stack(w, ent)^.item),
			i64(entity_stack(w, ent)^.count - left.count),
		)
		entity_stack(w, ent)^ = left
		c.inv_changed = true
		if game.stack_empty(left) {return true}
	}
	return false
}

// --- A game's ---

// The inventory as a game handles it: a currency (coins as an item), what a player
// buys, a kit taken away. Each counts what it did; the ledger books it as the game's.

// item_count: how much of item c carries in its slots (not in its hand's cursor, not
// worn).
item_count :: proc(c: ^Client, item: game.Item) -> int {
	n := 0
	for st in c.inventory.slots {
		if st.item == item && !game.stack_empty(st) {n += st.count}
	}
	return n
}

// item_give: count of item into c's slots, as stacks fit (the hotbar first); how
// many went in (the rest found no room and is not given).
item_give :: proc(s: ^Server, c: ^Client, item: game.Item, count: int) -> (given: int) {
	if item == game.NO_ITEM || count <= 0 || game.item_stack_size(s.registry, item) <= 0 {return}
	size := game.item_stack_size(s.registry, item)
	for given < count {
		want := min(count - given, size)
		rest := game.inventory_add(
			s.registry,
			&c.inventory,
			{item, want, game.new_ammo(s.registry, item, c.mode), 0},
		)
		given += want - rest.count
		if rest.count > 0 {break}
	}
	if given > 0 {
		ledger(s, c.world, .Game, item, given)
		c.inv_changed = true
	}
	return
}

// Pickup: what a game's picking hook makes of a stack a player walks over.
Pickup :: enum u8 {
	Take, // into its inventory, as the engine does (as far as there is room)
	Leave, // it stays where it lies (not this player's, not now)
	Taken, // the game took it its own way (coins into a purse, a potion drunk): gone
}

// item_drop: the game drops a stack into the world at position (loot, a chest's
// spill), with its game data (Stack.data: a rolled stat, a rarity); it hops up a
// little, lies there for its kind's life, and the first player to walk over it picks
// it up (the game's picking hook may decide). Booked in the ledger as the game's. 0:
// the world is full.
item_drop :: proc(
	s: ^Server,
	w: ^World,
	position: [3]f64,
	stack: game.Stack,
) -> game.Entity_Handle {
	if game.stack_empty(stack) {return 0}
	st := stack
	st.count = min(st.count, game.item_stack_size(s.registry, st.item))
	if st.ammo == 0 {st.ammo = game.new_ammo(s.registry, st.item)}
	ledger_stack(s, w, .Game, st)
	return spawn_item(w, position, st, {0, 3, 0}, -1)
}

// item_take: up to count of item out of c's slots; how many it took.
item_take :: proc(s: ^Server, c: ^Client, item: game.Item, count: int) -> (taken: int) {
	if item == game.NO_ITEM || count <= 0 {return}
	taken = game.inventory_remove(&c.inventory, item, count)
	if taken > 0 {
		ledger(s, c.world, .Game, item, -taken)
		c.inv_changed = true
	}
	return
}

// item_spend: c spends count of an item it carries on a use (fed to a creature): taken
// and booked as used, unless its mode gives without end (it keeps them). False when it
// carries fewer, and nothing is taken.
item_spend :: proc(s: ^Server, c: ^Client, item: game.Item, count := 1) -> bool {
	if item == game.NO_ITEM ||
	   count <= 0 ||
	   game.inventory_count(&c.inventory, item) < count {return false}
	if has_ability(s, c, .Infinite_Items) {return true}
	game.inventory_remove(&c.inventory, item, count)
	ledger(s, c.world, .Use, item, -count)
	c.inv_changed = true
	return true
}

// inventory_set_aside: c's whole inventory (its slots, what it wears, the cursor's stack) is
// set aside and c holds nothing; false, and nothing changes, if one is set aside already (one
// at a time). What is set aside is kept with c's character and saved with it, untouched by
// death, until inventory_give_back. The hotbar slot in hand stays as it was.
inventory_set_aside :: proc(s: ^Server, c: ^Client) -> bool {
	if _, held := c.aside.?; held {return false}
	c.aside = game.Inventory {
		slots     = c.inventory.slots,
		equipment = c.inventory.equipment,
		cursor    = c.inventory.cursor,
	}
	c.inventory.slots, c.inventory.equipment, c.inventory.cursor = {}, {}, {}
	c.inv_changed = true
	return true
}

// inventory_give_back: the inventory set aside (inventory_set_aside) is c's again, in the
// slots it was in; what c holds now is gone, booked in the item ledger as the game's (what
// comes back was neither made nor lost). False, and nothing changes, if none is set aside.
inventory_give_back :: proc(s: ^Server, c: ^Client) -> bool {
	aside, held := c.aside.?
	if !held {return false}
	ledger_inventory(s, c.world, .Game, &c.inventory)
	c.inventory.slots, c.inventory.equipment, c.inventory.cursor =
		aside.slots, aside.equipment, aside.cursor
	c.aside = nil
	c.inv_changed = true
	return true
}

// item_clear: all of item out of c's slots; how many there were.
item_clear :: proc(s: ^Server, c: ^Client, item: game.Item) -> int {
	return item_take(s, c, item, max(int))
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
			rest := game.inventory_add(s.registry, &to.inventory, {item, min(left, size), 0, 0})
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
		ledger_stack(
			s,
			who.world,
			.Clear,
			{st.item, st.count - who.inventory.slots[i].count, 0, 0},
			-1,
		)
	}
	ledger_stack(
		s,
		who.world,
		.Clear,
		{before.cursor.item, before.cursor.count - who.inventory.cursor.count, 0, 0},
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
