package core

import "core:strings"
import "core:testing"

import "common:game"

// An inventory set aside and given back (inventory_set_aside, inventory_give_back): one at
// a time, saved with the character, untouched by death, and the item ledger balanced
// throughout.

@(private = "file")
aside_open :: proc(t: ^testing.T, sess: ^Session, death_drops := false) -> bool {
	config := harness_world()
	if death_drops {
		config.mode = "survival"
		config.rules = game.RULES_DEFAULTS
		config.rules.keep_inventory = false
	}
	if !testing.expect(t, session_start(sess, {}, false, with = config)) {return false}
	if !testing.expect(t, harness_landed(&sess.h), "the player never landed") {return false}
	audit_baseline(&sess.h.srv)
	return true
}

@(private = "file")
expect_audit :: proc(t: ^testing.T, s: ^Server, what: string, loc := #caller_location) {
	lines := audit(s)
	testing.expectf(t, len(lines) == 0, "%s: unbalanced: %v", what, lines, loc = loc)
}

@(private = "file")
held_count :: proc(inv: ^game.Inventory, item: game.Item) -> int {
	n := 0
	for st in inv.slots {if st.item == item && !game.stack_empty(st) {n += st.count}}
	for st in inv.equipment {if st.item == item && !game.stack_empty(st) {n += st.count}}
	if inv.cursor.item == item && !game.stack_empty(inv.cursor) {n += inv.cursor.count}
	return n
}

@(test)
test_inventory_set_aside_and_given_back :: proc(t: ^testing.T) {
	sess := new(Session)
	defer free(sess)
	if !aside_open(t, sess) {
		session_stop(sess)
		return
	}
	defer session_stop(sess)
	s := &sess.h.srv
	c := &s.clients[0]
	reg := s.registry
	stone := game.item_of_block(reg, .Stone)
	planks := game.item_of_block(reg, .Planks)
	c.inventory.cursor = c.inventory.slots[0] // (one stack on the cursor, as if carried)
	c.inventory.slots[0] = {}
	before := c.inventory
	testing.expect(t, held_count(&before, stone) > 0, "the kit gave no stone")

	testing.expect(t, inventory_set_aside(s, c))
	testing.expect_value(t, held_count(&c.inventory, stone), 0)
	testing.expect(t, game.stack_empty(c.inventory.cursor), "the cursor kept its stack")
	testing.expect(t, !inventory_set_aside(s, c), "a second inventory was set aside")
	expect_audit(t, s, "set aside")

	// The encounter's kit, then the player's own again: the kit is gone, booked so.
	testing.expect_value(t, item_give(s, c, planks, 10), 10)
	testing.expect(t, inventory_give_back(s, c))
	testing.expect(t, c.aside == nil, "still set aside")
	testing.expect_value(t, c.inventory.slots, before.slots)
	testing.expect_value(t, c.inventory.equipment, before.equipment)
	testing.expect_value(t, c.inventory.cursor, before.cursor)
	testing.expect_value(t, held_count(&c.inventory, planks), 0)
	planks_row, stone_row := s.ledger.entries[planks], s.ledger.entries[stone]
	testing.expect_value(t, planks_row[.Game], 0) // (10 given, 10 gone)
	testing.expect_value(t, stone_row[.Game], 0) // (neither made nor lost)
	testing.expect(t, !inventory_give_back(s, c), "given back twice")
	expect_audit(t, s, "given back")

	// Set aside, the player leaves: kept with its character, out of memory with it.
	testing.expect(t, inventory_set_aside(s, c))
	name := strings.clone(client_name(c), context.temp_allocator) // (its seat forgets it)
	leave(s, c, "test")
	expect_audit(t, s, "left with an inventory set aside")
	r, ok := player_record(s, name)
	if !testing.expect(t, ok, "no record kept") {return}
	aside, set_aside := r.aside.?
	testing.expect(t, set_aside, "the record lost the inventory set aside")
	testing.expect_value(t, aside.slots, before.slots)
	testing.expect_value(t, aside.cursor, before.cursor)
	clear(&sess.failures) // (the mirror was let go)
}

// Death with drop_on_death drops only what the player holds; what is set aside stays.
@(test)
test_inventory_set_aside_through_death :: proc(t: ^testing.T) {
	sess := new(Session)
	defer free(sess)
	if !aside_open(t, sess, death_drops = true) {
		session_stop(sess)
		return
	}
	defer session_stop(sess)
	s := &sess.h.srv
	c := &s.clients[0]
	reg := s.registry
	planks := game.item_of_block(reg, .Planks)
	own := c.inventory
	testing.expect(t, inventory_set_aside(s, c))
	testing.expect_value(t, item_give(s, c, planks, 5), 5)
	items := 0
	it := entities_each(c.world)
	for e in entities_next(&it) {if entity_kind(c.world, e) == reg.engine.item {items += 1}}
	testing.expect_value(t, items, 0)

	damage(s, c, 1000, {kind = .Command})
	testing.expect(t, c.dead, "it lived")
	dropped := 0
	it = entities_each(c.world)
	for e in entities_next(&it) {
		if entity_kind(c.world, e) != reg.engine.item {continue}
		st := entity_stack(c.world, e)^
		testing.expect_value(t, st.item, planks)
		dropped += st.count
	}
	testing.expect_value(t, dropped, 5)
	aside, set_aside := c.aside.?
	testing.expect(t, set_aside, "death took what was set aside")
	testing.expect_value(t, aside.slots, own.slots)
	expect_audit(t, s, "death while set aside")
	testing.expect(t, inventory_give_back(s, c))
	expect_audit(t, s, "given back after death")
}

// A character file keeps the inventory set aside (even an empty one); one of format 5 has
// none.
@(test)
test_inventory_set_aside_in_the_character_file :: proc(t: ^testing.T) {
	reg := test_reg()
	stone := game.item_of_block(reg, .Stone)
	r: Player_Record
	r.inventory.slots[2] = {stone, 3, 0, 0}
	aside: game.Inventory
	aside.slots[5] = {stone, 7, 0, 0}
	aside.cursor = {stone, 1, 0, 0}
	r.aside = aside
	back, ok := player_parse(reg, player_json(reg, &r, nil), nil)
	counters_free(&back.stats)
	testing.expect(t, ok)
	got, set_aside := back.aside.?
	testing.expect(t, set_aside, "the inventory set aside was lost")
	testing.expect_value(t, got.slots, aside.slots)
	testing.expect_value(t, got.cursor, aside.cursor)
	testing.expect_value(t, back.inventory.slots, r.inventory.slots)

	r.aside = game.Inventory{}
	back, ok = player_parse(reg, player_json(reg, &r, nil), nil)
	counters_free(&back.stats)
	testing.expect(t, ok && back.aside != nil, "an empty inventory set aside was lost")

	r.aside = nil
	text := player_json(reg, &r, nil)
	back, ok = player_parse(reg, text, nil)
	counters_free(&back.stats)
	testing.expect(t, ok && back.aside == nil, "something was set aside")
	testing.expect(
		t,
		!strings.contains(string(text), "aside"),
		"a file with nothing set aside says so",
	)

	old, old_ok := player_parse(
		reg,
		transmute([]u8)string(
			`{"format": 5, "position": [1, 2, 3], "items": [{"slot": 0, "item": "voxiverse:stone", "count": 4}]}`,
		),
		nil,
	)
	counters_free(&old.stats)
	testing.expect(t, old_ok)
	testing.expect(t, old.aside == nil, "a format 5 file had an inventory set aside")
	testing.expect_value(t, old.inventory.slots[0].count, 4)
}
