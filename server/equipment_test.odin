package server

import "core:os"
import "core:path/filepath"
import "core:testing"

import "common:game"

// M22b's exit check, two players over UDP: armor goes on through the
// inventory's own actions (only into the slot it fits; swapping; quick
// equip), the other player is told what is worn (and again when it comes
// off, and on joining later), and equipment is kept through a restart.
@(test)
test_equipment_over_the_network :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "net_equipment"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	config := Config {
		seed            = 22,
		view_radius     = 2,
		view_height     = 1,
		save_dir        = dir,
		max_players     = 4,
		listen          = true,
		generator       = .Classic,
		everyone_cheats = true, // (the catalog)
	}
	h: Harness
	srv := &h.srv
	if !testing.expect(t, harness_start(&h, config)) {return}
	stopped := false
	defer if !stopped {harness_stop(&h)}
	cap_, boots := game.item_of_armor(.Cap), game.item_of_armor(.Boots)
	head, feet :=
		game.EQUIP_BASE + int(game.Equip_Slot.Head), game.EQUIP_BASE + int(game.Equip_Slot.Feet)

	alice, bob: Net_Client
	net_connect(&alice, 0, "alice", h = &h)
	net_connect(&bob, 0, "bob", h = &h)
	defer net_close(&alice)
	defer net_close(&bob)
	both := []^Net_Client{&alice, &bob}
	ok := net_wait(t, both, proc(cs: []^Net_Client) -> bool {
		return(
			cs[0].inv_updates > 0 &&
			cs[1].inv_updates > 0 &&
			len(cs[0].others) == 1 &&
			len(cs[1].others) == 1 \
		)
	})
	if !testing.expect(t, ok, "the players never met") {return}
	alice_id: u16
	for id, name in bob.others {if name == "alice" {alice_id = id}}

	// The cap onto the head: taken from the catalog, put on.
	net_send(&alice, game.Inventory_Request{1, {.Take, game.CURSOR_SLOT, int(cap_)}})
	net_send(&alice, game.Inventory_Request{2, {.Click, head, 0}})
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {
		return cs[0].inv_acked == 2
	})
	testing.expect(t, ok && alice.inventory.equipment[.Head] == {cap_, 1, 0}, "the cap is not on")
	testing.expect(t, game.stack_empty(alice.inventory.cursor))

	// Boots into the head slot: refused (the cursor keeps them); into the feet: on.
	net_send(&alice, game.Inventory_Request{3, {.Take, game.CURSOR_SLOT, int(boots)}})
	net_send(&alice, game.Inventory_Request{4, {.Click, head, 0}})
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {return cs[0].inv_acked == 4})
	testing.expect(
		t,
		ok &&
		alice.inventory.cursor.item == boots &&
		alice.inventory.equipment[.Head].item == cap_,
		"the wrong slot took them",
	)
	net_send(&alice, game.Inventory_Request{5, {.Click, feet, 0}})
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {return cs[0].inv_acked == 5})
	testing.expect(t, ok && alice.inventory.equipment[.Feet].item == boots)

	// Bob sees the cap and the boots.
	want := [game.WORN_SLOTS]game.Item{cap_, 0, 0, boots}
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {return len(cs[1].worn) > 0})
	testing.expect(t, ok)
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {
		w := cs[1].worn
		for _, v in w {return v[0] != 0 && v[3] != 0}
		return false
	})
	testing.expect_value(t, bob.worn[alice_id], want)

	// Shift-click takes a piece off, and puts it on again.
	net_send(&alice, game.Inventory_Request{6, {.Quick_Move, head, 0}}) // off: into the inventory
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {return cs[0].inv_acked == 6})
	testing.expect(t, ok && game.stack_empty(alice.inventory.equipment[.Head]))
	testing.expect_value(t, game.inventory_count(&alice.inventory, cap_), 1)
	slot := -1
	for st, i in alice.inventory.slots {if st.item == cap_ {slot = i}}
	net_send(&alice, game.Inventory_Request{7, {.Quick_Move, slot, 0}}) // on again
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {return cs[0].inv_acked == 7})
	testing.expect(t, ok && alice.inventory.equipment[.Head].item == cap_)

	// Kept through a restart, and a player joining later is told.
	alice_had := alice.inventory
	net_close(&alice)
	net_close(&bob)
	alice, bob = {}, {}
	expect_items_balanced(t, srv)
	testing.expect(t, harness_stop(&h))
	stopped = true
	if !testing.expect(t, harness_start(&h, config)) {return}
	stopped = false
	net_connect(&alice, 0, "alice", h = &h)
	net_connect(&bob, 0, "bob", h = &h)
	ok = net_wait(
		t,
		both,
		proc(cs: []^Net_Client) -> bool {return cs[0].inv_updates > 0 && cs[1].inv_updates > 0},
	)
	testing.expect(
		t,
		ok && alice.inventory.equipment == alice_had.equipment,
		"equipment lost in the restart",
	)
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {return len(cs[1].worn) > 0})
	testing.expect(t, ok, "bob was not told what alice wears")
	for _, v in bob.worn {testing.expect_value(t, v, want)}
}
