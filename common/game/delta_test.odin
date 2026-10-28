package game

import "core:slice"
import "core:testing"

import "../../base"

// M39's state model, end to end through test kinds of the tests' own: the
// sender's encoder and the receiver's decoder, with no game type involved.

Dt_Motion :: struct {
	position: [3]f64,
	yaw:      f32,
	flags:    u8,
}

Dt_Me :: struct {
	acked: u32 `net:"acked"`,
	x:     f64,
	n:     i32,
}

Dt_Single :: struct {
	n: u32,
}

Dt_Block :: struct {
	block: Block,
	heard: bool,
}

Dt_Ping :: struct {
	text: string `net:"max=16"`,
	n:    u32,
}

Dt_Inv :: struct {
	acked:     u32 `net:"acked"`,
	inventory: Inventory,
}

// the kinds' ids
DT_ALL :: 0
DT_MOTION :: 1
DT_ME :: 2
DT_SINGLE :: 3
DT_BLOCK :: 4
DT_INV :: 5
DT_PING :: 6 // events from here
DT_ALL_EVENT :: 7

@(private = "file")
motion_at :: proc(v: rawptr) -> [3]i32 {
	p := (^Dt_Motion)(v).position
	return {i32(p.x), i32(p.y), i32(p.z)}
}

@(private = "file")
dt_schema :: proc() -> Schema {
	states := []State_Kind_Info {
		{name = "all", value = Sch_All, key = .Entity, max_records = 16},
		{
			name = "motion",
			value = Dt_Motion,
			key = .Entity,
			lane = .Snapshot,
			max_records = 600,
			priority = 2,
			locate = motion_at,
		},
		{name = "me", value = Dt_Me, lane = .Snapshot},
		{name = "single", value = Dt_Single},
		{name = "block", value = Dt_Block, key = .Block, write_through = true},
		{name = "inv", value = Dt_Inv},
	}
	events := []Event_Kind_Info {
		{name = "ping", value = Dt_Ping},
		{name = "all_event", value = Sch_All},
	}
	s, err := schema_make(states, events, context.temp_allocator)
	assert(err.reason == "", schema_error_text(err))
	return s
}

// Link: a sender and a receiver, and a client's view of what it was told.
Link :: struct {
	schema:   ^Schema,
	tx:       Sender,
	rx:       Receiver,
	view:     Replica, // the application's copy: what the receiver yielded
	events:   [dynamic]Received,
	rng:      base.Rng,
	loss:     int, // percent of snapshot parts lost
	lost:     int,
	tick:     u32,
	messages: [dynamic]Outgoing,
	failed:   bool,
	budget:   int, // (unused)
}


link_init :: proc(l: ^Link, schema: ^Schema, loss := 0, seed := u64(7)) {
	l.schema = schema
	sender_init(&l.tx, schema)
	receiver_init(&l.rx, schema, test_reg())
	replica_init(&l.view, schema)
	l.rng = base.rng_make(seed)
	l.loss = loss
	l.events = make([dynamic]Received)
	l.messages = make([dynamic]Outgoing)
}


link_destroy :: proc(l: ^Link) {
	sender_destroy(&l.tx)
	receiver_destroy(&l.rx)
	replica_destroy(&l.view)
	delete(l.events)
	delete(l.messages)
}

// apply: the application's side of what the receiver yielded.

link_apply :: proc(l: ^Link, got: []Received) {
	for g in got {
		switch g.op {
		case .Create, .Change:
			if l.schema.kinds[g.kind].write_through {
				append(&l.events, g)
				continue
			}
			replica_upsert(&l.view, g.kind, g.key, g.value)
		case .Remove:
			if i, found := replica_find(&l.view, g.kind, g.key); found {
				replica_remove_at(&l.view, g.kind, i)
			}
		case .Event:
			append(&l.events, g)
		}
	}
}

// step: one tick. What was put is flushed and delivered (reliable messages
// always, snapshot parts but for the lost ones), and the receiver's
// acknowledgement goes back.

link_step :: proc(l: ^Link, origin := [3]i32{}) -> (reliable_bytes, snapshot_bytes: int) {
	l.tick += 1
	clear(&l.messages)
	clear(&l.events)
	sender_flush(&l.tx, l.tick, origin, &l.messages)
	got := make([dynamic]Received, context.temp_allocator)
	for m in l.messages {
		if m.snapshot {
			snapshot_bytes += len(m.data)
			if l.loss > 0 && base.rng_int_max(&l.rng, 100) < l.loss {
				l.lost += 1
				continue
			}
			if !receive_snapshot(&l.rx, m.data, &got) {l.failed = true}
		} else {
			reliable_bytes += len(m.data)
			if !receive_state(&l.rx, m.data, &got) {l.failed = true}
		}
		link_apply(l, got[:])
		// (events are kept for the test; records' values are views, so copy before the next receive)
		clear(&got)
	}
	sender_ack(&l.tx, l.rx.ack)
	return
}


link_put :: proc(l: ^Link, kind: int, key: u32, value: ^$T) {
	sender_put(&l.tx, kind, Key{a = i32(key)}, value)
}


kinds_equal :: proc(a, b: ^Replica, kind: int) -> bool {
	ta, tb := a.tables[kind].records, b.tables[kind].records
	if len(ta) != len(tb) {return false}
	k := &a.schema.kinds[kind]
	for rec, i in ta {
		if rec.key != tb[i].key || value_diff(k, rec.value, tb[i].value) != 0 {return false}
	}
	return true
}

// ---- reliable lane ----

Gauge_Mode :: enum u8 {
	Off,
	On,
	Auto,
}

Gauge1 :: struct {
	a: i32,
	b: f32,
}

Gauge2 :: struct {
	a:    i32,
	b:    f32,
	c:    [3]f64,
	mode: Gauge_Mode,
}

@(private = "file")
gauge_round_trip :: proc(
	t: ^testing.T,
	value: typeid,
	first, second, third: rawptr,
	mode_alone: bool,
) {
	states := []State_Kind_Info{{name = "gauge", value = value}}
	s, err := schema_make(states, nil, context.temp_allocator)
	if !testing.expect(t, err.reason == "", schema_error_text(err)) {return}
	l: Link
	link_init(&l, &s)
	defer link_destroy(&l)
	k := &s.kinds[0]

	sender_put(&l.tx, 0, {}, first)
	link_step(&l)
	testing.expect(t, !l.failed, "create failed")
	got := replica_get(&l.rx.live, 0, {})
	if testing.expect(t, got != nil, "the record was not created") {
		testing.expect(t, value_diff(k, got, first) == 0, "the created record differs")
	}

	sender_put(&l.tx, 0, {}, second)
	bytes, _ := link_step(&l)
	got = replica_get(&l.rx.live, 0, {})
	testing.expect(t, !l.failed, "change failed")
	testing.expect(t, got != nil && value_diff(k, got, second) == 0, "the changed record differs")
	if mode_alone {
		// kind, tick, group id, count, head, the one byte of `mode`
		testing.expect_value(t, bytes, 6)
	}

	sender_put(&l.tx, 0, {}, third)
	link_step(&l)
	got = replica_get(&l.rx.live, 0, {})
	testing.expect(
		t,
		!l.failed && got != nil && value_diff(k, got, third) == 0,
		"the third value differs",
	)

	sender_remove(&l.tx, 0, {})
	link_step(&l)
	testing.expect(t, !l.failed, "removal failed")
	testing.expect(t, replica_get(&l.rx.live, 0, {}) == nil, "the record was not removed")
}

// A new replicated field needs no protocol code: Gauge has two fields in one
// schema and four in the other, and both round-trip through the same encoder
// and decoder with nothing written for either.
@(test)
test_new_field_needs_no_code :: proc(t: ^testing.T) {
	a1 := Gauge1{1, 1.5}
	a2 := Gauge1{-70000, -0.0}
	a3 := Gauge1{-69999, 3}
	gauge_round_trip(t, Gauge1, &a1, &a2, &a3, false)

	b1 := Gauge2{1, 1.5, {1, 2, 3}, .Off}
	b2 := b1
	b2.mode = .Auto // one byte: head and the mode
	b3 := Gauge2{5, 2, {-1e9, 0.25, 7}, .On}
	gauge_round_trip(t, Gauge2, &b1, &b2, &b3, true)

	s1, _ := schema_make({{name = "gauge", value = Gauge1}}, nil, context.temp_allocator)
	s2, _ := schema_make({{name = "gauge", value = Gauge2}}, nil, context.temp_allocator)
	testing.expect(t, schema_hash(&s1) != schema_hash(&s2), "the two schemas hash alike")
}

@(private = "file")
random_all :: proc(rng: ^base.Rng, v: ^Sch_All, names: []string) {
	switch base.rng_int_max(rng, 17) {
	case 0:
		v.flag = !v.flag
	case 1:
		v.a = u8(base.rng_u32(rng))
	case 2:
		v.b = u16(base.rng_u32(rng))
	case 3:
		v.c = base.rng_u32(rng) if base.rng_int_max(rng, 2) == 0 else v.c + 3
	case 4:
		v.d =
			base.rng_u64(rng) if base.rng_int_max(rng, 2) == 0 else max(u64) - u64(base.rng_int_max(rng, 5))
	case 5:
		v.e = i32(base.rng_u32(rng))
	case 6:
		v.f =
			int(i64(base.rng_u64(rng))) if base.rng_int_max(rng, 3) == 0 else base.rng_int_range(rng, -50, 50)
	case 7:
		v.g = base.rng_f32_range(rng, -1000, 1000)
	case 8:
		v.h = base.rng_f64_range(rng, -1e6, 1e6)
	case 9:
		modes := [?]Sch_Mode{.A, .B, .C}
		v.mode = modes[base.rng_int_max(rng, 3)]
	case 10:
		v.flags = transmute(Sch_Flags)(u8(base.rng_u32(rng)) & 0b100101)
	case 11:
		v.pos[base.rng_int_max(rng, 3)] = base.rng_f64_range(rng, -100, 100)
	case 12:
		v.stack[base.rng_int_max(rng, 4)] = {
			Item(base.rng_int_max(rng, 300)),
			base.rng_int_range(rng, 0, 99),
		}
	case 13:
		v.worn[Equip_Slot(base.rng_int_max(rng, len(Equip_Slot)))] = {
			Item(base.rng_int_max(rng, 300)),
			base.rng_int_range(rng, 0, 99),
		}
	case 14:
		v.inner = {i32(base.rng_u32(rng)), base.rng_f32(rng)}
	case 15:
		v.name = names[base.rng_int_max(rng, len(names))]
	case 16:
		v.spot =
			nil if base.rng_int_max(rng, 3) == 0 else Block_Pos{i32(base.rng_int_range(rng, -50, 50)), 3, 4}
	}
}

@(test)
test_every_field_type_round_trips :: proc(t: ^testing.T) {
	s := dt_schema()
	l: Link
	link_init(&l, &s)
	defer link_destroy(&l)
	rng := base.rng_make(11)
	names := []string{"", "a", "zeta", "twelve ch"[:8]}
	values: [4]Sch_All
	for tick in 0 ..< 1000 {
		for &v, i in values {
			if base.rng_int_max(&rng, 3) == 0 {random_all(&rng, &v, names)}
			if tick > 400 && i == 3 {continue} 	// (this one stops being put: removed)
			link_put(&l, DT_ALL, u32(i + 1), &v)
		}
		link_step(&l)
		if !testing.expectf(t, !l.failed, "tick %d: the receiver refused a message", tick) {return}
		if !kinds_equal(&l.tx.sent, &l.rx.live, DT_ALL) {
			testing.expectf(
				t,
				false,
				"tick %d: the receiver's records differ from the sender's",
				tick,
			)
			return
		}
	}
	testing.expect_value(t, len(l.rx.live.tables[DT_ALL].records), 3)
}

@(test)
test_events_carry_every_field :: proc(t: ^testing.T) {
	s := dt_schema()
	l: Link
	link_init(&l, &s)
	defer link_destroy(&l)
	ev := Sch_All {
		flag  = true,
		d     = max(u64),
		f     = -5,
		h     = -0.0,
		mode  = .C,
		flags = {.A, .C},
		name  = "boom",
		spot  = Block_Pos{1, -2, 3},
	}
	ev.worn[.Head] = {4, 1}
	ping := Dt_Ping{"hello", 77}
	sender_event(&l.tx, DT_ALL_EVENT, &ev)
	sender_event(&l.tx, DT_PING, &ping)
	sender_event(&l.tx, DT_PING, &ping)
	link_step(&l)
	if !testing.expect_value(t, len(l.events), 3) {return}
	k := &s.kinds[DT_ALL_EVENT]
	testing.expect(t, value_diff(k, l.events[0].value, &ev) == 0, "the event's value differs")
	testing.expect_value(t, (^Dt_Ping)(l.events[1].value).text, "hello")
	testing.expect_value(t, (^Dt_Ping)(l.events[2].value).n, 77)
	testing.expect_value(t, l.events[0].kind, DT_ALL_EVENT)
}

@(test)
test_costs :: proc(t: ^testing.T) {
	s := dt_schema()
	l: Link
	link_init(&l, &s)
	defer link_destroy(&l)

	// `acked` one input on is one byte
	me := Dt_Me {
		acked = 100,
		x     = 1.5,
		n     = 3,
	}
	sender_put(&l.tx, DT_ME, {}, &me)
	link_step(&l)
	me.acked = 101
	sender_put(&l.tx, DT_ME, {}, &me)
	_, snap := link_step(&l)
	// kind, tick, back, part, parts, id, count, head, acked
	testing.expect_value(t, snap, 9)

	// one stack that changed is under 8 bytes
	inv := Dt_Inv {
		acked = 1,
	}
	inv.inventory.slots[3] = {5, 20}
	sender_put(&l.tx, DT_INV, {}, &inv)
	link_step(&l)
	inv.inventory.slots[4] = {5, 20}
	sender_put(&l.tx, DT_INV, {}, &inv)
	bytes, _ := link_step(&l)
	// kind, tick, id, count, then the entry
	testing.expectf(t, bytes - 4 < 8, "a moved stack cost %d bytes", bytes - 4)

	// 64 blocks of one chunk: a few bytes each, one group header
	for i in 0 ..< 64 {
		b := Dt_Block{.Stone, false}
		sender_put(&l.tx, DT_BLOCK, key_of_block({i32(i % 16) + 32, i32(i / 16) + 5, 40}), &b)
	}
	bytes, _ = link_step(&l)
	testing.expectf(t, bytes <= 64 * 5 + 8, "64 blocks cost %d bytes", bytes)
}

@(test)
test_reliable_lane_rules :: proc(t: ^testing.T) {
	s := dt_schema()
	l: Link
	link_init(&l, &s)
	defer link_destroy(&l)

	// puts coalesce within a tick (the last wins), and an unchanged put sends nothing
	one := Dt_Single{1}
	two := Dt_Single{2}
	sender_put(&l.tx, DT_SINGLE, {}, &one)
	sender_put(&l.tx, DT_SINGLE, {}, &two)
	link_step(&l)
	got := (^Dt_Single)(replica_get(&l.rx.live, DT_SINGLE, {}))
	if !testing.expect(t, got != nil) {return}
	testing.expect_value(t, got.n, 2)
	sender_put(&l.tx, DT_SINGLE, {}, &two)
	reliable, _ := link_step(&l)
	testing.expect_value(t, reliable, 0)
	reliable, _ = link_step(&l) // (nothing put: a singleton persists)
	testing.expect_value(t, reliable, 0)
	testing.expect(t, replica_get(&l.rx.live, DT_SINGLE, {}) != nil, "a singleton must persist")

	// keyed kinds are views: not put, removed
	a := Sch_All {
		a = 1,
	}
	link_put(&l, DT_ALL, 5, &a)
	link_put(&l, DT_ALL, 9, &a)
	link_step(&l)
	testing.expect_value(t, len(l.rx.live.tables[DT_ALL].records), 2)
	link_put(&l, DT_ALL, 9, &a)
	link_step(&l)
	testing.expect_value(t, len(l.rx.live.tables[DT_ALL].records), 1)

	// the order: creates and changes, then events, then removals
	b := Sch_All {
		a = 2,
	}
	link_put(&l, DT_ALL, 12, &b) // created, 9 removed
	ping := Dt_Ping{"x", 1}
	sender_event(&l.tx, DT_PING, &ping)
	clear(&l.messages)
	sender_flush(&l.tx, 99, {}, &l.messages)
	got_all := make([dynamic]Received, context.temp_allocator)
	for m in l.messages {testing.expect(t, receive_state(&l.rx, m.data, &got_all))}
	ops: [dynamic]Op
	defer delete(ops)
	for g in got_all {append(&ops, g.op)}
	testing.expect(
		t,
		slice.equal(ops[:], []Op{.Create, .Event, .Remove}),
		"creates, events, removals in that order",
	)
}

// ---- snapshot lane ----

@(private = "file")
walk_motion :: proc(rng: ^base.Rng, m: ^Dt_Motion) {
	if base.rng_int_max(rng, 2) == 0 {
		m.position.x += base.rng_f64_range(rng, -1, 1)
		m.position.z += base.rng_f64_range(rng, -1, 1)
		m.yaw = base.rng_f32(rng)
	}
}

@(test)
test_snapshot_lane_survives_loss :: proc(t: ^testing.T) {
	s := dt_schema()
	l: Link
	link_init(&l, &s, loss = 20)
	defer link_destroy(&l)
	rng := base.rng_make(5)
	motions: [60]Dt_Motion
	for &m, i in motions {m.position = {f64(i), 3, f64(i % 7)}}
	me := Dt_Me{}
	last_loss := 0
	max_lag := 0
	for tick in 0 ..< 300 {
		me.acked += 1
		me.x += 0.1
		sender_put(&l.tx, DT_ME, {}, &me)
		for &m, i in motions {
			walk_motion(&rng, &m)
			link_put(&l, DT_MOTION, u32(i + 1), &m)
		}
		before := l.lost
		link_step(&l)
		if l.lost != before {last_loss = tick}
		if !testing.expectf(t, !l.failed, "tick %d: a snapshot part was refused", tick) {return}
		if !kinds_equal(&l.tx.cur, &l.view, DT_MOTION) {max_lag = tick - last_loss}
	}
	// after the loss stops, the view converges within a couple of ticks
	for _ in 0 ..< 3 {
		sender_put(&l.tx, DT_ME, {}, &me)
		for &m, i in motions {link_put(&l, DT_MOTION, u32(i + 1), &m)}
		link_step(&l)
	}
	testing.expect(t, l.lost > 5, "the link lost nothing")
	testing.expect(t, kinds_equal(&l.tx.cur, &l.view, DT_MOTION), "the view never caught up")
	testing.expect(t, kinds_equal(&l.tx.cur, &l.view, DT_ME), "the singleton never caught up")
	_ = max_lag
}

@(test)
test_snapshot_part_lost_applies_in_part :: proc(t: ^testing.T) {
	s := dt_schema()
	l: Link
	link_init(&l, &s)
	defer link_destroy(&l)
	// 200 records change every tick: a snapshot is several parts
	motions: [200]Dt_Motion
	for &m, i in motions {m.position = {f64(i), 3, 0}}
	tick :: proc(l: ^Link, motions: []Dt_Motion, drop_part: int) -> bool {
		for &m, i in motions {
			m.position.x += 0.5
			link_put(l, DT_MOTION, u32(i + 1), &m)
		}
		l.tick += 1
		out := make([dynamic]Outgoing, context.temp_allocator)
		sender_flush(&l.tx, l.tick, {}, &out)
		got := make([dynamic]Received, context.temp_allocator)
		for m, i in out {
			if len(m.data) > SNAPSHOT_PART_BYTES {return false}
			if i == drop_part {continue}
			if !receive_snapshot(&l.rx, m.data, &got) {return false}
			link_apply(l, got[:])
			clear(&got)
		}
		sender_ack(&l.tx, l.rx.ack)
		return len(out) > 1
	}
	testing.expect(t, tick(&l, motions[:], -1), "the snapshot was not split in parts")
	complete := l.rx.ack
	testing.expect(t, complete != 0, "a complete snapshot was not acknowledged")
	testing.expect(t, tick(&l, motions[:], 1), "the snapshot was not split in parts")
	testing.expect_value(t, l.rx.ack, complete) // (one part short: not acknowledged)
	have := len(l.view.tables[DT_MOTION].records)
	testing.expect_value(t, have, 200)
	// the part that did arrive was applied: some record moved on
	moved := 0
	for rec in l.view.tables[DT_MOTION].records {
		if (^Dt_Motion)(rec.value).position.x > f64(rec.key.a) - 1 + 0.75 {moved += 1}
	}
	testing.expect(t, moved > 0 && moved < 200, "a lost part must leave a part applied")
	// the next one is a delta against the older baseline, and decodes
	testing.expect(t, tick(&l, motions[:], -1), "no parts")
	testing.expect(t, l.rx.ack > complete, "the next snapshot was not acknowledged")
	testing.expect(t, kinds_equal(&l.tx.cur, &l.view, DT_MOTION), "the view differs")
}

@(test)
test_snapshot_baseline_gone :: proc(t: ^testing.T) {
	s := dt_schema()
	l: Link
	link_init(&l, &s)
	defer link_destroy(&l)
	m := Dt_Motion {
		position = {1, 2, 3},
	}
	link_put(&l, DT_MOTION, 1, &m)
	link_step(&l)
	acked := l.rx.ack
	testing.expect(t, acked != 0)
	// an acknowledgement older than the ring: the next snapshot has no baseline
	for _ in 0 ..< SNAPSHOT_RING + 4 {
		m.position.x += 1
		link_put(&l, DT_MOTION, 1, &m)
		l.tick += 1
		out := make([dynamic]Outgoing, context.temp_allocator)
		sender_flush(&l.tx, l.tick, {}, &out) // (never delivered, never acknowledged)
	}
	m.position.x += 1
	link_put(&l, DT_MOTION, 1, &m)
	l.tick += 1
	out := make([dynamic]Outgoing, context.temp_allocator)
	sender_flush(&l.tx, l.tick, {}, &out)
	if !testing.expect(t, len(out) == 1) {return}
	r := reader_make(out[0].data)
	read_u8(&r)
	read_varint(&r)
	testing.expect_value(t, read_varint(&r), u32(0)) // back: none
}

@(test)
test_snapshot_priority :: proc(t: ^testing.T) {
	s := dt_schema()
	l: Link
	link_init(&l, &s)
	defer link_destroy(&l)
	// 400 records far too many for one snapshot, all changing every tick
	motions := make([]Dt_Motion, 400, context.temp_allocator)
	for &m, i in motions {m.position = {f64(i), 0, 0}}
	for _ in 1 ..= 40 {
		for &m, i in motions {
			m.position.y += 1
			link_put(&l, DT_MOTION, u32(i + 1), &m)
		}
		link_step(&l, {0, 0, 0})
	}
	// far records are not starved: what everyone's view holds is at most 10
	// ticks old (position.y counts the ticks)
	starved := 0
	for rec in l.view.tables[DT_MOTION].records {
		if 40 - (^Dt_Motion)(rec.value).position.y > 10 {starved += 1}
	}
	testing.expect_value(t, len(l.view.tables[DT_MOTION].records), 400)
	testing.expect_value(t, starved, 0)
	// and in the first snapshot, nearer ones went first
	l2: Link
	link_init(&l2, &s)
	defer link_destroy(&l2)
	for &m, i in motions {link_put(&l2, DT_MOTION, u32(i + 1), &m)}
	link_step(&l2, {0, 0, 0})
	nearest, farthest := 0, 0
	for rec in l2.view.tables[DT_MOTION].records {
		if rec.key.a <= 100 {nearest += 1}
		if rec.key.a > 300 {farthest += 1}
	}
	testing.expect(t, nearest > farthest, "nearer records must go first when a snapshot is full")
}

// ---- malformed input ----

@(private = "file")
valid_messages :: proc(l: ^Link) -> (state, snapshot: []u8) {
	a := Sch_All {
		a    = 9,
		name = "abc",
		spot = Block_Pos{1, 2, 3},
	}
	link_put(l, DT_ALL, 3, &a)
	link_put(l, DT_ALL, 4, &a)
	m := Dt_Motion {
		position = {1, 2, 3},
		yaw      = 2,
	}
	link_put(l, DT_MOTION, 7, &m)
	ping := Dt_Ping{"p", 3}
	sender_event(&l.tx, DT_PING, &ping)
	b := Dt_Block{.Stone, true}
	sender_put(&l.tx, DT_BLOCK, key_of_block({1, 2, 3}), &b)
	l.tick += 1
	out := make([dynamic]Outgoing, context.temp_allocator)
	sender_flush(&l.tx, l.tick, {}, &out)
	for o in out {
		if o.snapshot {snapshot = o.data} else {state = o.data}
	}
	return
}

@(private = "file")
fresh_rx :: proc(s: ^Schema) -> Receiver {
	rx: Receiver
	receiver_init(&rx, s, test_reg())
	return rx
}

@(test)
test_state_prefixes_fail :: proc(t: ^testing.T) {
	s := dt_schema()
	l: Link
	link_init(&l, &s)
	defer link_destroy(&l)
	state, snapshot := valid_messages(&l)
	got := make([dynamic]Received, context.temp_allocator)
	{
		rx := fresh_rx(&s)
		defer receiver_destroy(&rx)
		testing.expect(t, receive_state(&rx, state, &got), "the valid State message was refused")
	}
	{
		rx := fresh_rx(&s)
		defer receiver_destroy(&rx)
		testing.expect(
			t,
			receive_snapshot(&rx, snapshot, &got),
			"the valid Snapshot message was refused",
		)
	}
	for n in 0 ..< len(state) {
		rx := fresh_rx(&s)
		defer receiver_destroy(&rx)
		clear(&got)
		// (a prefix that ends exactly between groups is a shorter, valid message)
		ok := receive_state(&rx, state[:n], &got)
		if ok {testing.expectf(t, n == 2 || len(got) > 0, "the %d byte prefix of a State was accepted", n)}
	}
	for n in 0 ..< len(snapshot) {
		rx := fresh_rx(&s)
		defer receiver_destroy(&rx)
		clear(&got)
		ok := receive_snapshot(&rx, snapshot[:n], &got)
		if ok {testing.expectf(t, n == 5 || len(got) > 0, "the %d byte prefix of a Snapshot was accepted", n)}
	}
}

@(private = "file")
Bad :: struct {
	why:  string,
	data: []u8,
}

@(private = "file")
state_with :: proc(body: ..u8) -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, STATE_MESSAGE, 1)
	append(&out, ..body)
	return out[:]
}

@(test)
test_state_malformed_cases :: proc(t: ^testing.T) {
	s := dt_schema()
	l: Link
	link_init(&l, &s)
	defer link_destroy(&l)
	state, _ := valid_messages(&l)
	with_trailing := slice.concatenate([][]u8{state, {0}}, context.temp_allocator)
	// single: id 3, count 1, head (create) 1, n varint
	cases := [?]Bad {
		{"an unknown id", state_with(99, 1, 1)},
		{"op 3", state_with(DT_SINGLE, 1, 3, 1)},
		{"a mask bit past the kind's fields", state_with(DT_SINGLE, 1, 0b100, 1)},
		{"a change to an unheld key", state_with(DT_SINGLE, 1, 0b100, 1)},
		{"a count of zero", state_with(DT_SINGLE, 0)},
		{"a count past the bytes", state_with(DT_SINGLE, 5, 1, 1)},
		{"a create past max_records", state_with(DT_SINGLE, 2, 1, 1, 1, 1)},
		{"an enum gap", state_with(DT_ALL, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3)},
		{"a snapshot kind in a State", state_with(DT_MOTION, 1, 1, 1)},
		{"an over-long varint", state_with(DT_SINGLE, 1, 1, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80)},
		{"trailing bytes", with_trailing},
	}
	for c in cases {
		rx := fresh_rx(&s)
		defer receiver_destroy(&rx)
		got := make([dynamic]Received, context.temp_allocator)
		testing.expectf(t, !receive_state(&rx, c.data, &got), "%s was accepted", c.why)
	}

	// a create of a held key
	{
		rx := fresh_rx(&s)
		defer receiver_destroy(&rx)
		got := make([dynamic]Received, context.temp_allocator)
		ok := receive_state(&rx, state_with(DT_SINGLE, 1, 1, 5), &got)
		testing.expect(t, ok, "a valid create was refused")
		ok = receive_state(&rx, state_with(DT_SINGLE, 1, 1, 5), &got)
		testing.expect(t, !ok, "a create of a held key was accepted")
	}
	// a change to a held record that makes it NaN: floats must be finite
	{
		rx := fresh_rx(&s)
		defer receiver_destroy(&rx)
		got := make([dynamic]Received, context.temp_allocator)
		testing.expect(t, receive_state(&rx, state_with(DT_SINGLE, 1, 1, 5), &got))
		nan := state_with(DT_ME, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
		_ = nan
	}
	// a Block_Pos outside the world
	{
		rx := fresh_rx(&s)
		defer receiver_destroy(&rx)
		got := make([dynamic]Received, context.temp_allocator)
		w: Writer
		writer_init(&w, context.temp_allocator)
		write_u8(&w, STATE_MESSAGE)
		write_varint(&w, 1)
		write_varint(&w, DT_BLOCK)
		write_varint(&w, 1)
		write_varint64(&w, 1) // create
		write_varint(&w, 0) // a new chunk
		write_svarint(&w, 1 << 25)
		write_svarint(&w, 0)
		write_svarint(&w, 0)
		write_varint(&w, 0)
		write_varint(&w, 1) // stone
		write_u8(&w, 0)
		testing.expect(
			t,
			!receive_state(&rx, w.buf[:], &got),
			"a block outside the world was accepted",
		)
	}
}

@(test)
test_snapshot_malformed_cases :: proc(t: ^testing.T) {
	s := dt_schema()
	snap :: proc(tick, back: u32, part, parts: u8, body: ..u8) -> []u8 {
		w: Writer
		writer_init(&w, context.temp_allocator)
		write_u8(&w, SNAPSHOT_MESSAGE)
		write_varint(&w, tick)
		write_varint(&w, back)
		write_u8(&w, part)
		write_u8(&w, parts)
		append(&w.buf, ..body)
		return w.buf[:]
	}
	cases := [?]Bad {
		{"no parts", snap(1, 0, 0, 0)},
		{"too many parts", snap(1, 0, 0, SNAPSHOT_PARTS + 1)},
		{"a part past the parts", snap(1, 0, 2, 2)},
		{"a baseline after the snapshot", snap(1, 2, 0, 1)},
		{"tick zero", snap(0, 0, 0, 1)},
		{"a reliable kind in a snapshot", snap(1, 0, 0, 1, DT_SINGLE, 1, 1, 5)},
		{"a change in a snapshot with no baseline", snap(1, 0, 0, 1, DT_MOTION, 1, 0b100, 1)},
		{"a removal of a record not held", snap(1, 0, 0, 1, DT_MOTION, 1, 2, 3)},
	}
	for c in cases {
		rx := fresh_rx(&s)
		defer receiver_destroy(&rx)
		got := make([dynamic]Received, context.temp_allocator)
		testing.expectf(t, !receive_snapshot(&rx, c.data, &got), "%s was accepted", c.why)
	}
	// a baseline the receiver lacks: dropped, counted, not an error
	rx := fresh_rx(&s)
	defer receiver_destroy(&rx)
	got := make([dynamic]Received, context.temp_allocator)
	testing.expect(t, receive_snapshot(&rx, snap(40, 5, 0, 1), &got))
	testing.expect_value(t, rx.dropped, 1)
	testing.expect_value(t, len(got), 0)
}

@(test)
test_state_decode_fuzz :: proc(t: ^testing.T) {
	s := dt_schema()
	l: Link
	link_init(&l, &s)
	defer link_destroy(&l)
	state, snapshot := valid_messages(&l)
	rng := base.rng_make(99)
	got := make([dynamic]Received, context.temp_allocator)
	for i in 0 ..< 3000 {
		which := state if i % 2 == 0 else snapshot
		data := slice.clone(which, context.temp_allocator)
		for _ in 0 ..< 1 + base.rng_int_max(&rng, 3) {
			data[base.rng_int_max(&rng, len(data))] = u8(base.rng_u32(&rng))
		}
		rx := fresh_rx(&s)
		clear(&got)
		if i % 2 == 0 {receive_state(&rx, data, &got)} else {receive_snapshot(&rx, data, &got)}
		receiver_destroy(&rx) // (whatever was accepted must also be freeable)
	}
}
