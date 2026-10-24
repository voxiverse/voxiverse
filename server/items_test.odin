package server

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "../game"

@(private = "file")
want_count: int

// M14's exit check for items, two players over UDP: the kit, dropping a
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
		seed        = 21,
		view_radius = 2,
		view_height = 1,
		workers     = 1,
		save_dir    = dir,
		max_players = 4,
		listen      = true,
		generator   = .Classic,
	}
	srv: Server
	if !testing.expect(t, start(&srv, config, {})) {return}
	stopped := false
	defer if !stopped {stop(&srv)}
	for !srv.listening {}
	port := srv.host.socket.port
	stone, dirt := game.item_of_block(.Stone), game.item_of_block(.Dirt)

	alice, bob: Net_Client
	net_connect(&alice, port, "alice")
	net_connect(&bob, port, "bob")
	defer net_close(&alice)
	defer net_close(&bob)
	both := []^Net_Client{&alice, &bob}
	ok := net_wait(t, both, proc(cs: []^Net_Client) -> bool {
		ready :: proc(c: ^Net_Client) -> bool {
			return c.inv_updates > 0 && c.update.acked > 0 && c.update.state.on_ground
		}
		return ready(cs[0]) && ready(cs[1])
	})
	if !testing.expect(t, ok, "the players never landed with their kits") {return}
	testing.expect(t, alice.inventory.slots[0] == {stone, 64}, "no kit")
	testing.expect(t, !game.allowed(alice.grants[:], "items.infinite"))

	// Alice drops all her stone at her feet (looking down); bob, standing
	// there too, picks it up.
	alice.look = {0, -1.5}
	net_wait(t, both, proc(cs: []^Net_Client) -> bool {return false}, 0.2)
	alice.seq += 1
	net_send(&alice, game.Inventory_Request{1, {.Drop, 0, 1}})
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {
		return(
			cs[0].inv_acked == 1 &&
			game.inventory_count(&cs[1].inventory, game.item_of_block(.Stone)) == 128 \
		)
	})
	testing.expectf(t, ok, "bob has %d stone", game.inventory_count(&bob.inventory, stone))
	testing.expect_value(t, game.inventory_count(&alice.inventory, stone), 0)

	// Alice places dirt (slot 1) beside her: one used up.
	net_send(&alice, game.Inventory_Request{2, {.Select, 0, 1}})
	feet := alice.update.state.position
	beside := game.Block_Pos {
		i32(math.floor(feet.x)) + 1,
		i32(math.floor(feet.y)),
		i32(math.floor(feet.z)),
	}
	net_send(&alice, game.Edit{1, alice.seq, beside, .Dirt})
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {
		return(
			1 in cs[0].results &&
			game.inventory_count(&cs[0].inventory, game.item_of_block(.Dirt)) == 63 \
		)
	})
	testing.expect(t, ok && alice.results[1].accepted, "placing did not use one up")
	// She breaks it: it falls at her side; she picks it up.
	net_send(&alice, game.Edit{2, alice.seq, beside, .Air})
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {
		return game.inventory_count(&cs[0].inventory, game.item_of_block(.Dirt)) == 64
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
	net_send(&bob, game.Inventory_Request{1, {.Click, 25, 0}})
	net_send(&bob, game.Inventory_Request{2, {.Take, game.CURSOR_SLOT, int(dirt)}})
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {return cs[1].inv_acked == 2})
	testing.expect(t, ok && bob.inventory == before, "a refused request changed the inventory")

	// Kept: after a restart, each carries what they carried.
	alice_had, bob_had := alice.inventory, bob.inventory
	net_close(&alice)
	net_close(&bob)
	alice, bob = {}, {}
	testing.expect(t, stop(&srv))
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
	if !testing.expect(t, start(&srv, config, {})) {return}
	stopped = false
	for !srv.listening {}
	net_connect(&alice, srv.host.socket.port, "alice")
	net_connect(&bob, srv.host.socket.port, "bob")
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
	_ = want_count
}

// A world saved before players had files: their lines in world.cfg move
// to players/<name>.json at the next save.
@(test)
test_players_move_to_their_files :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "player_files"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	os.make_directory_all(dir)
	old := "format = 2\nseed = 7\ngenerator = classic\ntime = 0.3\nplayer.bea.x = 10.5\nplayer.bea.y = 40\nplayer.bea.z = -3.5\nplayer.bea.yaw = 1\nplayer.bea.pitch = 0.5\nplayer.bea.flying = true\n"
	cfg := filepath.join({dir, WORLD_FILE}, context.temp_allocator) or_else ""
	testing.expect(t, os.write_entire_file(cfg, transmute([]u8)old) == nil)
	srv: Server
	if !testing.expect(
		t,
		start(&srv, {seed = 1, view_radius = 2, view_height = 1, workers = 1, save_dir = dir}, {}),
	) {return}
	testing.expect_value(t, srv.home.params.biome_blend, 0) // (made before biomes blended)
	testing.expect(t, stop(&srv))
	data, err := os.read_entire_file_from_path(
		filepath.join({dir, PLAYERS_DIR, "bea.json"}, context.temp_allocator) or_else "",
		context.temp_allocator,
	)
	if !testing.expect(t, err == nil, "bea.json not written") {return}
	r, ok := player_parse(data)
	testing.expect(
		t,
		ok && r.state.position == {10.5, 40, -3.5} && r.state.flying && r.look == {1, 0.5},
	)
	testing.expect(t, !os.exists(cfg), "the world.cfg from before universes stayed")
	universe, _ := os.read_entire_file_from_path(
		filepath.join({dir, UNIVERSE_FILE}, context.temp_allocator) or_else "",
		context.temp_allocator,
	)
	testing.expect(t, !strings.contains(string(universe), "player."), "universe.cfg has players")
	testing.expect(t, strings.contains(string(universe), "kit = stone 64"), string(universe))
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
	r, ok := player_parse(transmute([]u8)strings.to_string(b))
	testing.expect(t, ok)
	stone := game.item_of_block(.Stone)
	testing.expect_value(t, game.inventory_count(&r.inventory, stone), 64 * game.INVENTORY_SLOTS)
	testing.expect_value(t, r.inventory.selected, game.HOTBAR_SLOTS - 1)
	over := 0
	for st in r.overflow {if st.item == stone {over += st.count}}
	testing.expect_value(t, over, 64 * (36 - game.INVENTORY_SLOTS))
}
