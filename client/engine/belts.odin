package engine

import "base:runtime"
import "core:slice"

import "client:render"
import "common:game"
import "common:protocol"

// Belts (common/game/belt.odin): the client's copy of the conveyors near it. The server
// tells a belt's items with its chunk and when one is put on or taken off; between those
// the session steps its belts every tick with the server's own code, so the items move as
// they do there without a message. They are drawn as small cubes of their item's colour
// riding on the belt (the top of a slab), moved on between ticks.

// MAX_BELT_ITEMS_DRAWN: the items on belts drawn a frame, the nearest first past it.
MAX_BELT_ITEMS_DRAWN :: 16384
// BELT_DRAW_DISTANCE: blocks from the eyes past which belt items are not drawn.
BELT_DRAW_DISTANCE :: 64

// Session_Belts: the lanes the session holds, and those awake (moving).
Session_Belts :: struct {
	lanes: map[game.Block_Pos]game.Lane, // (heap)
	awake: map[game.Block_Pos]struct{}, // (heap)
}

belts_destroy :: proc(b: ^Session_Belts) {
	delete(b.lanes)
	delete(b.awake)
	b^ = {}
}

// belt_lane_find: the belt at p as the session holds it (Lane_Find): a belt block of the
// world with a lane kept for it (belts_step keeps one for every belt it may touch first:
// a lookup never adds to the map, so the lanes found stay where they are).
@(private = "file")
belt_lane_find :: proc(
	data: rawptr,
	p: game.Block_Pos,
) -> (
	^game.Lane,
	u16,
	game.Block_Pos,
	bool,
) {
	s := (^Session)(data)
	b, loaded := world_block(&s.world, p)
	t := &s.reg.blocks
	if !loaded || game.block_entity_kind(t, b) != .Belt {return nil, 0, {}, false}
	lane, _ := &s.belts.lanes[p]
	if lane == nil {return nil, 0, {}, false}
	dir, _ := game.facing_vector(t, b)
	return lane, t.types[t.type_of[b]].belt_step, dir, true
}

// belt_lane_keep: a lane kept for the belt at p, if p is one (empty until told otherwise).
@(private = "file")
belt_lane_keep :: proc(s: ^Session, p: game.Block_Pos) {
	b, loaded := world_block(&s.world, p)
	if !loaded || game.block_entity_kind(&s.reg.blocks, b) != .Belt || p in s.belts.lanes {return}
	s.belts.lanes[p] = {}
}

@(private)
apply_belt :: proc(s: ^Session, g: protocol.Received) {
	if g.op == .Remove {return}
	b := &s.belts
	if b.lanes == nil {
		b.lanes = make(map[game.Block_Pos]game.Lane, runtime.heap_allocator())
		b.awake = make(map[game.Block_Pos]struct{}, runtime.heap_allocator())
	}
	p := protocol.key_block(g.key)
	b.lanes[p] = (^protocol.Belt_Record)(g.value).lane
	b.awake[p] = {}
	feeders, n := game.lane_feeders(p, belt_lane_find, s)
	for q in feeders[:n] {b.awake[q] = {}}
}

// belts_chunk: chunk came whole: what its belts carried is old (the server tells it again).
@(private)
belts_chunk :: proc(s: ^Session, chunk: game.Chunk_Pos) {
	gone := make([dynamic]game.Block_Pos, context.temp_allocator)
	for p in s.belts.lanes {if game.chunk_of(p) == chunk {append(&gone, p)}}
	for p in gone {
		delete_key(&s.belts.lanes, p)
		delete_key(&s.belts.awake, p)
	}
}

// belts_step: one tick of the session's awake belts, as the server steps its own.
@(private)
belts_step :: proc(s: ^Session) {
	b := &s.belts
	if len(b.awake) == 0 {return}
	active := make([dynamic]game.Block_Pos, 0, len(b.awake), context.temp_allocator)
	for p in b.awake {append(&active, p)}
	slice.sort_by(active[:], game.block_pos_less)
	clear(&b.awake)
	for p in active {
		b, loaded := world_block(&s.world, p)
		if !loaded {continue}
		dir, _ := game.facing_vector(&s.reg.blocks, b)
		belt_lane_keep(s, p + dir)
	}
	out := game.Lanes_Stepped {
		awake = make([dynamic]game.Block_Pos, context.temp_allocator),
		gave  = make([dynamic]game.Block_Pos, context.temp_allocator),
	}
	game.lanes_step(active[:], belt_lane_find, s, &out)
	for p in out.awake {b.awake[p] = {}}
	for p in out.gave {
		feeders, n := game.lane_feeders(p, belt_lane_find, s)
		for q in feeders[:n] {b.awake[q] = {}}
	}
}

// belts_draw: the items on the session's belts near the eyes, each a cube of its item's
// colour on its belt, moved on by the part of a tick since the last (`between`, 0 to 1)
// where its belt is awake.
belts_draw :: proc(s: ^Session, d: ^render.Entity_Draw, between: f32) {
	eye := s.camera.position
	t := &s.reg.blocks
	drawn := 0
	for p, &lane in s.belts.lanes {
		if lane.count == 0 {continue}
		centre := [3]f64{f64(p.x) + 0.5, f64(p.y), f64(p.z) + 0.5}
		off := centre - eye
		if off.x * off.x + off.z * off.z > BELT_DRAW_DISTANCE * BELT_DRAW_DISTANCE {continue}
		b, loaded := world_block(&s.world, p)
		if !loaded || game.block_entity_kind(t, b) != .Belt {continue}
		dir, _ := game.facing_vector(t, b)
		step := f32(t.types[t.type_of[b]].belt_step) if p in s.belts.awake else 0
		limit := f32(game.LANE_END)
		for it in lane.items[:lane.count] {
			if drawn == MAX_BELT_ITEMS_DRAWN {return}
			at := min(f32(it.at) + step * between, limit)
			limit = max(at - game.LANE_SPACING, 0)
			along := f64(at / 65536 - 0.5)
			pos := centre + {f64(dir.x) * along, 0.5, f64(dir.z) * along}
			render.entity_box(
				d,
				pos,
				0,
				0,
				{-0.11, 0, -0.11},
				{0.11, 0.2, 0.11},
				item_colour(s, it.item),
				.Body,
			)
			drawn += 1
		}
	}
}
