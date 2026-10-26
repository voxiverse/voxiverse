package client

import "core:math"
import "core:time"

import "../game"

// Items as the player uses them: the stack in hand (the selected hotbar
// slot of the inventory, game/inventory.odin) and the mouse buttons. A
// block's item places it with the right button (the left breaks, or hits a
// sheep); the rocket launcher fires with the left. The inventory is the
// server's: what we do to it is predicted at once and sent
// (session_inventory_do), and replayed over each Inventory_Update until
// the server has answered it.

// Drop_Repeat: holding the drop key drops again and again, slowly at first,
// then faster (after the utility mods of other games).
DROP_FIRST_REPEAT :: 0.35 // seconds held before the second drop
DROP_START_INTERVAL :: 0.25 // seconds between the next ones, shrinking
DROP_SHRINK :: 0.8 // each interval is this much of the last
DROP_MIN_INTERVAL :: 0.04

Drop_Repeat :: struct {
	next:  f64, // when the held key drops next (seconds)
	count: int, // drops since it went down
}

// drop_repeat: true when a drop is due. now in seconds; pressed: the key
// went down this frame; down: it is held.
drop_repeat :: proc(r: ^Drop_Repeat, pressed, down: bool, now: f64) -> bool {
	switch {
	case pressed:
		r^ = {now + DROP_FIRST_REPEAT, 1}
		return true
	case down && r.count > 0 && now >= r.next:
		interval := max(
			DROP_MIN_INTERVAL,
			DROP_START_INTERVAL * math.pow(DROP_SHRINK, f64(r.count - 1)),
		)
		r.next, r.count = now + interval, r.count + 1
		return true
	case !down:
		r.count = 0
	}
	return false
}

// seconds_now: a clock for drop_repeat.
seconds_now :: proc() -> f64 {
	return f64(time.tick_now()._nsec) / 1e9
}

// held: the stack in hand.
held :: proc(s: ^Session) -> game.Stack {
	return game.inventory_held(&s.inventory)
}

// item_use: the mouse buttons with stack in hand.
item_use :: proc(s: ^Session, stack: game.Stack, breaking, placing: bool) {
	// Using what is aimed at comes before placing a block behind it.
	if placing && !breaking && (session_use_entity(s) || session_use_block(s)) {return}
	info, _ := game.item_info(stack.item)
	if t, tool := info.tool.?; tool {
		switch t {
		case .Launcher:
			if breaking {session_fire(s)}
			return
		case .Hoe:
			// Tills with the right button; the left still breaks and hits.
			if placing && !breaking {
				session_till(s)
				return
			}
		}
	}
	if breaking && !placing {
		if session_attack(s) {return}
		session_edit(s, false, .Air)
		return
	}
	if placing && !breaking && info.block != .Air {session_edit(s, true, info.block)}
}

// Pending_Inventory: an inventory request sent, not yet answered.
Pending_Inventory :: struct {
	sequence: u32,
	action:   game.Inventory_Action,
}

// session_inventory_do does a to our inventory (predicted) and asks the
// server; false (and nothing sent) if it does nothing.
session_inventory_do :: proc(s: ^Session, a: game.Inventory_Action) -> bool {
	if s.state != .Playing {return false}
	_, ok := game.inventory_apply(&s.inventory, a, session_allowed(s, "items.catalog"))
	if !ok {return false}
	s.inv_sequence += 1
	append(&s.inv_pending, Pending_Inventory{s.inv_sequence, a})
	send_message(s, game.Inventory_Request{s.inv_sequence, a})
	return true
}

// inventory_reconcile: the server's inventory, then what it has not
// answered yet over it (requests, and blocks placed and not yet confirmed).
inventory_reconcile :: proc(s: ^Session, u: game.Inventory_Update) {
	s.server_inventory = u.inventory
	for len(s.inv_pending) > 0 && !game.sequence_before(u.acked, s.inv_pending[0].sequence) {
		ordered_remove(&s.inv_pending, 0)
	}
	inventory_predict(s)
}

// inventory_predict: our inventory as it will be once the server has
// answered everything we have done.
inventory_predict :: proc(s: ^Session) {
	s.inventory = s.server_inventory
	catalog := session_allowed(s, "items.catalog")
	for p in s.inv_pending {game.inventory_apply(&s.inventory, p.action, catalog)}
	if session_allowed(s, "items.infinite") {return}
	for e in s.edits {
		if e.block == .Air {continue}
		if slot := game.inventory_placing_slot(&s.inventory, e.block); slot >= 0 {
			s.inventory.slots[slot].count -= 1
			game.inventory_tidy(&s.inventory)
		}
	}
}

// can_place_from_hand: placing block would find it in the inventory (or
// the player places without using anything up).
can_place_from_hand :: proc(s: ^Session, block: game.Block) -> bool {
	return(
		session_allowed(s, "items.infinite") ||
		game.inventory_placing_slot(&s.inventory, block) >= 0 \
	)
}
