package core

import "base:runtime"
import "core:slice"

import "common:game"
import "common:protocol"

// Belts (common/game/belt.odin): the world's conveyors, stepped each tick by the code the
// clients step their copies with. Only the awake ones are stepped: a belt wakes when an
// item comes on it or leaves it, or the belt it feeds hands an item on, and sleeps when
// nothing on it moved (empty, or its front item waiting at its end). A player is told a
// belt's items with its chunk and whenever the game or a player put or take one (a
// Belt_Record), never as they only move: its client moves them as the server does. What
// belts carry is in the item ledger; a broken belt spills it. Its game moves items on and
// off with belt_put and belt_take (an arm feeding a furnace, a mine's output).

// Belt_Set: the belts awake in a world.
Belt_Set :: struct {
	awake: [dynamic]game.Block_Pos, // (heap; may repeat: sorted and made unique each tick)
	moves: u64, // lane steps run since the world opened (stats)
}

belts_destroy :: proc(b: ^Belt_Set) {
	delete(b.awake)
	b^ = {}
}

// belt_find: the belt at p (a Lane_Find over the world's loaded chunks): one look-up of its
// chunk for both its block and its entity.
@(private = "file")
belt_find :: proc(data: rawptr, p: game.Block_Pos) -> (^game.Lane, u16, game.Block_Pos, bool) {
	w := (^World)(data)
	c := chunks_get(&w.chunks, game.chunk_of(p))
	if c == nil || c.state != .Ready {return nil, 0, {}, false}
	local := game.local_of(p)
	at, found := game.block_entity_find(c.block_entities[:], u16(game.local_index(local)))
	if !found || c.block_entities[at].kind != .Belt {return nil, 0, {}, false}
	b := game.chunk_get(&c.blocks, local)
	t := &w.server.registry.blocks
	dir, _ := game.facing_vector(t, b)
	return &c.block_entities[at].lane, t.types[t.type_of[b]].belt_step, dir, true
}

@(private = "file")
belt_wake :: proc(w: ^World, p: game.Block_Pos) {
	if w.belts.awake.allocator.procedure ==
	   nil {w.belts.awake.allocator = runtime.heap_allocator()}
	append(&w.belts.awake, p)
}

// belt_told: every player who has p's chunk is told the belt's items as they are.
@(private = "file")
belt_told :: proc(w: ^World, p: game.Block_Pos, lane: ^game.Lane) {
	s := w.server
	record := protocol.Belt_Record{lane^}
	chunk := game.chunk_of(p)
	for &c in s.clients {
		if c.state != .Playing || c.world != w || chunk not_in c.has {continue}
		state_put(s, &c, .Belt, &record, protocol.key_of_block(p))
	}
}

// belt_put: item comes on the belt at p, at its start (false: no belt there, or no room).
belt_put :: proc(w: ^World, p: game.Block_Pos, item: game.Item) -> bool {
	lane, _, _, ok := belt_find(w, p)
	if !ok || !game.lane_put(lane, item) {return false}
	block_entity_touch(w, p)
	belt_wake(w, p)
	belt_told(w, p, lane)
	return true
}

// belt_take: the front item leaves the belt at p (false: no belt there, or it is empty).
belt_take :: proc(w: ^World, p: game.Block_Pos) -> (game.Item, bool) {
	lane, _, _, ok := belt_find(w, p)
	if !ok {return game.NO_ITEM, false}
	item, took := game.lane_take(lane)
	if !took {return game.NO_ITEM, false}
	block_entity_touch(w, p)
	belt_wake(w, p)
	belt_feeders_wake(w, p)
	belt_told(w, p, lane)
	return item, true
}

// belt_peek: what the belt at p carries, front first (nil: no belt there). Read only.
belt_peek :: proc(w: ^World, p: game.Block_Pos) -> []game.Lane_Item {
	lane, _, _, ok := belt_find(w, p)
	return lane.items[:lane.count] if ok else nil
}

@(private = "file")
belt_feeders_wake :: proc(w: ^World, p: game.Block_Pos) {
	feeders, n := game.lane_feeders(p, belt_find, w)
	for q in feeders[:n] {belt_wake(w, q)}
}

// belts_sent: c was sent chunk whole: the items on its belts follow it.
@(private)
belts_sent :: proc(s: ^Server, c: ^Client, chunk: ^Chunk) {
	origin := game.chunk_origin(chunk.pos)
	for &e in chunk.block_entities {
		if e.kind != .Belt || e.lane.count == 0 {continue}
		record := protocol.Belt_Record{e.lane}
		state_put(
			s,
			c,
			.Belt,
			&record,
			protocol.key_of_block(origin + game.local_from_index(int(e.local))),
		)
	}
}

// belts_loaded: chunk came from its save (or was built): its belts that carry anything
// wake.
@(private)
belts_loaded :: proc(w: ^World, chunk: ^Chunk) {
	origin := game.chunk_origin(chunk.pos)
	for &e in chunk.block_entities {
		if e.kind == .Belt &&
		   e.lane.count > 0 {belt_wake(w, origin + game.local_from_index(int(e.local)))}
	}
}

// belt_changed: the block at p was or became a belt (built, broken, turned): it and the
// belts feeding it wake.
@(private)
belt_changed :: proc(w: ^World, p: game.Block_Pos) {
	belt_wake(w, p)
	belt_feeders_wake(w, p)
}

// belts_tick: one step of the world's awake belts, lowest position first.
@(private)
belts_tick :: proc(w: ^World) {
	b := &w.belts
	if len(b.awake) == 0 {return}
	slice.sort_by(b.awake[:], game.block_pos_less)
	active := slice.clone(slice.unique(b.awake[:]), context.temp_allocator)
	clear(&b.awake)
	out := game.Lanes_Stepped {
		awake = make([dynamic]game.Block_Pos, context.temp_allocator),
		gave  = make([dynamic]game.Block_Pos, context.temp_allocator),
	}
	// Every chunk a lane may change in is touched first (kept as it was for a save that is
	// capturing it, and saved again): an awake belt's, and its neighbour's across a border.
	touched := game.Chunk_Pos{max(i32), 0, 0}
	for p in active {
		for d in ([5]game.Block_Pos{{0, 0, 0}, {1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1}}) {
			q := p + d
			if game.chunk_of(q) == touched ||
			   (d != {} && game.chunk_of(q) == game.chunk_of(p)) {continue}
			touched = game.chunk_of(q)
			block_entity_touch(w, q)
		}
	}
	game.lanes_step(active, belt_find, w, &out)
	b.moves += u64(len(active))
	for p in out.awake {belt_wake(w, p)}
	for p in out.gave {belt_feeders_wake(w, p)}
}
