package server

import "core:log"
import "core:os"
import "core:slice"

import "../base"
import "../common/game"

// Journal compaction and retention (docs/journal.md). A closed segment older
// than JOURNAL_DETAIL is rewritten once with one entry per run of changes of
// a block by one action (the first old, the last new, the last age), entries
// that changed nothing dropped; segments older than JOURNAL_KEEP, then the
// oldest while the directory is over JOURNAL_MAX_BYTES, are deleted. Both run
// from world_save; the segment the world.cfg records (the newest) is left.

JOURNAL_DETAIL :: 108_000 // ticks (one hour)
JOURNAL_KEEP :: 7 * 24 * 108_000
JOURNAL_MAX_BYTES :: 256 << 20

@(private = "file")
detail_ticks :: proc(s: ^Server) -> u64 {
	return s.config.journal_detail if s.config.journal_detail > 0 else JOURNAL_DETAIL
}

// segment_header reads only the header of segment seq.
@(private = "file")
segment_header :: proc(w: ^World, seq: u32) -> (h: game.Journal_Header, ok: bool) {
	f, err := os.open(segment_path(w, seq), {.Read})
	if err != nil {return}
	defer os.close(f)
	buf: [game.JOURNAL_HEADER_SIZE]u8
	n, _ := os.read(f, buf[:])
	if n != len(buf) {return}
	r := game.journal_read_segment(nil, buf[:], nil)
	return r.header, r.status != .Bad_Header
}

// journal_maintain compacts at most one segment and applies retention.
journal_maintain :: proc(w: ^World) {
	if w.dir == "" || !w.started {return}
	s := w.server
	now := age_of(s)
	segs := journal_segments(w)
	// A segment's newest age is at most the next one's first: it is old
	// enough when that one began before the detail window.
	for seq, i in segs {
		if i + 1 >= len(segs) {break} 	// (the newest stays whole)
		next, ok := segment_header(w, segs[i + 1])
		if !ok || now - min(now, next.first_age) <= detail_ticks(s) {break}
		h, have := segment_header(w, seq)
		if !have || h.flags & game.JOURNAL_COMPACTED != 0 {continue}
		segment_compact(w, seq)
		break
	}
	journal_retain(w, segs)
}

// segment_compact rewrites segment seq compacted.
@(private = "file")
segment_compact :: proc(w: ^World, seq: u32) {
	path := segment_path(w, seq)
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {return}
	out, ok := compact_bytes(w.server.registry, data)
	if !ok {
		log.warnf("server cannot compact a journal segment seq=%d", seq)
		return
	}
	if base.disk_replace(&w.server.store.disk, path, out) == .None {
		log.infof(
			"server compacted a journal segment seq=%d before=%d after=%d",
			seq,
			len(data),
			len(out),
		)
	}
}

@(private = "file")
Compacting :: struct {
	age:     u64,
	ticks:   map[u64]i64, // age -> wall clock ms
	actors:  map[u32]game.Journal_Actor,
	actions: map[u32]game.Journal_Action,
	entries: [dynamic]game.Journal_Entry,
	params:  [dynamic]u64,
	values:  map[Entity_Undo_Key][]u8, // by (pos, action; age 0): the first removal's packed value
}

// compact_bytes returns the compacted form of a segment's bytes (temp allocator).
compact_bytes :: proc(reg: ^game.Registry, data: []u8) -> (out: []u8, ok: bool) {
	c := Compacting {
		ticks   = make(map[u64]i64, 64, context.temp_allocator),
		actors  = make(map[u32]game.Journal_Actor, 16, context.temp_allocator),
		actions = make(map[u32]game.Journal_Action, 16, context.temp_allocator),
		entries = make([dynamic]game.Journal_Entry, context.temp_allocator),
		params  = make([dynamic]u64, context.temp_allocator),
		values  = make(map[Entity_Undo_Key][]u8, 16, context.temp_allocator),
	}
	r := game.journal_read_segment(
		reg,
		data,
		proc(user: rawptr, rec: game.Journal_Record) {
			c := cast(^Compacting)user
			switch v in rec {
			case game.Journal_Tick:
				c.age = v.age
				c.ticks[v.age] = v.unix_ms
			case game.Journal_Actor:
				a := v
				a.name = string(slice.clone(transmute([]u8)v.name, context.temp_allocator))
				c.actors[v.index] = a
			case game.Journal_Action:
				a := v
				a.command = string(slice.clone(transmute([]u8)v.command, context.temp_allocator))
				c.actions[v.id] = a
			case game.Journal_Changes:
				origin := game.chunk_origin(v.chunk)
				for ch in v.changes {
					append(
						&c.entries,
						game.Journal_Entry {
							pos = origin + game.local_from_index(int(ch.index)),
							old = ch.old,
							new = ch.new,
							action = ch.action,
							how = ch.how,
							age = c.age,
						},
					)
				}
			case game.Journal_Save:
			case game.Journal_Params:
				append(&c.params, v.age)
			case game.Journal_Entity:
				// (the first removal of a block by an action: the one its kept
				// entry restores)
				pos := game.chunk_origin(v.chunk) + game.local_from_index(int(v.local))
				key := Entity_Undo_Key{pos, v.action, 0}
				if key not_in c.values {
					c.values[key] = slice.clone(v.value, context.temp_allocator)
				}
			}
		},
		&c,
	)
	if r.status == .Bad_Header {return}

	// One entry per run of changes of a block by one action: its first old,
	// its last new, how and age of the last.
	kept := make([dynamic]game.Journal_Entry, context.temp_allocator)
	last := make(map[game.Block_Pos]int, len(c.entries), context.temp_allocator)
	for e in c.entries {
		if i, seen := last[e.pos]; seen && kept[i].action == e.action {
			kept[i].new, kept[i].how, kept[i].age = e.new, e.how, e.age
			continue
		}
		last[e.pos] = len(kept)
		append(&kept, e)
	}
	// (an entry that changed nothing is dropped; a block changed and changed
	// back by one action leaves no entry, and its neighbours in the chain
	// still agree: the new of one is the old of the next)
	live := make([dynamic]game.Journal_Entry, 0, len(kept), context.temp_allocator)
	for e in kept {if e.old != e.new {append(&live, e)}}
	slice.stable_sort_by(live[:], proc(a, b: game.Journal_Entry) -> bool {return a.age < b.age})

	w := game.Writer{}
	game.writer_init(&w, context.temp_allocator, 1 << 16)
	header := game.Journal_Header {
		seq       = r.header.seq,
		first_age = r.header.first_age,
		flags     = r.header.flags | game.JOURNAL_COMPACTED,
	}
	game.journal_write_header(&w, header)
	for age in c.params {game.journal_write_record(&w, game.Journal_Params{age})}
	declared := make(map[u64]struct{}, 16, context.temp_allocator)
	Keyed :: struct {
		chunk: game.Chunk_Pos,
		order: int,
	}
	changes := make([dynamic]game.Journal_Change, 0, 256, context.temp_allocator)
	for run_start := 0; run_start < len(live); {
		age := live[run_start].age
		run_end := run_start
		for run_end < len(live) && live[run_end].age == age {run_end += 1}
		game.journal_write_record(&w, game.Journal_Tick{age, c.ticks[age]})
		order := make([]Keyed, run_end - run_start, context.temp_allocator)
		for i in run_start ..< run_end {order[i - run_start] = {game.chunk_of(live[i].pos), i}}
		slice.sort_by(order, proc(a, b: Keyed) -> bool {
			if a.chunk != b.chunk {return game.chunk_pos_less(a.chunk, b.chunk)}
			return a.order < b.order
		})
		for start := 0; start < len(order); {
			chunk := order[start].chunk
			clear(&changes)
			end := start
			for end < len(order) &&
			    order[end].chunk == chunk &&
			    len(changes) < game.MAX_CHANGES_PER_RECORD {
				e := live[order[end].order]
				if u64(e.action) not_in declared {
					declared[u64(e.action)] = {}
					if a, known := c.actions[e.action]; known {
						if key := u64(1) << 62 | u64(a.actor); key not_in declared {
							declared[key] = {}
							if who, have := c.actors[a.actor]; have {
								game.journal_write_record(&w, who)
							}
						}
						game.journal_write_record(&w, a)
					}
				}
				append(
					&changes,
					game.Journal_Change {
						u16(game.local_index(game.local_of(e.pos))),
						e.old,
						e.new,
						e.action,
						e.how,
					},
				)
				end += 1
			}
			game.journal_write_record(&w, game.Journal_Changes{chunk, changes[:]})
			for i in start ..< end { 	// the entities its entries removed, under the kept entry's age
				e := live[order[i].order]
				if value, had := c.values[{e.pos, e.action, 0}]; had {
					game.journal_write_record(
						&w,
						game.Journal_Entity {
							chunk,
							u16(game.local_index(game.local_of(e.pos))),
							e.age,
							e.action,
							value,
						},
					)
				}
			}
			start = end
		}
		run_start = run_end
	}
	return w.buf[:], true
}

// journal_retain deletes the segments older than JOURNAL_KEEP, then the
// oldest while the directory is over its size (never the newest).
@(private = "file")
journal_retain :: proc(w: ^World, segs: []u32) {
	s := w.server
	keep := s.config.journal_keep if s.config.journal_keep > 0 else JOURNAL_KEEP
	limit := s.config.journal_max_bytes if s.config.journal_max_bytes > 0 else JOURNAL_MAX_BYTES
	now := age_of(s)
	sizes := make(map[u32]u64, len(segs), context.temp_allocator)
	total := u64(0)
	for seq in segs {
		if info, err := os.stat(segment_path(w, seq), context.temp_allocator); err == nil {
			sizes[seq] = u64(info.size)
			total += u64(info.size)
		}
	}
	for seq, i in segs {
		if i + 1 >= len(segs) {break}
		old := false
		if next, ok := segment_header(w, segs[i + 1]); ok {
			old = now - min(now, next.first_age) > keep
		}
		if !old && total <= limit {break}
		if err := base.disk_remove(&s.store.disk, segment_path(w, seq)); err != .None {
			log.errorf("server cannot remove a journal segment seq=%d error=%v", seq, err)
			break
		}
		log.infof("server deleted a journal segment seq=%d", seq)
		total -= min(total, sizes[seq])
	}
}
