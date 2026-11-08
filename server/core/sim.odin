package core

import "base:runtime"
import "core:log"
import "core:mem"
import "core:slice"
import "core:time"

import "common:base"
import "common:game"

// The simulation framework: what a block does by itself is data (data/sim/*.json in a
// pack, game.Sim_Rules in the registry). Cells wake, wait in a queue and, when due, run
// the rules of the block they hold.
//
// Updates: a queue of (due tick, position), ordered by tick then position (the same edits
// give the same world on every run), at most one per position, at most UPDATE_BUDGET run
// per tick. An update names a cell, not a rule: the block there picks what runs. Anything
// that changes a block wakes the cells around it (sim_wake); an update whose chunk is not
// loaded is dropped, and a saved chunk's cells wake again when it loads (the blocks that
// wake on Load).

MAX_UPDATES :: 1 << 16 // waiting at once (more are dropped, logged)
UPDATE_BUDGET :: 4096 // run per tick (more wait: the world slows under load rather than the server)

Update :: struct {
	due:    u64,
	pos:    game.Block_Pos,
	action: u32, // the journal action whose update this is (0: the world's, made when it runs)
}

Updates :: struct {
	heap:    []Update, // a binary heap by (due, pos), count used
	count:   int,
	queued:  map[game.Block_Pos]struct{}, // fixed: what is in the heap
	dropped: int, // full: logged once per run of drops
	run:     int, // updates run (stats)
}

updates_init :: proc(u: ^Updates, allocator := context.allocator) -> (err: mem.Allocator_Error) {
	u.heap = make([]Update, MAX_UPDATES, allocator) or_return
	u.queued = base.map_make_fixed(map[game.Block_Pos]struct{}, MAX_UPDATES, allocator) or_return
	return
}

// schedule wakes the block at p in delay ticks (unless already waiting).
schedule :: proc(w: ^World, p: game.Block_Pos, delay: u64, action: Action_Id) {
	s := w.server
	u := &w.updates
	if p in u.queued {return}
	if u.count == MAX_UPDATES {
		if u.dropped ==
		   0 {log.warnf("server block updates full (%d waiting): dropping", MAX_UPDATES)}
		u.dropped += 1
		return
	}
	u.queued[p] = {}
	u.heap[u.count] = {s.tick + delay, p, u32(action)}
	u.count += 1
	sift_up(u.heap[:u.count], u.count - 1)
}

// sim_wake: p and its six neighbours, in this order, are scheduled if their block has
// rules that wake on it: p on Placed or Neighbour, a neighbour on Neighbour, each after
// its block's delay.
sim_wake :: proc(w: ^World, p: game.Block_Pos, action: Action_Id) {
	sim := &w.server.registry.sim
	if !sim.any {return}
	for d in ([7]game.Block_Pos{{0, 0, 0}, {1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}) {
		b, loaded := chunks_block(&w.chunks, p + d)
		if !loaded || int(b) >= len(sim.wakes) {continue}
		wakes := sim.wakes[b]
		woken := .Neighbour in wakes || (d == game.Block_Pos{0, 0, 0} && .Placed in wakes)
		if woken {
			schedule(w, p + d, u64(sim.delay[b]), action)
		}
	}
}

// sim_wake_box schedules the cells in lo..hi and around them that could change (after a
// bulk edit, a saved chunk loading, a new chunk next to cells that were waiting for it:
// only_border, its faces' neighbours).
sim_wake_box :: proc(w: ^World, lo, hi: game.Block_Pos, action: Action_Id, only_border := false) {
	sim := &w.server.registry.sim
	if !sim.any {return}
	// Chunk by chunk, only those with blocks that have rules (only those are restless):
	// a chunk arriving among dry ones looks at nothing.
	a, z := game.chunk_of(lo - 1), game.chunk_of(hi + 1)
	for cy in a.y ..= z.y {
		for cz in a.z ..= z.z {
			for cx in a.x ..= z.x {
				c := chunks_get(&w.chunks, {cx, cy, cz})
				if c == nil || c.state != .Ready || !c.restless {continue}
				origin := game.chunk_origin({cx, cy, cz})
				from := [3]i32 {
					max(lo.x - 1, origin.x),
					max(lo.y - 1, origin.y),
					max(lo.z - 1, origin.z),
				}
				to := [3]i32 {
					min(hi.x + 1, origin.x + game.CHUNK_SIZE - 1),
					min(hi.y + 1, origin.y + game.CHUNK_SIZE - 1),
					min(hi.z + 1, origin.z + game.CHUNK_SIZE - 1),
				}
				for y in from.y ..= to.y {
					for z in from.z ..= to.z {
						for x in from.x ..= to.x {
							inside :=
								x >= lo.x &&
								x <= hi.x &&
								y >= lo.y &&
								y <= hi.y &&
								z >= lo.z &&
								z <= hi.z
							if only_border && inside {continue}
							if sim_restless(w, {x, y, z}) {
								b, _ := chunks_block(&w.chunks, {x, y, z})
								schedule(w, {x, y, z}, u64(sim.delay[b]), action)
							}
						}
					}
				}
			}
		}
	}
}

// sim_restless: a cell whose block wakes on Load and has a rule whose own test says it
// could change.
@(private = "file")
sim_restless :: proc(w: ^World, p: game.Block_Pos) -> bool {
	sim := &w.server.registry.sim
	b, loaded := chunks_block(&w.chunks, p)
	if !loaded || int(b) >= len(sim.wakes) || .Load not_in sim.wakes[b] {return false}
	for r in sim.scheduled[b] {
		if sim.rules[r].is_program {return true}
		switch sim.rules[r].behaviour {
		case .Flow:
			if flow_restless(w, p, r) {return true}
		}
	}
	return false
}

// block_has_rules: whether b has simulation rules.
block_has_rules :: #force_inline proc(w: ^Chunk_Store, b: game.Block) -> bool {
	return w.reg != nil && int(b) < len(w.reg.sim.scheduled) && len(w.reg.sim.scheduled[b]) > 0
}

// block_has_random: whether b has random tick rules.
block_has_random :: #force_inline proc(w: ^Chunk_Store, b: game.Block) -> bool {
	return w.reg != nil && int(b) < len(w.reg.sim.random) && len(w.reg.sim.random[b]) > 0
}

// chunk_random_blocks: count of blocks in the chunk with random rules.
chunk_random_blocks :: proc(w: ^Chunk_Store, blocks: ^game.Chunk_Blocks) -> int {
	if w.reg == nil {return 0}
	if blocks.array == nil {
		return game.CHUNK_VOLUME if block_has_random(w, blocks.uniform) else 0
	}
	count := 0
	for b in blocks.array {
		if block_has_random(w, b) {count += 1}
	}
	return count
}

// chunk_restless: whether any block of the chunk has rules (so waking looks at it).
chunk_restless :: proc(w: ^Chunk_Store, blocks: ^game.Chunk_Blocks) -> bool {
	if w.reg == nil || !w.reg.sim.any {return false}
	s := &w.reg.sim
	has :: #force_inline proc(s: ^game.Sim_Rules, b: game.Block) -> bool {
		return int(b) < len(s.scheduled) && len(s.scheduled[b]) > 0
	}
	if blocks.array == nil {return has(s, blocks.uniform)}
	for b in blocks.array {
		if has(s, b) {return true}
	}
	return false
}

// sim_run_scheduled runs the updates due this tick (up to the budget).
sim_run_scheduled :: proc(w: ^World) {
	s := w.server
	base.profile_scope("block updates")
	u := &w.updates
	if u.dropped > 0 && u.count < MAX_UPDATES / 2 {u.dropped = 0}
	for n := 0; n < UPDATE_BUDGET && u.count > 0 && u.heap[0].due <= s.tick; n += 1 {
		p := u.heap[0].pos
		action := Action_Id(u.heap[0].action)
		u.count -= 1
		u.heap[0] = u.heap[u.count]
		sift_down(u.heap[:u.count], 0)
		delete_key(&u.queued, p)
		u.run += 1
		sim_update(w, p, action)
	}
	// Aged task bypass: starved updates waiting >4 ticks bypass the regular budget
	// up to AGED_BUDGET_CAP while the tick has budget headroom.
	AGED_BUDGET_CAP :: 1024
	for aged := 0;
	    aged < AGED_BUDGET_CAP &&
	    u.count > 0 &&
	    u.heap[0].due + 4 < s.tick &&
	    have_time(s, 2 * time.Millisecond);
	    aged += 1 {
		p := u.heap[0].pos
		action := Action_Id(u.heap[0].action)
		u.count -= 1
		u.heap[0] = u.heap[u.count]
		sift_down(u.heap[:u.count], 0)
		delete_key(&u.queued, p)
		u.run += 1
		sim_update(w, p, action)
	}
}

// sim_update runs the rules of the block at p, in order; a rule that changed the block
// there ends the old block's turn.
@(private = "file")
sim_update :: proc(w: ^World, p: game.Block_Pos, action: Action_Id) {
	sim := &w.server.registry.sim
	b, loaded := chunks_block(&w.chunks, p)
	if !loaded || int(b) >= len(sim.scheduled) {return}
	for r in sim.scheduled[b] {
		if sim.rules[r].is_program {
			act := Act{action, .Rule} if action != 0 else world_act(w, .Rule)
			rule_run(w, p, &sim.rules[r], act)
		} else {
			switch sim.rules[r].behaviour {
			case .Flow:
				flow_update(w, p, r, action)
			}
		}
		if now, _ := chunks_block(&w.chunks, p); now != b {return}
	}
}

// saved_updates: the updates of the heap that are in chunk pos, as Saved_Updates in (due,
// pos) order, with how far each is from now (temp). take: they leave the queue.
@(private = "file")
saved_updates :: proc(w: ^World, pos: game.Chunk_Pos, take: bool) -> []game.Saved_Update {
	u := &w.updates
	found := make([dynamic]Update, context.temp_allocator)
	for i in 0 ..< u.count {
		if game.chunk_of(u.heap[i].pos) == pos {append(&found, u.heap[i])}
	}
	if len(found) == 0 {return nil}
	slice.sort_by(found[:], update_less)
	out := make([]game.Saved_Update, len(found), context.temp_allocator)
	for x, i in found {
		now := w.server.tick
		out[i] = {
			u16(game.local_index(game.local_of(x.pos))),
			u32(x.due - now) if x.due > now else 0,
		}
	}
	if take {
		kept := 0
		for i in 0 ..< u.count {
			x := u.heap[i]
			if game.chunk_of(x.pos) == pos {
				delete_key(&u.queued, x.pos)
				continue
			}
			u.heap[kept] = x
			kept += 1
		}
		u.count = kept
		for i := kept / 2 - 1; i >= 0; i -= 1 {sift_down(u.heap[:kept], i)}
	}
	return out
}

// sim_take_chunk: the updates waiting in chunk pos, taken out of the queue to be saved
// with the chunk as it unloads (temp).
sim_take_chunk :: proc(w: ^World, pos: game.Chunk_Pos) -> []game.Saved_Update {
	return saved_updates(w, pos, true)
}

// sim_waiting: the updates waiting now in each of chunks (a save's capture), left in the
// queue; chunks with none are absent (map and slices from allocator).
sim_waiting :: proc(
	w: ^World,
	chunks: []game.Chunk_Pos,
	allocator: runtime.Allocator,
) -> map[game.Chunk_Pos][]game.Saved_Update {
	out := make(map[game.Chunk_Pos][]game.Saved_Update, allocator)
	if w.updates.count == 0 {return out}
	for pos in chunks {
		if got := saved_updates(w, pos, false);
		   len(got) > 0 {out[pos] = slice.clone(got, allocator)}
	}
	return out
}

// sim_restore schedules a loaded chunk's saved updates again, each as due when saved.
sim_restore :: proc(w: ^World, pos: game.Chunk_Pos, updates: []game.Saved_Update) {
	origin := game.chunk_origin(pos)
	for x in updates {
		l := int(x.local)
		p := origin + game.local_from_index(l)
		schedule(w, p, u64(x.delta), 0)
	}
}

// updates_cancel drops the queued updates for which drop says yes
// (a rollback stops the updates its filter caused).
updates_cancel :: proc(
	w: ^World,
	drop: proc(w: ^World, u: Update, data: rawptr) -> bool,
	data: rawptr,
) {
	u := &w.updates
	kept := 0
	for i in 0 ..< u.count {
		x := u.heap[i]
		if drop(w, x, data) {
			delete_key(&u.queued, x.pos)
			continue
		}
		u.heap[kept] = x
		kept += 1
	}
	u.count = kept
	for i := kept / 2 - 1; i >= 0; i -= 1 {sift_down(u.heap[:kept], i)}
}

@(private = "file")
update_less :: #force_inline proc(a, b: Update) -> bool {
	if a.due != b.due {return a.due < b.due}
	if a.pos.y != b.pos.y {return a.pos.y < b.pos.y}
	if a.pos.z != b.pos.z {return a.pos.z < b.pos.z}
	return a.pos.x < b.pos.x
}

@(private = "file")
sift_up :: proc(h: []Update, i: int) {
	i := i
	for i > 0 {
		parent := (i - 1) / 2
		if !update_less(h[i], h[parent]) {return}
		h[i], h[parent] = h[parent], h[i]
		i = parent
	}
}

@(private = "file")
sift_down :: proc(h: []Update, i: int) {
	i := i
	for {
		l, r := 2 * i + 1, 2 * i + 2
		m := i
		if l < len(h) && update_less(h[l], h[m]) {m = l}
		if r < len(h) && update_less(h[r], h[m]) {m = r}
		if m == i {return}
		h[i], h[m] = h[m], h[i]
		i = m
	}
}

// light_above: the light at q for grass to spread by: 15 under open sky,
// else what the nearest lamp gives (15 less its distance), else 0.
light_above :: proc(w: ^World, q: game.Block_Pos) -> int {
	if column_top(w, q.x, q.z) < q.y {return 15}
	best := 0
	for y in i32(-6) ..= 6 {
		for z in i32(-6) ..= 6 {
			for x in i32(-6) ..= 6 {
				d := int(abs(x) + abs(y) + abs(z))
				if d > 6 {continue}
				b, _ := chunks_block(&w.chunks, q + {x, y, z})
				if b == .Lamp {best = max(best, 15 - d)}
			}
		}
	}
	return best
}
