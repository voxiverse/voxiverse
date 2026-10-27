package server

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:testing"

import "../common/game"

@(private = "file")
config :: proc(dir: string) -> Config {
	return {
		seed = 30,
		generator = .Classic,
		rules = quiet_rules(),
		view_radius = 3,
		view_height = 2,
		workers = 2,
		max_players = 4,
		listen = true,
		everyone_cheats = true,
		save_dir = dir,
		no_sheep = true,
	}
}

@(private = "file")
pause :: proc(t: ^testing.T, clients: []^Net_Client, seconds: f64) {
	net_wait(t, clients, proc(cs: []^Net_Client) -> bool {return false}, seconds)
}

@(private = "file")
Block_Data :: struct {
	pos:   game.Block_Pos,
	block: game.Block,
	name:  string,
	slots: [game.CHEST_SLOTS]game.Stack, // read out
	items: int, // dropped item entities' total, read out
	has:   bool, // a record, read out
}

// beside: a block position two blocks from where the named player stands.
@(private = "file")
beside :: proc(srv: ^Server, name: string) -> game.Block_Pos {
	d := Block_Data {
		name = name,
	}
	call(srv, proc(s: ^Server, data: rawptr) {
			d := (^Block_Data)(data)
			if c := client_by_name(s, d.name); c != nil {
				p := c.player.position
				d.pos = {i32(math.floor(p.x)) + 2, i32(math.floor(p.y)), i32(math.floor(p.z))}
			}
		}, &d)
	return d.pos
}

@(private = "file")
put_block :: proc(srv: ^Server, pos: game.Block_Pos, block: game.Block) {
	d := Block_Data {
		pos   = pos,
		block = block,
	}
	call(srv, proc(s: ^Server, data: rawptr) {
			d := (^Block_Data)(data)
			set_block(s.worlds[0], d.pos, d.block)
		}, &d)
}

// record_at: the chest record the world holds at pos, and the item entities
// lying about.
@(private = "file")
record_at :: proc(srv: ^Server, pos: game.Block_Pos) -> Block_Data {
	d := Block_Data {
		pos = pos,
	}
	call(srv, proc(s: ^Server, data: rawptr) {
			d := (^Block_Data)(data)
			w := s.worlds[0]
			if rec, ok := w.containers[d.pos]; ok {d.slots, d.has = rec.slots, true}
			for e in w.entities.list {
				if e.kind == .Item {d.items += e.stack.count}
			}
		}, &d)
	return d
}

@(private = "file")
request :: proc(a: ^Net_Client, n: ^u32, kind: game.Inventory_Action_Kind, slot: int, arg := 0) {
	n^ += 1
	net_send(a, game.Inventory_Request{n^, {kind, slot, arg}})
}

@(private = "file")
open_chest :: proc(t: ^testing.T, srv: ^Server, a: ^Net_Client, pos: game.Block_Pos) -> bool {
	net_send(a, game.Use_Block{pos, 0})
	return net_wait(t, {a}, proc(cs: []^Net_Client) -> bool {return cs[0].inventory.chest_open})
}

// M30: a chest holds what is put in it, kept through save and load; breaking
// it spills everything; one far from its block, or not a chest, opens nothing.
@(test)
test_chest_keeps_and_spills :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "chest"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	srv: Server
	if !testing.expect(t, start(&srv, config(dir), {})) {return}
	stopped := false
	defer if !stopped {stop(&srv)}
	a: Net_Client
	net_connect(&a, srv.host.socket.port, "a")
	defer net_close(&a)
	ok := net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return landed(cs[0])})
	if !testing.expect(t, ok, "never landed") {return}
	pos := beside(&srv, "a")
	// Not a chest (nothing there): it does not open.
	net_send(&a, game.Use_Block{pos, 0})
	pause(t, {&a}, 0.3)
	testing.expect(t, !a.inventory.chest_open, "air opened as a chest")
	put_block(&srv, pos, .Chest)
	// (a new player has a kit of stacks of 64)
	first, second := a.inventory.slots[0], a.inventory.slots[1]
	if !testing.expect(t, open_chest(t, &srv, &a, pos), "the chest did not open") {return}
	n: u32
	request(&a, &n, .Quick_Move, 0)
	request(&a, &n, .Quick_Move, 1)
	ok = net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {
		return cs[0].inventory.chest[0].count == 64 && cs[0].inventory.chest[1].count == 64
	})
	if !testing.expect(t, ok, "the stacks did not go into the chest") {return}
	testing.expect(t, game.stack_empty(a.inventory.slots[0]), "and stayed in the hand")
	request(&a, &n, .Close, game.CURSOR_SLOT)
	ok = net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return !cs[0].inventory.chest_open})
	testing.expect(t, ok, "the chest did not close")
	rec := record_at(&srv, pos)
	testing.expect(t, rec.has && rec.slots[0] == first, "the record lacks the first stack")
	testing.expect(t, rec.slots[1] == second, "or the second")
	// A request naming a chest slot while none is open does nothing.
	request(&a, &n, .Click, game.CHEST_BASE)
	pause(t, {&a}, 0.3)
	testing.expect(t, game.stack_empty(a.inventory.cursor), "a closed chest's slot was taken")

	expect_items_balanced(t, &srv)
	stop(&srv)
	stopped = true

	// Saved and loaded: the same.
	srv2: Server
	if !testing.expect(t, start(&srv2, config(dir), {})) {return}
	defer stop(&srv2)
	b: Net_Client
	net_connect(&b, srv2.host.socket.port, "a")
	defer net_close(&b)
	ok = net_wait(t, {&b}, proc(cs: []^Net_Client) -> bool {return landed(cs[0])})
	if !testing.expect(t, ok, "never landed again") {return}
	rec = record_at(&srv2, pos)
	testing.expect(
		t,
		rec.has && rec.slots[0].count == 64 && rec.slots[1].count == 64,
		"the chest lost its contents over a save",
	)
	// (its block is saved with the world's regions: still there)
	if !testing.expect(t, open_chest(t, &srv2, &b, pos), "the loaded chest did not open") {return}
	testing.expect_value(t, b.inventory.chest[0].count, 64)
	// Broken (by the world): everything spills out and the record is gone; the looker's chest closes.
	put_block(&srv2, pos, .Air)
	ok = net_wait(t, {&b}, proc(cs: []^Net_Client) -> bool {return !cs[0].inventory.chest_open})
	testing.expect(t, ok, "a broken chest stayed open")
	rec = record_at(&srv2, pos)
	testing.expect(t, !rec.has, "the record outlived its block")
	testing.expect_value(t, rec.items, 128)
}

// Two players at one chest see each other's moves and agree with the server.
@(test)
test_two_players_one_chest :: proc(t: ^testing.T) {
	srv: Server
	if !testing.expect(t, start(&srv, config(""), {})) {return}
	defer stop(&srv)
	a, b: Net_Client
	net_connect(&a, srv.host.socket.port, "a")
	net_connect(&b, srv.host.socket.port, "b")
	defer net_close(&a)
	defer net_close(&b)
	ok := net_wait(
		t,
		{&a, &b},
		proc(cs: []^Net_Client) -> bool {return landed(cs[0]) && landed(cs[1])},
	)
	if !testing.expect(t, ok, "never landed") {return}
	pos := beside(&srv, "a")
	put_block(&srv, pos, .Chest)
	if !testing.expect(t, open_chest(t, &srv, &a, pos), "a's chest did not open") {return}
	if !testing.expect(t, open_chest(t, &srv, &b, pos), "b's chest did not open") {return}
	na, nb: u32
	request(&a, &na, .Quick_Move, 0)
	ok = net_wait(t, {&a, &b}, proc(cs: []^Net_Client) -> bool {
		return cs[0].inventory.chest[0].count == 64 && cs[1].inventory.chest[0].count == 64
	})
	if !testing.expect(t, ok, "b did not see a's stone go in") {return}
	// b takes half of it out, a sees what is left.
	request(&b, &nb, .Click_Right, game.CHEST_BASE)
	request(&b, &nb, .Click, 29)
	ok = net_wait(t, {&a, &b}, proc(cs: []^Net_Client) -> bool {
		return cs[0].inventory.chest[0].count == 32 && cs[1].inventory.slots[29].count == 32
	})
	testing.expect(t, ok, "a did not see b's half come out")
	rec := record_at(&srv, pos)
	testing.expect_value(t, rec.slots[0].count, 32)
	testing.expect(
		t,
		a.inventory.chest == rec.slots && b.inventory.chest == rec.slots,
		"the clients disagree with the server",
	)
}

// A record whose block is not there is dropped, what it held spilling out.
@(test)
test_record_without_block_dropped :: proc(t: ^testing.T) {
	srv: Server
	if !testing.expect(t, start(&srv, config(""), {})) {return}
	defer stop(&srv)
	a: Net_Client
	net_connect(&a, srv.host.socket.port, "a")
	defer net_close(&a)
	ok := net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return landed(cs[0])})
	if !testing.expect(t, ok, "never landed") {return}
	pos := beside(&srv, "a")
	d := Block_Data {
		pos = pos,
	}
	call(&srv, proc(s: ^Server, data: rawptr) {
			d := (^Block_Data)(data)
			rec := Container{}
			rec.slots[3] = {game.item_of_block(.Planks), 5}
			s.worlds[0].containers[d.pos] = rec
		}, &d)
	pause(t, {&a}, 0.6)
	rec := record_at(&srv, pos)
	testing.expect(t, !rec.has, "a record without a chest stayed")
	testing.expect_value(t, rec.items, 5)
}
