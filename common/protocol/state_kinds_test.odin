package protocol

import "common:game"
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
	s := game_schema(allocator = context.temp_allocator)
	l: Link
	link_init(&l, &s)
	defer link_destroy(&l)

	// Player_Update
	own := Own_Player {
		acked = 9,
		state = {
			position = {1, 2, 3},
			velocity = {4, -5, 6},
			on_ground = true,
			crouched = true,
			jump_held = true,
			air_jumps = 2,
		},
		teleports = 3,
		yaw = 1,
		pitch = -1,
	}
	round_trip(t, &l, .Own_Player, {}, &own)
	// Rules_Changed (the receiver holds the world's rules from its Welcome)
	rules := game.RULES_DEFAULTS
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
		{game.item_of_armor(.Cap), game.NO_ITEM, game.NO_ITEM, game.item_of_armor(.Boots)},
		game.NO_ITEM,
		7,
		3,
	}
	round_trip(t, &l, .Player, key_player(7), &record)
	tally := Tally{12, 4}
	round_trip(t, &l, .Tally, {}, &tally)
	motion := Player_Motion{{1.5, -60, 2e6}, 1, -0.5, true, true}
	round_trip(t, &l, .Player_Motion, key_player(4), &motion)
	// Entity_Spawn, Entities
	sheep := Entity_Record{game.test_reg().engine.sheep, {}, 3, 4}
	round_trip(t, &l, .Entity, key_entity(77), &sheep)
	dropped := Entity_Record {
		game.test_reg().engine.item,
		{game.item_of_block(game.test_reg(), .Sand), 12, 0, 0},
		1,
		1,
	}
	round_trip(t, &l, .Entity, key_entity(78), &dropped)
	moving := Entity_Motion{{1, 2, 3}, 0.5, -0.2, 0b0110}
	round_trip(t, &l, .Entity_Motion, key_entity(77), &moving)
	// Inventory_Update, with a chest
	inv: game.Inventory
	game.inventory_add(
		game.test_reg(),
		&inv,
		{game.item_of_block(game.test_reg(), .Stone), 100, 0, 0},
	)
	inv.cursor = {game.item_of_tool(.Launcher), 1, 0, 0}
	inv.selected = 3
	inv.equipment[.Head] = {game.item_of_armor(.Cap), 1, 0, 0}
	inv.equipment[.Offhand] = {game.item_of_block(game.test_reg(), .Dirt), 12, 0, 0}
	inv.chest_open = true
	inv.chest[0] = {game.item_of_block(game.test_reg(), .Stone), 7, 0, 0}
	inv.chest[24] = {game.item_of_block(game.test_reg(), .Dirt), 64, 0, 0}
	pistol, _ := game.registry_item(game.test_reg(), "pistol")
	inv.slots[4] = {pistol, 1, 7, 0} // (a weapon's magazine goes with its stack)
	state := Inventory_State{5, inv}
	round_trip(t, &l, .Inventory, {}, &state)
	// Health
	health := Health{13.5, 24, false}
	round_trip(t, &l, .Health, {}, &health)
	// Grants, Variables, Selection
	grants := Grants{"1 chat.*\n0 -chat.format\n", "spawn mute"}
	round_trip(t, &l, .Grants, {}, &grants)
	variables := Variables{"worldgen.sea_level = 4\n"}
	round_trip(t, &l, .Variables, {}, &variables)
	selection := Selection{{game.Block_Pos{1, 2, 3}, nil}}
	round_trip(t, &l, .Selection, {}, &selection)
	island := Island{3, 441}
	round_trip(t, &l, .Island, {}, &island)
	place := Place{8, -20, 100}
	round_trip(t, &l, .Place, {}, &place)
	// Block_Changed (heard), Blocks_Changed (quiet)
	heard := Block_Record{u16(game.Block.Gravel), true}
	round_trip(t, &l, .Block, key_of_block({1, 2, 3}), &heard)
	quiet := Block_Record{u16(game.Block.Water_3), false}
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
	s := game_schema(allocator = context.temp_allocator)
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
	rules := game.RULES_DEFAULTS
	rules.gravity = 1e6
	refuse(t, &s, .Rules, {}, &rules, "rules out of range")
	early := Clock{-1, 0}
	refuse(t, &s, .Clock, {}, &early, "negative time")
	nan := Clock{transmute(f64)u64(0x7ff8000000000001), 0}
	refuse(t, &s, .Clock, {}, &nan, "time NaN")
	bad_name := Player_Record{"bad name", {}, game.NO_ITEM, 0, 0}
	refuse(t, &s, .Player, key_player(1), &bad_name, "a name with a space")
	not_item := Player_Record{"ok", {game.Item(0x7fff), 0, 0, 0}, game.NO_ITEM, 0, 0}
	refuse(t, &s, .Player, key_player(1), &not_item, "an item that does not exist")
	health := Health{30, 24, false}
	refuse(t, &s, .Health, {}, &health, "health above the maximum")
	bad := Inventory_State{5, {}}
	bad.inventory.slots[0] = {game.item_of_block(game.test_reg(), .Stone), 65, 0, 0} // more than a stack
	refuse(t, &s, .Inventory, {}, &bad, "more than a stack")
	feet := Inventory_State{5, {}}
	feet.inventory.equipment[.Feet] = {game.item_of_armor(.Cap), 1, 0, 0} // a cap on the feet
	refuse(t, &s, .Inventory, {}, &feet, "a cap on the feet")
	far := Selection{{game.Block_Pos{1 << 28, 0, 0}, nil}}
	refuse(t, &s, .Selection, {}, &far, "a corner outside the world")
	far_biome := Place{254, 0, 0}
	refuse(t, &s, .Place, {}, &far_biome, "a biome that does not exist")
	hot := Place{4, 101, 0}
	refuse(t, &s, .Place, {}, &hot, "warmth 101")
	boom := Explosion{{1, 2, 3}, 1000}
	refuse_event(t, &s, .Explosion, &boom, "an explosion of radius 1000")
	kind_gap := Entity_Record{game.Kind_Id(200), {}, 0, 0}
	refuse(t, &s, .Entity, key_entity(1), &kind_gap, "an entity kind that does not exist")
	// (Entity_Motion.looks holds 16 bits and a record cannot know its kind: every value is
	// well formed, and the client drops a bit past its kind's looks.)
	far_look := Entity_Motion {
		position = {1 << 40, 0, 0},
	}
	refuse(t, &s, .Entity_Motion, key_entity(1), &far_look, "an entity outside the world")
}

// A game's kinds (Game_Kinds) follow the engine's: the engine's keep their ids, the
// schema hash covers the game's (the engine's hash alone does not change), a game's kind
// is found by its value type, and its records and events cross the wire as the engine's.
@(test)
test_game_kinds :: proc(t: ^testing.T) {
	Score :: struct {
		points: u32,
		team:   u8,
	}
	Tagged :: struct {
		who: string `net:"max=16"`,
	}
	Lap :: struct {
		ticks: u64,
	}
	KINDS :: Game_Kinds {
		states = {
			{name = "tag.score", value = Score},
			{name = "tag.lap", value = Lap, key = .Player, max_records = game.MAX_PLAYERS},
		},
		events = {{name = "tag.tagged", value = Tagged}},
	}
	engine := game_schema(allocator = context.temp_allocator)
	s := game_schema("tag", KINDS, context.temp_allocator)
	testing.expect_value(t, s.engine, len(State_Kind) + len(Event_Kind))
	testing.expect_value(t, len(s.kinds), s.engine + 3)
	for k, i in engine.kinds {
		testing.expectf(t, s.kinds[i].name == k.name, "the engine's kind %s moved", k.name)
	}
	testing.expect(t, s.hash != engine.hash, "the game's kinds are not in the hash")
	testing.expect_value(t, s.engine_hash, engine.hash)
	testing.expect_value(t, engine.engine_hash, engine.hash)
	other := game_schema(
		"tag",
		{states = {{name = "tag.score", value = Lap}}},
		context.temp_allocator,
	)
	testing.expect(t, other.hash != s.hash, "a kind's value type is not in the hash")

	score, found := game_kind(&s, Score)
	testing.expect(t, found && score == s.engine && !s.kinds[score].is_event)
	tagged, found_event := game_kind(&s, Tagged)
	testing.expect(t, found_event && tagged == s.engine + 2 && s.kinds[tagged].is_event)
	_, found = game_kind(&engine, Score)
	testing.expect(t, !found, "a game's kind in a schema without the game")
	_, found = game_kind(&s, Clock)
	testing.expect(t, !found, "an engine kind found as a game's")

	// Two kinds of a game with one value type: the type would not name the kind.
	_, err := schema_make(
		{},
		{},
		{states = {{name = "tag.a", value = Score}}, events = {{name = "tag.b", value = Score}}},
		context.temp_allocator,
	)
	testing.expect_value(t, err.reason, "a game's kinds have a value type each")

	l: Link
	link_init(&l, &s)
	defer link_destroy(&l)
	points := Score{12, 2}
	sender_put(&l.tx, score, {}, &points)
	lap := game_kind(&s, Lap) or_else -1
	laps := [2]Lap{{30}, {60}}
	sender_put(&l.tx, lap, key_player(1), &laps[0])
	sender_put(&l.tx, lap, key_player(2), &laps[1])
	who := Tagged{"Steve_1"}
	sender_event(&l.tx, tagged, &who)
	link_step(&l)
	if !testing.expect(t, !l.failed, "the receiver refused a game's kinds") {return}
	got := (^Score)(replica_get(&l.view, score, {}))
	testing.expect(t, got != nil && got^ == points)
	for want, i in laps {
		lap_got := (^Lap)(replica_get(&l.view, lap, key_player(u16(i + 1))))
		testing.expect(t, lap_got != nil && lap_got^ == want)
	}
	if testing.expect_value(t, len(l.events), 1) {
		testing.expect_value(t, l.events[0].kind, tagged)
		testing.expect_value(t, (^Tagged)(l.events[0].value).who, "Steve_1")
	}

	// A receiver without the game knows none of its kinds: such a message is malformed.
	bare: Receiver
	receiver_init(&bare, &engine, game.test_reg())
	defer receiver_destroy(&bare)
	sender_put(&l.tx, score, {}, &Score{13, 2})
	clear(&l.messages)
	sender_flush(&l.tx, 9, {}, &l.messages)
	out := make([dynamic]Received, context.temp_allocator)
	testing.expect(t, len(l.messages) == 1 && !receive_state(&bare, l.messages[0].data, &out))
}

// A game's requests: in the schema (and its hash) after its events, found by their value
// type only as requests; a value goes through its encoding and back whole, checked; a
// value that does not decode whole, or that its check refuses, or a kind that is not a
// request, is refused; and a server never sends one.
@(test)
test_game_requests :: proc(t: ^testing.T) {
	Build :: struct {
		kind:     u8,
		at:       [2]i16,
		rotation: u8,
	}
	Shout :: struct {
		text: string `net:"max=8"`,
	}
	Score :: struct {
		points: u32,
	}
	check_build :: proc(reg: ^game.Registry, v: rawptr) -> bool {return (^Build)(v).rotation < 4}
	KINDS :: Game_Kinds {
		states   = {{name = "town.score", value = Score}},
		requests = {
			{name = "town.build", value = Build, check = check_build},
			{name = "town.shout", value = Shout},
		},
	}
	without := game_schema("town", {states = KINDS.states}, context.temp_allocator)
	s := game_schema("town", KINDS, context.temp_allocator)
	testing.expect(t, s.hash != without.hash, "the requests are not in the hash")
	build, found := request_kind(&s, Build)
	testing.expect(t, found && s.kinds[build].is_request && s.kinds[build].is_event)
	_, found = request_kind(&s, Score)
	testing.expect(t, !found, "a record found as a request")

	w: game.Writer
	game.writer_init(&w, context.temp_allocator)
	b := Build{3, {-40, 95}, 2}
	request_encode(&w, &s, build, &b)
	got, ok := request_decode(&s, game.test_reg(), {u16(build), 0, w.buf[:]})
	if testing.expect(t, ok) {testing.expect_value(t, (^Build)(got)^, b)}
	// Refused: a byte short, a byte over, the check's, a kind that is no request.
	_, ok = request_decode(&s, game.test_reg(), {u16(build), 0, w.buf[:len(w.buf) - 1]})
	testing.expect(t, !ok)
	long := make([]u8, len(w.buf) + 1, context.temp_allocator)
	copy(long, w.buf[:])
	_, ok = request_decode(&s, game.test_reg(), {u16(build), 0, long})
	testing.expect(t, !ok)
	clear(&w.buf)
	bad := Build{3, {0, 0}, 9}
	request_encode(&w, &s, build, &bad)
	_, ok = request_decode(&s, game.test_reg(), {u16(build), 0, w.buf[:]})
	testing.expect(t, !ok, "the kind's check let it through")
	score, _ := game_kind(&s, Score)
	_, ok = request_decode(&s, game.test_reg(), {u16(score), 0, w.buf[:]})
	testing.expect(t, !ok, "a record's kind decoded as a request")
	_, ok = request_decode(&s, game.test_reg(), {u16(len(s.kinds)), 0, w.buf[:]})
	testing.expect(t, !ok)
	shout, _ := request_kind(&s, Shout)
	clear(&w.buf)
	game.write_string(&w, "far too long a shout")
	_, ok = request_decode(&s, game.test_reg(), {u16(shout), 0, w.buf[:]})
	testing.expect(t, !ok, "a string past its limit")

	// On the wire, as a message, within MAX_GAME_REQUEST.
	clear(&w.buf)
	request_encode(&w, &s, build, &b)
	m := Game_Request{u16(build), 77, w.buf[:]}
	enc: game.Writer
	game.writer_init(&enc, context.temp_allocator)
	encode_client(&enc, m)
	back, decoded := decode_client(enc.buf[:])
	if testing.expect(t, decoded) {
		r := back.(Game_Request) or_else {}
		testing.expect_value(t, r.kind, m.kind)
		testing.expect_value(t, r.after, u32(77))
		testing.expect_value(t, string(r.data), string(m.data))
	}
	// (the same message with its length past MAX_GAME_REQUEST: the kind's byte, the kind,
	// after, then the length)
	head := enc.buf[:1 + 2 + 4]
	over: game.Writer
	game.writer_init(&over, context.temp_allocator)
	append(&over.buf, ..head)
	game.write_varint(&over, MAX_GAME_REQUEST + 1)
	for _ in 0 ..= MAX_GAME_REQUEST {game.write_u8(&over, 0)}
	_, decoded = decode_client(over.buf[:])
	testing.expect(t, !decoded, "a request past MAX_GAME_REQUEST")
}

// A kind at its cap may swap records in one message, creating before it removes (a
// nearest-first view at its cap); a message that leaves the kind over its cap is refused.
@(test)
test_record_cap_holds_per_message :: proc(t: ^testing.T) {
	Mark :: struct {
		n: u32,
	}
	KINDS :: Game_Kinds {
		states = {{name = "cap.mark", value = Mark, key = .Entity, max_records = 3}},
	}
	s := game_schema("cap", KINDS, context.temp_allocator)
	kind, _ := game_kind(&s, Mark)
	l: Link
	link_init(&l, &s)
	defer link_destroy(&l)
	put :: proc(l: ^Link, kind: int, ids: []u32) {
		for id in ids {
			m := Mark{id}
			sender_put(&l.tx, kind, key_entity(id), &m)
		}
		link_step(l)
	}
	put(&l, kind, {5, 6, 7})
	testing.expect(t, !l.failed)
	// 5 goes, 1 comes: by key, the create comes first.
	put(&l, kind, {1, 6, 7})
	testing.expect(t, !l.failed, "a swap at the cap was refused")
	testing.expect(t, replica_get(&l.view, kind, key_entity(1)) != nil)
	testing.expect(t, replica_get(&l.view, kind, key_entity(5)) == nil)
}
