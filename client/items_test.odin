package client

import "core:testing"

import "../game"

// The inventory as we predict it: our requests replayed over the server's
// word until it answers them; a refused one rolled back; blocks placed
// used up until confirmed (not with items.infinite).
@(test)
test_inventory_prediction :: proc(t: ^testing.T) {
	s := new(Session)
	defer free(s)
	defer delete(s.inv_pending)
	defer delete(s.edits)
	defer delete(s.grants)
	s.state = .Playing
	stone := game.item_of_block(.Stone)
	server: game.Inventory
	server.slots[0] = {stone, 64}
	inventory_reconcile(s, {0, server})
	testing.expect(t, s.inventory == server)

	// Pick up the stack, put it in slot 5: both predicted.
	append(
		&s.inv_pending,
		Pending_Inventory{1, {.Click, 0, 0}},
		Pending_Inventory{2, {.Click, 5, 0}},
	)
	inventory_predict(s)
	testing.expect(
		t,
		s.inventory.slots[5] == {stone, 64} && game.stack_empty(s.inventory.slots[0]),
	)
	// The server has done the first: the second is still replayed.
	picked := server
	picked.slots[0], picked.cursor = {}, {stone, 64}
	inventory_reconcile(s, {1, picked})
	testing.expect_value(t, len(s.inv_pending), 1)
	testing.expect(t, s.inventory.slots[5] == {stone, 64} && game.stack_empty(s.inventory.cursor))
	// It refused the second (the inventory as before it): rolled back.
	inventory_reconcile(s, {2, picked})
	testing.expect_value(t, len(s.inv_pending), 0)
	testing.expect(t, s.inventory == picked, "a refused request was not rolled back")

	// A block placed and not yet confirmed is used up; with items.infinite not.
	inventory_reconcile(s, {2, server})
	append(&s.edits, game.Edit{id = 1, block = .Stone})
	inventory_predict(s)
	testing.expect_value(t, s.inventory.slots[0].count, 63)
	testing.expect(t, !can_place_from_hand(s, .Dirt) && can_place_from_hand(s, .Stone))
	append(&s.grants, game.Grant{pattern = "items.*", allow = true})
	inventory_predict(s)
	testing.expect_value(t, s.inventory.slots[0].count, 64)
	testing.expect(t, can_place_from_hand(s, .Dirt))
	// Its result came: nothing pending.
	clear(&s.edits)
	clear(&s.grants)
	inventory_predict(s)
	testing.expect(t, s.inventory == server)
}

// Holding the drop key: one at once, then slowly, then faster, never
// faster than the floor; letting go starts over.
@(test)
test_drop_repeat :: proc(t: ^testing.T) {
	r: Drop_Repeat
	testing.expect(t, drop_repeat(&r, true, true, 10), "the press drops")
	testing.expect(t, !drop_repeat(&r, false, true, 10.2), "not yet")
	now := 10 + DROP_FIRST_REPEAT
	testing.expect(t, drop_repeat(&r, false, true, now), "held: the second")
	gaps: [dynamic]f64
	defer delete(gaps)
	last := now
	for step := 0; step < 4000 && len(gaps) < 14; step += 1 {
		now += 0.005
		if drop_repeat(&r, false, true, now) {
			append(&gaps, now - last)
			last = now
		}
	}
	testing.expect(t, gaps[0] > gaps[5] && gaps[5] > gaps[10], "it speeds up")
	testing.expect(t, gaps[13] >= DROP_MIN_INTERVAL - 0.006, "not past the floor")
	testing.expect(t, !drop_repeat(&r, false, false, now + 1), "released: nothing")
	testing.expect(
		t,
		!drop_repeat(&r, false, true, now + 2),
		"and a held key it was not pressed with does nothing",
	)
	testing.expect(t, drop_repeat(&r, true, true, now + 3), "pressed again: starts over")
}
