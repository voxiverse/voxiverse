package server

import "core:fmt"
import "core:log"
import "core:slice"

import "../common/game"
import "../common/telemetry"

// The item ledger (M31): every item that enters or leaves what the server
// holds is one call to ledger with a reason (a faucet: count positive, a
// sink: negative); the audit sums everything held and checks it against the
// entries. Moves (pick up, drop, merge, chest in and out, equip, death spill,
// travel) are not entries: they only change where an item is, and the audit
// is what notices one that changed how many. It never fixes anything: a fix
// would hide the bug.

Ledger :: struct {
	entries:  map[game.Item][game.Reason]i64, // (heap; the server's thread only)
	baseline: map[game.Item]i64, // what was held at audit_baseline
}

ledger_destroy :: proc(l: ^Ledger) {
	delete(l.entries)
	delete(l.baseline)
	l^ = {}
}

// ledger: count of item (positive: made, negative: gone) for reason, in w.
// Scope entries are bookkeeping and tell nobody.
ledger :: proc(s: ^Server, w: ^World, reason: game.Reason, item: game.Item, count: int) {
	if count == 0 || item == game.NO_ITEM {return}
	row, _ := &s.ledger.entries[item]
	if row == nil {
		s.ledger.entries[item] = {}
		row = &s.ledger.entries[item]
	}
	row[reason] += i64(count)
	if reason == .Scope_In || reason == .Scope_Out {return}
	kind := telemetry.Kind.Item_Created if count > 0 else telemetry.Kind.Item_Destroyed
	n := abs(count)
	telemetry.emit(
		&s.sink,
		event_for(s, w, kind, telemetry.NO_ACTOR, game.item_name(item), {i64(n), i64(reason), 0}),
	)
	if w != nil {
		pattern := "items.created." if count > 0 else "items.destroyed."
		counter_add(&w.stats, fmt.tprintf("%s%s", pattern, game.item_name(item)), u64(n))
	}
}

// ledger_stack: ledger for a stack (nothing if it is empty).
ledger_stack :: proc(s: ^Server, w: ^World, reason: game.Reason, st: game.Stack, sign := 1) {
	if game.stack_empty(st) {return}
	ledger(s, w, reason, st.item, sign * st.count)
}

// inventory_scope: an inventory's own stacks (the chest it looks into is a
// copy of the record, not counted) come into or leave memory.
ledger_inventory :: proc(s: ^Server, w: ^World, reason: game.Reason, inv: ^game.Inventory) {
	sign := 1 if reason == .Scope_In else -1
	for st in inv.slots {ledger_stack(s, w, reason, st, sign)}
	for st in inv.equipment {ledger_stack(s, w, reason, st, sign)}
	ledger_stack(s, w, reason, inv.cursor, sign)
}

// ledger_world_scope: what a world holds (chests and item entities) comes
// into memory (loaded) or leaves it (about to unload).
ledger_world_scope :: proc(w: ^World, reason: game.Reason) {
	s := w.server
	sign := 1 if reason == .Scope_In else -1
	for _, rec in w.containers {
		for st in rec.slots {ledger_stack(s, w, reason, st, sign)}
	}
	for e in w.entities.list {
		if e.kind == .Item {ledger_stack(s, w, reason, e.stack, sign)}
	}
}

// held_sums: everything held in memory, per item: online players'
// inventories, and the chests and item entities of loaded worlds.
@(private = "file")
held_sums :: proc(s: ^Server) -> map[game.Item]i64 {
	held := make(map[game.Item]i64, context.temp_allocator)
	add :: proc(held: ^map[game.Item]i64, st: game.Stack) {
		if !game.stack_empty(st) {held[st.item] += i64(st.count)}
	}
	for &c in s.clients {
		if c.state != .Playing {continue}
		for st in c.inventory.slots {add(&held, st)}
		for st in c.inventory.equipment {add(&held, st)}
		add(&held, c.inventory.cursor)
	}
	for w in s.worlds {
		for _, rec in w.containers {
			for st in rec.slots {add(&held, st)}
		}
		for e in w.entities.list {
			if e.kind == .Item {add(&held, e.stack)}
		}
	}
	return held
}

// Audit_Line: item is held `held` but the ledger says `expected`.
Audit_Line :: struct {
	item:     game.Item,
	held:     i64,
	expected: i64,
}

// audit: the items whose holdings disagree with the ledger (in the temp
// allocator); none is balanced. held - baseline - sum of entries is what
// is compared.
audit :: proc(s: ^Server) -> []Audit_Line {
	held := held_sums(s)
	seen := make(map[game.Item]struct{}, context.temp_allocator)
	lines := make([dynamic]Audit_Line, context.temp_allocator)
	check :: proc(
		s: ^Server,
		held: map[game.Item]i64,
		item: game.Item,
		lines: ^[dynamic]Audit_Line,
	) {
		sum := s.ledger.baseline[item]
		if row, ok := s.ledger.entries[item]; ok {
			for v in row {sum += v}
		}
		if held[item] != sum {append(lines, Audit_Line{item, held[item], sum})}
	}
	for item in held {
		seen[item] = {}
		check(s, held, item, &lines)
	}
	for item in s.ledger.entries {
		if item not_in seen {check(s, held, item, &lines)}
	}
	for item in s.ledger.baseline {
		if item not_in seen && item not_in s.ledger.entries {check(s, held, item, &lines)}
	}
	slice.sort_by(lines[:], proc(a, b: Audit_Line) -> bool {return a.item < b.item})
	return lines[:]
}

// audit_baseline: what is held now is the new starting point; the entries
// are zeroed.
audit_baseline :: proc(s: ^Server) {
	clear(&s.ledger.entries)
	clear(&s.ledger.baseline)
	for item, n in held_sums(s) {s.ledger.baseline[item] = n}
}

// AUDIT_EVERY_TICKS: a dedicated server audits this often (five minutes).
@(private = "file")
AUDIT_EVERY_TICKS :: 5 * 60 * game.TICK_RATE

// audit_tick: the periodic run of a dedicated server.
@(private)
audit_tick :: proc(s: ^Server) {
	if s.local != {} || s.tick % AUDIT_EVERY_TICKS != 0 || s.tick == 0 {return}
	audit_report(s)
}

// audit_report: runs the audit; each unbalanced item is logged at error
// with an Audit_Failed event. The number of unbalanced items.
audit_report :: proc(s: ^Server) -> int {
	lines := audit(s)
	for l in lines {
		log.errorf(
			"server audit unbalanced item=%s held=%d expected=%d difference=%d",
			game.item_name(l.item),
			l.held,
			l.expected,
			l.held - l.expected,
		)
		telemetry.emit(
			&s.sink,
			event_for(
				s,
				nil,
				.Audit_Failed,
				telemetry.NO_ACTOR,
				game.item_name(l.item),
				{l.held, l.expected, l.held - l.expected},
			),
		)
	}
	return len(lines)
}

// admin_audit: audit: check the items held against the ledger.
@(private)
admin_audit :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	lines := audit(s)
	if len(lines) == 0 {
		notice(s, c, "Items balanced")
		return true
	}
	audit_report(s)
	for l in lines[:min(len(lines), 8)] {
		notice(
			s,
			c,
			fmt.tprintf(
				"&cUnbalanced: %s held %d, ledger %d",
				game.item_name(l.item),
				l.held,
				l.expected,
			),
		)
	}
	return true
}
