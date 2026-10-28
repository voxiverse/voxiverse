package server

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
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
			set_block(s.worlds[0], d.pos, d.block, test_act(s.worlds[0]))
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
			if e := block_entity_at(w, d.pos); e != nil {d.slots, d.has = e.slots, true}
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

// A chest blown up (a bulk edit, no set_block) loses its entity at once, at the
// pipeline, what it held spilling out: no sweep is needed.
@(test)
test_explosion_removes_the_entity :: proc(t: ^testing.T) {
	srv: Server
	if !testing.expect(t, start(&srv, config(""), {})) {return}
	defer stop(&srv)
	a: Net_Client
	net_connect(&a, srv.host.socket.port, "a")
	defer net_close(&a)
	ok := net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return landed(cs[0])})
	if !testing.expect(t, ok, "never landed") {return}
	pos := beside(&srv, "a")
	put_block(&srv, pos, .Chest)
	d := Block_Data {
		pos = pos,
	}
	made := record_at(&srv, pos)
	testing.expect(t, made.has, "placing the chest made no entity")
	call(
		&srv,
		proc(s: ^Server, data: rawptr) {
			d := (^Block_Data)(data)
			w := s.worlds[0]
			block_entity_at(w, d.pos).slots[3] = {game.item_of_block(test_reg(), .Planks), 5}
			p := d.pos
			bulk_edit(w, Bulk_Edit{shape = Box{p, p}, op = .Carve}, world_act(w, .Explosion))
			d.has = block_entity_at(w, d.pos) != nil // (in the same call: no tick, no sweep)
		},
		&d,
	)
	testing.expect(t, !d.has, "the entity outlived its block")
	pause(t, {&a}, 0.3)
	rec := record_at(&srv, pos)
	testing.expect_value(t, rec.items, 5)
}

// Log_Lines collects what a chunk load logs (a test logger).
@(private = "file")
Log_Lines :: struct {
	lines: [dynamic]string,
}

@(private = "file")
collect_log :: proc(
	data: rawptr,
	level: runtime.Logger_Level,
	text: string,
	options: runtime.Logger_Options,
	location := #caller_location,
) {
	l := (^Log_Lines)(data)
	append(&l.lines, strings.clone(text, context.temp_allocator))
}

// save_chunk_with: a chunk of one block kind with `block` at local {5, 5, 5}, as
// its save holds it, to be loaded at pos.
@(private = "file")
save_chunk_with :: proc(
	w: ^World,
	pos: game.Chunk_Pos,
	block: game.Block,
	entities: []game.Block_Entity,
) {
	array := new(game.Block_Array, context.temp_allocator)
	array^ = {}
	array[game.local_index({5, 5, 5})] = block
	blocks := game.Chunk_Blocks {
		array = array,
	}
	wr: game.Writer
	game.writer_init(&wr, context.temp_allocator)
	game.write_chunk_payload(&wr, &blocks, entities)
	w.saved[pos] = slice.clone(wr.buf[:])
}

// A saved entity whose block is not a container any more (the block was
// changed underneath it, or a pack revised it) is dropped on load: logged with
// its position and kind, what it held leaving through the ledger as orphaned.
@(test)
test_entity_without_block_dropped :: proc(t: ^testing.T) {
	dir := scratch_dir("orphan")
	defer delete(dir)
	defer os.remove_all(dir)
	g, ok := grief_open(t, dir)
	defer grief_close(g)
	if !ok {return}
	s, w := grief_srv(g), grief_world(g)
	planks := game.item_of_block(test_reg(), .Planks)
	orphan := game.Block_Entity {
		local = u16(game.local_index({5, 5, 5})),
		kind  = .Container,
	}
	orphan.slots[3] = {planks, 5}
	pos := game.Chunk_Pos{900, 0, 900}
	save_chunk_with(w, pos, .Stone, {orphan})
	before := s.ledger.entries[planks][.Orphaned]

	lines: Log_Lines
	loud := context.logger
	context.logger = {collect_log, &lines, .Debug, {}}
	loaded := request_chunk(w, pos)
	context.logger = loud
	if !testing.expect(t, loaded, "the chunk did not load") {return}

	c := chunks_get(&w.chunks, pos)
	if !testing.expect(t, c != nil, "the chunk is not there") {return}
	testing.expect_value(t, len(c.block_entities), 0)
	testing.expect_value(t, s.ledger.entries[planks][.Orphaned] - before, -5)
	found := false
	at := game.chunk_origin(pos) + {5, 5, 5}
	for line in lines.lines {
		if strings.contains(line, "without its block dropped") &&
		   strings.contains(line, fmt.tprintf("%v", at)) &&
		   strings.contains(line, "Container") {found = true}
	}
	testing.expect(t, found, "the drop was not logged with position and kind")
}

// The opposite: a chest block saved with no entity gets an empty one.
@(test)
test_block_without_entity_made :: proc(t: ^testing.T) {
	dir := scratch_dir("noentity")
	defer delete(dir)
	defer os.remove_all(dir)
	g, ok := grief_open(t, dir)
	defer grief_close(g)
	if !ok {return}
	w := grief_world(g)
	pos := game.Chunk_Pos{900, 0, 900}
	save_chunk_with(w, pos, .Chest, nil)
	loud := context.logger
	context.logger = log.nil_logger()
	loaded := request_chunk(w, pos)
	context.logger = loud
	if !testing.expect(t, loaded, "the chunk did not load") {return}
	c := chunks_get(&w.chunks, pos)
	if !testing.expect(t, c != nil, "the chunk is not there") {return}
	if !testing.expect_value(t, len(c.block_entities), 1) {return}
	e := c.block_entities[0]
	testing.expect_value(t, int(e.local), game.local_index({5, 5, 5}))
	testing.expect_value(t, e.kind, game.Block_Entity_Kind.Container)
	for st in e.slots {testing.expect(t, game.stack_empty(st), "the new entity is not empty")}
}
