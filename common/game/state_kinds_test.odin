package game

import "core:testing"

// The game's own kinds: the 22 messages that moved onto the state model, with
// the values their tests used before, put through records and events.

@(private = "file")
round_trip :: proc(t: ^testing.T, l: ^Link, kind: State_Kind, key: Key, value: ^$T) {
	sender_put(&l.tx, int(kind), key, value)
	link_step(l)
	if !testing.expectf(t, !l.failed, "%v: the receiver refused it", kind) {return}
	k := &l.schema.kinds[int(kind)]
	if k.write_through {
		found := false
		for e in l.events {
			if e.kind == int(kind) &&
			   e.key == key &&
			   value_diff(k, e.value, value) == 0 {found = true}
		}
		testing.expectf(t, found, "%v: the record did not arrive as sent", kind)
		return
	}
	got := replica_get(&l.view, int(kind), key)
	if !testing.expectf(t, got != nil, "%v: no record arrived", kind) {return}
	testing.expectf(
		t,
		value_diff(k, got, value) == 0,
		"%v: the record differs from what was sent",
		kind,
	)
}

@(private = "file")
event_round_trip :: proc(t: ^testing.T, l: ^Link, kind: Event_Kind, value: ^$T) {
	sender_event(&l.tx, kind_of_event(kind), value)
	link_step(l)
	if !testing.expectf(t, !l.failed, "%v: the receiver refused it", kind) {return}
	if !testing.expectf(t, len(l.events) == 1, "%v: %d events", kind, len(l.events)) {return}
	k := &l.schema.kinds[kind_of_event(kind)]
	testing.expectf(t, l.events[0].kind == kind_of_event(kind), "%v: the wrong kind", kind)
	testing.expectf(t, value_diff(k, l.events[0].value, value) == 0, "%v: the event differs", kind)
}

// The values of the old per-message tests, as records and events: Player_Update,
// Players, Entities, Entity_Spawn, Entity_Despawn, Entity_Hurt, Explosion,
// Health, Inventory_Update, Player_Worn, Player_Joined, Player_Left,
// Rules_Changed, Time, Grants, Variables, Selection, Notice, Chat_Line,
// Chat_Delete, Block_Changed, Blocks_Changed.
@(test)
test_every_moved_message_round_trips :: proc(t: ^testing.T) {
	s := game_schema(context.temp_allocator)
	l: Link
	link_init(&l, &s)
	defer link_destroy(&l)

	// Player_Update
	own := Own_Player {
		acked     = 9,
		state     = {{1, 2, 3}, {4, -5, 6}, true, false, true, true, 2},
		teleports = 3,
		yaw       = 1,
		pitch     = -1,
	}
	round_trip(t, &l, .Own_Player, {}, &own)
	// Rules_Changed (the receiver holds the world's rules from its Welcome)
	rules := RULES_DEFAULTS
	sender_seed(&l.tx, int(State_Kind.Rules), &rules)
	receiver_seed(&l.rx, int(State_Kind.Rules), &rules)
	rules.gravity, rules.allow_flying = 12.5, false
	round_trip(t, &l, .Rules, {}, &rules)
	// Time
	clock := Clock{12345.678, 77}
	round_trip(t, &l, .Clock, {}, &clock)
	// Player_Joined, Player_Worn, Players
	record := Player_Record {
		"bob_the-builder",
		{item_of_armor(.Cap), NO_ITEM, NO_ITEM, item_of_armor(.Boots)},
	}
	round_trip(t, &l, .Player, key_player(7), &record)
	motion := Player_Motion{{1.5, -60, 2e6}, 1, -0.5, true, true}
	round_trip(t, &l, .Player_Motion, key_player(4), &motion)
	// Entity_Spawn, Entities
	sheep := Entity_Record{.Sheep, {}}
	round_trip(t, &l, .Entity, key_entity(77), &sheep)
	dropped := Entity_Record{.Item, {item_of_block(.Sand), 12}}
	round_trip(t, &l, .Entity, key_entity(78), &dropped)
	moving := Entity_Motion{{1, 2, 3}, 0.5, -0.2, {.Lamb, .Black}}
	round_trip(t, &l, .Entity_Motion, key_entity(77), &moving)
	// Inventory_Update, with a chest
	inv: Inventory
	inventory_add(&inv, {item_of_block(.Stone), 100})
	inv.cursor = {item_of_tool(.Launcher), 1}
	inv.selected = 3
	inv.equipment[.Head] = {item_of_armor(.Cap), 1}
	inv.equipment[.Offhand] = {item_of_block(.Dirt), 12}
	inv.chest_open = true
	inv.chest[0] = {item_of_block(.Stone), 7}
	inv.chest[24] = {item_of_block(.Dirt), 64}
	state := Inventory_State{5, inv}
	round_trip(t, &l, .Inventory, {}, &state)
	// Health
	health := Health{13.5, 24}
	round_trip(t, &l, .Health, {}, &health)
	// Grants, Variables, Selection
	grants := Grants{"1 chat.*\n0 -chat.format\n", "spawn mute"}
	round_trip(t, &l, .Grants, {}, &grants)
	variables := Variables{"worldgen.sea_level = 4\n"}
	round_trip(t, &l, .Variables, {}, &variables)
	selection := Selection{{Block_Pos{1, 2, 3}, nil}}
	round_trip(t, &l, .Selection, {}, &selection)
	place := Place{8, -20, 100}
	round_trip(t, &l, .Place, {}, &place)
	// Block_Changed (heard), Blocks_Changed (quiet)
	heard := Block_Record{.Gravel, true}
	round_trip(t, &l, .Block, key_of_block({1, 2, 3}), &heard)
	quiet := Block_Record{.Water_3, false}
	round_trip(t, &l, .Block, key_of_block({-2 * 16 + 7, 3 * 16, 4 * 16 + 5}), &quiet)

	// Entity_Despawn: the removal of its records (the death is an event, below)
	link_step(&l) // (nothing is put: every keyed record is removed)
	testing.expect(t, !l.failed, "the removals were refused")
	testing.expect_value(t, len(l.rx.live.tables[int(State_Kind.Entity)].records), 0)
	testing.expect_value(t, len(l.view.tables[int(State_Kind.Entity)].records), 0)
	// Notice, Chat_Line, Chat_Delete, Entity_Hurt, Entity_Died, Explosion
	notice := Notice{"Open to LAN on port 27315"}
	event_round_trip(t, &l, .Notice, &notice)
	chat := Chat_Line{7, NO_PLAYER, "&eBea joined"}
	event_round_trip(t, &l, .Chat_Line, &chat)
	deleted := Chat_Delete{7}
	event_round_trip(t, &l, .Chat_Delete, &deleted)
	hurt := Entity_Hurt{9}
	event_round_trip(t, &l, .Entity_Hurt, &hurt)
	died := Entity_Died{77}
	event_round_trip(t, &l, .Entity_Died, &died)
	blast := Explosion{{1, 2, 3}, 6}
	event_round_trip(t, &l, .Explosion, &blast)
}

// What the old decoders refused, the kinds' checks refuse.
@(test)
test_kind_checks_refuse :: proc(t: ^testing.T) {
	s := game_schema(context.temp_allocator)
	refuse :: proc(
		t: ^testing.T,
		s: ^Schema,
		kind: State_Kind,
		key: Key,
		value: ^$T,
		what: string,
	) {
		l: Link
		link_init(&l, s)
		defer link_destroy(&l)
		sender_put(&l.tx, int(kind), key, value)
		link_step(&l)
		testing.expectf(t, l.failed, "accepted: %s", what)
	}
	refuse_event :: proc(t: ^testing.T, s: ^Schema, kind: Event_Kind, value: ^$T, what: string) {
		l: Link
		link_init(&l, s)
		defer link_destroy(&l)
		sender_event(&l.tx, kind_of_event(kind), value)
		link_step(&l)
		testing.expectf(t, l.failed, "accepted: %s", what)
	}
	fast := Own_Player {
		state = {velocity = {0, MAX_SPEED * 2, 0}},
	}
	refuse(t, &s, .Own_Player, {}, &fast, "player speed absurd")
	steep := Own_Player {
		pitch = 2,
	}
	refuse(t, &s, .Own_Player, {}, &steep, "looking past straight up")
	rules := RULES_DEFAULTS
	rules.gravity = 1e6
	refuse(t, &s, .Rules, {}, &rules, "rules out of range")
	early := Clock{-1, 0}
	refuse(t, &s, .Clock, {}, &early, "negative time")
	nan := Clock{transmute(f64)u64(0x7ff8000000000001), 0}
	refuse(t, &s, .Clock, {}, &nan, "time NaN")
	bad_name := Player_Record{"bad name", {}}
	refuse(t, &s, .Player, key_player(1), &bad_name, "a name with a space")
	not_item := Player_Record{"ok", {Item(0x7fff), 0, 0, 0}}
	refuse(t, &s, .Player, key_player(1), &not_item, "an item that does not exist")
	health := Health{30, 24}
	refuse(t, &s, .Health, {}, &health, "health above the maximum")
	bad := Inventory_State{5, {}}
	bad.inventory.slots[0] = {item_of_block(.Stone), 65} // more than a stack
	refuse(t, &s, .Inventory, {}, &bad, "more than a stack")
	feet := Inventory_State{5, {}}
	feet.inventory.equipment[.Feet] = {item_of_armor(.Cap), 1} // a cap on the feet
	refuse(t, &s, .Inventory, {}, &feet, "a cap on the feet")
	far := Selection{{Block_Pos{1 << 28, 0, 0}, nil}}
	refuse(t, &s, .Selection, {}, &far, "a corner outside the world")
	far_biome := Place{254, 0, 0}
	refuse(t, &s, .Place, {}, &far_biome, "a biome that does not exist")
	hot := Place{4, 101, 0}
	refuse(t, &s, .Place, {}, &hot, "warmth 101")
	boom := Explosion{{1, 2, 3}, 1000}
	refuse_event(t, &s, .Explosion, &boom, "an explosion of radius 1000")
	kind_gap := Entity_Record{Entity_Kind(200), {}}
	refuse(t, &s, .Entity, key_entity(1), &kind_gap, "an entity kind that does not exist")
	flags := Entity_Motion {
		flags = transmute(Sheep_Flags)u8(0x80),
	}
	refuse(t, &s, .Entity_Motion, key_entity(1), &flags, "a sheep flag that does not exist")
}
