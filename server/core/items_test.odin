package core

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "common:game"

// The exit check for items, two players over UDP: the kit, dropping a
// stack that the other picks up, placing using one up, breaking leaving
// the block to pick up, a refused request answered with the inventory as
// it was, the catalog only with its permission; inventories kept through a
// restart in the players' own files.
@(test)
test_items_over_the_network :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "net_items"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	config := Config {
		mode        = "survival",
		rules       = quiet_rules(),
		seed        = 21,
		view_radius = 2,
		view_height = 1,
		save_dir    = dir,
		max_players = 4,
		listen      = true,
		generator   = .Classic,
	}
	h := new(Harness)
	defer free(h)
	srv := &h.srv
	if !testing.expect(t, harness_start(h, config)) {return}
	stopped := false
	defer if !stopped {harness_stop(h)}
	stone, dirt := game.item_of_block(test_reg(), .Stone), game.item_of_block(test_reg(), .Dirt)

	alice := new(Net_Client)
	defer free(alice)
	bob := new(Net_Client)
	defer free(bob)
	net_connect(alice, 0, "alice", h = h)
	net_connect(bob, 0, "bob", h = h)
	defer net_close(alice)
	defer net_close(bob)
	both := []^Net_Client{alice, bob}
	ok := net_wait(
		t,
		both,
		proc(cs: []^Net_Client) -> bool {return cs[0].welcomed && cs[1].welcomed},
	)
	if !testing.expect(t, ok, "never joined") {return}
	// (survival's own kit is the weapons: these two hold the test world's blocks instead)
	call(
		srv,
		proc(s: ^Server, _: rawptr) {
			for &c in s.clients {
				if c.state != .Playing {continue}
				ledger_inventory(s, c.world, .Clear, &c.inventory) // (the audit stays balanced)
				c.inventory = {}
				give_kit(s, &c)
				c.inv_changed = true
			}
		},
		nil,
	)
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {
		ready :: proc(c: ^Net_Client) -> bool {
			return(
				c.inv_updates > 0 &&
				c.update.acked > 0 &&
				c.update.state.on_ground &&
				c.inventory.slots[0].count == 64 \
			)
		}
		return ready(cs[0]) && ready(cs[1])
	})
	if !testing.expect(t, ok, "the players never landed with their kits") {return}
	testing.expect(t, alice.inventory.slots[0] == {stone, 64, 0, 0}, "no kit")
	testing.expect(t, !game.allowed(alice.grants[:], "items.infinite"))

	// Alice drops all her stone at her feet (looking down); bob, standing
	// there too, picks it up.
	alice.look = {0, -1.5}
	net_wait(t, both, proc(cs: []^Net_Client) -> bool {return false}, 0.2)
	alice.seq += 1
	net_send(alice, game.Inventory_Request{1, {.Drop, 0, 1}})
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {
		return(
			cs[0].inv_acked == 1 &&
			game.inventory_count(&cs[1].inventory, game.item_of_block(test_reg(), .Stone)) == 128 \
		)
	})
	testing.expectf(t, ok, "bob has %d stone", game.inventory_count(&bob.inventory, stone))
	testing.expect_value(t, game.inventory_count(&alice.inventory, stone), 0)

	// Alice places dirt (slot 1) beside her: one used up.
	net_send(alice, game.Inventory_Request{2, {.Select, 0, 1}})
	feet := alice.update.state.position
	beside := game.Block_Pos {
		i32(math.floor(feet.x)) + 1,
		i32(math.floor(feet.y)),
		i32(math.floor(feet.z)),
	}
	net_send(alice, game.edit_plain(1, alice.seq, beside, .Dirt))
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {
		return(
			1 in cs[0].results &&
			game.inventory_count(&cs[0].inventory, game.item_of_block(test_reg(), .Dirt)) == 63 \
		)
	})
	testing.expect(t, ok && alice.results[1].accepted, "placing did not use one up")
	// She breaks it: it falls at her side; she picks it up.
	net_send(alice, game.edit_plain(2, alice.seq, beside, .Air))
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {
		return game.inventory_count(&cs[0].inventory, game.item_of_block(test_reg(), .Dirt)) == 64
	})
	testing.expectf(
		t,
		ok,
		"the broken block was not picked up (broken %v, entities %v, at %v, block %v)",
		alice.results[2],
		alice.entities,
		alice.update.state.position,
		beside,
	)

	// Refused: a click on nothing, the catalog without items.catalog.
	before := bob.inventory
	net_send(bob, game.Inventory_Request{1, {.Click, 25, 0}})
	net_send(bob, game.Inventory_Request{2, {.Take, game.CURSOR_SLOT, int(dirt)}})
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {return cs[1].inv_acked == 2})
	testing.expect(t, ok && bob.inventory == before, "a refused request changed the inventory")

	// Kept: after a restart, each carries what they carried.
	alice_had, bob_had := alice.inventory, bob.inventory
	net_close(alice)
	net_close(bob)
	alice^, bob^ = {}, {}
	expect_items_balanced(t, srv)
	testing.expect(t, harness_stop(h))
	stopped = true
	for name in ([]string{"alice", "bob"}) {
		path :=
			filepath.join(
				{
					dir,
					CHARACTERS_DIR,
					game.account_text(test_key(name).account),
					strings.concatenate({name, ".json"}, context.temp_allocator),
				},
				context.temp_allocator,
			) or_else ""
		testing.expectf(t, os.exists(path), "%s not written", path)
	}
	if !testing.expect(t, harness_start(h, config)) {return}
	stopped = false
	net_connect(alice, 0, "alice", h = h)
	net_connect(bob, 0, "bob", h = h)
	ok = net_wait(
		t,
		both,
		proc(cs: []^Net_Client) -> bool {return cs[0].inv_updates > 0 && cs[1].inv_updates > 0},
	)
	testing.expect(t, ok)
	testing.expect(
		t,
		alice.inventory == alice_had,
		"alice's inventory changed through the restart",
	)
	testing.expect(t, bob.inventory == bob_had, "bob's inventory changed through the restart")
}

// A player file from when inventories had 36 slots: what no longer fits
// is kept to be dropped at their feet when they join.
@(test)
test_old_inventory_fits :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(
		&b,
		`{"format": 1, "position": [1, 2, 3], "look": [0, 0], "flying": false, "selected": 8, "items": [`,
	)
	for i in 0 ..< 36 {
		if i > 0 {strings.write_string(&b, ", ")}
		strings.write_string(&b, `{"slot": `)
		strings.write_int(&b, i)
		strings.write_string(&b, `, "item": "stone", "count": 64}`)
	}
	strings.write_string(&b, "]}")
	r, ok := player_parse(test_reg(), transmute([]u8)strings.to_string(b))
	testing.expect(t, ok)
	stone := game.item_of_block(test_reg(), .Stone)
	testing.expect_value(t, game.inventory_count(&r.inventory, stone), 64 * game.INVENTORY_SLOTS)
	testing.expect_value(t, r.inventory.selected, game.HOTBAR_SLOTS - 1)
	over := 0
	for st in r.overflow {if st.item == stone {over += st.count}}
	testing.expect_value(t, over, 64 * (36 - game.INVENTORY_SLOTS))
}

// hotbar_select (a game's): the server puts another slot in hand and the player is told;
// a slot past the hotbar changes nothing.
@(test)
test_hotbar_select :: proc(t: ^testing.T) {
	sess := new(Session)
	defer free(sess)
	if !testing.expect(t, session_start(sess, {}, false, with = harness_world())) {return}
	defer session_stop(sess)
	welcomed :: proc(data: rawptr) -> bool {return (^Session)(data).mirror.welcomed}
	_, ok := harness_step_until(&sess.h, welcomed, sess, 600)
	if !testing.expect(t, ok, "the player never joined") {return}
	harness_step(&sess.h, 5)
	s := &sess.h.srv
	c := &s.clients[0]
	testing.expect_value(t, sess.mirror.inventory.selected, 0)

	testing.expect(t, hotbar_select(s, c, 3))
	harness_step(&sess.h, 5)
	testing.expect_value(t, c.inventory.selected, 3)
	testing.expect_value(t, sess.mirror.inventory.selected, 3)

	testing.expect(t, !hotbar_select(s, c, game.HOTBAR_SLOTS))
	testing.expect(t, !hotbar_select(s, c, -1))
	harness_step(&sess.h, 5)
	testing.expect_value(t, sess.mirror.inventory.selected, 3)
}

// Loot: Picked, the test game's tally of what its picking hook decided.
@(private = "file")
Picked :: struct {
	taken: int, // the dirt it took its own way (a purse)
	seen:  [dynamic]game.Stack,
}

// A game drops stacks with data of its own (a rolled stat): the pistol walked over
// goes into the inventory with its data, sent to the client so; the dirt the game
// takes its own way is gone; the stone it leaves lies there. After a save and a
// restart the pistol in the inventory and the stone on the ground still have theirs.
@(test)
test_loot_keeps_its_data :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "loot"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	config := harness_world()
	config.mode = "survival"
	config.save_dir = dir
	config.kit = ""
	config.game = {
		info = {id = "loot", name = "Loot"},
		server_state = Picked,
		picking = proc(s: ^Server, c: ^Client, stack: game.Stack) -> Pickup {
			p := game_state(s, Picked)
			append(&p.seen, stack)
			switch stack.item {
			case game.item_of_block(s.registry, .Dirt):
				p.taken += stack.count
				return .Taken
			case game.item_of_block(s.registry, .Stone):
				return .Leave
			}
			return .Take
		},
		stop = proc(s: ^Server) {delete(game_state(s, Picked).seen)},
	}
	pistol, _ := game.registry_item(test_reg(), "voxiverse:pistol")
	stone := game.item_of_block(test_reg(), .Stone)
	{
		sess := new(Session)
		defer free(sess)
		if !testing.expect(t, session_start(sess, {}, false, with = config)) {
			session_stop(sess)
			return
		}
		_, ok := harness_step_until(&sess.h, proc(data: rawptr) -> bool {
				sess := (^Session)(data)
				return sess.mirror.welcomed && sess.h.srv.clients[0].state == .Playing
			}, sess, 600)
		if !testing.expect(t, ok) {
			session_stop(sess)
			return
		}
		s := &sess.h.srv
		c := &s.clients[0]
		c.inventory.slots, c.inv_changed = {}, true // (the kit out of the way)
		feet := c.player.position
		testing.expect(t, item_drop(s, s.home, feet + {0.3, 0.5, 0}, {pistol, 1, 0, 0x0207}) != 0)
		testing.expect(
			t,
			item_drop(
				s,
				s.home,
				feet + {-0.3, 0.5, 0},
				{game.item_of_block(s.registry, .Dirt), 5, 0, 0},
			) !=
			0,
		)
		testing.expect(t, item_drop(s, s.home, feet + {0, 0.5, 0.3}, {stone, 3, 0, 99}) != 0)
		harness_step(&sess.h, 60)
		p := game_state(s, Picked)
		testing.expect_value(t, p.taken, 5)
		slot := slot_of(c, pistol)
		if testing.expect(t, slot >= 0, "the pistol was not picked up") {
			testing.expect_value(t, c.inventory.slots[slot].data, 0x0207)
			testing.expect_value(t, sess.mirror.inventory.slots[slot].data, 0x0207)
		}
		testing.expect_value(t, item_count(c, stone), 0)
		lying := 0
		it := entities_each(s.home)
		for h in entities_next(&it) {
			if entity_kind(s.home, h) == s.registry.engine.item {
				lying += 1
				testing.expect_value(t, entity_stack(s.home, h)^, game.Stack{stone, 3, 0, 99})
			}
		}
		testing.expect_value(t, lying, 1)
		session_stop(sess)
	}
	// The second session: the same player in the same universe.
	config.game.picking = proc(s: ^Server, c: ^Client, stack: game.Stack) -> Pickup {return .Leave}
	sess := new(Session)
	defer free(sess)
	if !testing.expect(t, session_start(sess, {}, false, with = config)) {
		session_stop(sess)
		return
	}
	defer session_stop(sess)
	_, ok := harness_step_until(&sess.h, proc(data: rawptr) -> bool {
			sess := (^Session)(data)
			return sess.mirror.welcomed && sess.h.srv.clients[0].state == .Playing
		}, sess, 600)
	if !testing.expect(t, ok) {return}
	s := &sess.h.srv
	c := &s.clients[0]
	slot := slot_of(c, pistol)
	if testing.expect(t, slot >= 0, "the pistol did not come back") {
		testing.expect_value(t, c.inventory.slots[slot].data, 0x0207)
	}
	found := false
	it := entities_each(s.home)
	for h in entities_next(&it) {
		if entity_kind(s.home, h) == s.registry.engine.item {
			found = entity_stack(s.home, h)^ == game.Stack{stone, 3, 0, 99}
		}
	}
	testing.expect(t, found, "the stone on the ground lost its data")
}

// slot_of: the first slot holding item (-1: none).
@(private = "file")
slot_of :: proc(c: ^Client, item: game.Item) -> int {
	for st, i in c.inventory.slots {if st.item == item && !game.stack_empty(st) {return i}}
	return -1
}
