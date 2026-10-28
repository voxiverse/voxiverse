package server

import "core:fmt"
import "core:log"
import "core:math"
import "core:slice"
import "core:strings"

import "../common/game"

// Rollback, undo and history (docs/journal.md): blocks put back from the
// journal. A rollback is a job over ticks: it plans from the journal, then
// applies up to ROLLBACK_APPLY_PER_TICK blocks a tick, and never overwrites a
// later change by someone else.

ROLLBACK_APPLY_PER_TICK :: 4096
ROLLBACK_LOADS_PER_TICK :: 16
ROLLBACK_FREE_SLOTS :: 64 // chunks it loads only while this many slots are free
ROLLBACK_RING_PER_TICK :: 131072
ROLLBACK_REPORT_TICKS :: 5 * game.TICK_RATE
UNDO_SYNC_ENTRIES :: 4096 // an undo of this many changes or fewer is applied in the same tick

Rollback_Filter :: struct {
	actor:  Maybe(string), // a character's name
	system: Maybe(game.Edit_System), // matched against how an entry was made
	action: Action_Id, // one action (undo and redo)
	since:  u64, // age
	box:    Maybe(Box),
}

@(private = "file")
Run_State :: enum u8 {
	Open, // the newest entries at the position are the filter's: restore it, the run goes on
	Closed, // ... and an older entry that is not the filter's has ended the run
	Blocked, // the newest entry at the position is not the filter's: leave it
}

@(private = "file")
Plan :: struct {
	restore, expect: game.Block,
	restore_from:    Entity_Undo_Key, // the journal entry the restore comes from (what it removed)
	state:           Run_State,
	kept:            bool, // the filter's entries are there, but someone else changed it since
	queued:          bool, // waiting in order
}

Rollback_Report :: struct {
	action:   Action_Id,
	restored: int,
	kept:     int,
	missing:  int,
	done:     bool,
}

Rollback_Job :: struct {
	filter:      Rollback_Filter,
	action:      Action_Id, // the rollback's own
	caller:      string, // owned
	title:       string, // owned
	scanning:    bool,
	ring_only:   bool,
	segments:    []u32, // newest first (disk scan)
	next_seg:    int,
	ring_next:   u64, // the scan's next ring index, going down
	catch_up:    u64, // the ring index of the next entry to fold in
	plan:        map[game.Block_Pos]Plan,
	order:       [dynamic]game.Block_Pos,
	cursor:      int,
	restored:    int,
	missing:     int,
	last_report: u64,
	cancelled:   bool,
}

rollback_free :: proc(w: ^World) {
	job := w.rollback
	if job == nil {return}
	delete(job.plan)
	delete(job.order)
	delete(job.caller)
	delete(job.title)
	delete(job.segments)
	free(job)
	w.rollback = nil
}

// ---- matching ----

@(private = "file")
in_box :: proc(box: Maybe(Box), p: game.Block_Pos) -> bool {
	b, has := box.?
	if !has {return true}
	return(
		p.x >= b.lo.x &&
		p.x <= b.hi.x &&
		p.y >= b.lo.y &&
		p.y <= b.hi.y &&
		p.z >= b.lo.z &&
		p.z <= b.hi.z \
	)
}

@(private = "file")
matches :: proc(
	f: Rollback_Filter,
	e: game.Journal_Entry,
	info: Action_Info,
	known: bool,
) -> bool {
	if f.action != 0 {return e.action == u32(f.action)}
	if name, has := f.actor.?; has {
		if !known || info.kind != .Character || info.actor != name {return false}
	}
	if sys, has := f.system.?; has && e.how != sys {return false}
	return true
}

// ---- the plan ----

// scan_entry folds an entry met going back in time (newest first).
@(private = "file")
scan_entry :: proc(job: ^Rollback_Job, e: game.Journal_Entry, info: Action_Info, known: bool) {
	if e.age < job.filter.since || !in_box(job.filter.box, e.pos) {return}
	if e.action == u32(job.action) {return}
	hit := matches(job.filter, e, info, known)
	pl, seen := &job.plan[e.pos]
	if !seen {
		job.plan[e.pos] = {
			restore      = e.old,
			expect       = e.new,
			restore_from = {e.pos, e.action, e.age},
			state        = .Open if hit else .Blocked,
		}
		return
	}
	switch pl.state {
	case .Open:
		if hit {pl.restore, pl.restore_from = e.old, {e.pos, e.action, e.age}} else {pl.state = .Closed}
	case .Blocked:
		if hit {pl.kept = true} 	// (the position stays as it is)
	case .Closed:
	}
}

// fold_entry folds an entry appended after the scan began (oldest first).
@(private = "file")
fold_entry :: proc(job: ^Rollback_Job, e: game.Journal_Entry, info: Action_Info, known: bool) {
	if e.action == u32(job.action) || !in_box(job.filter.box, e.pos) {return}
	hit := matches(job.filter, e, info, known)
	pl, seen := &job.plan[e.pos]
	if !seen {
		if !hit {return}
		job.plan[e.pos] = {
			restore      = e.old,
			expect       = e.new,
			restore_from = {e.pos, e.action, e.age},
			state        = .Open,
		}
		pl = &job.plan[e.pos]
	} else if hit {
		if pl.state != .Blocked {
			pl.expect = e.new
		} else {
			pl^ = {
				restore      = e.old,
				expect       = e.new,
				restore_from = {e.pos, e.action, e.age},
				state        = .Open,
				queued       = pl.queued,
			}
		}
	} else {
		pl.kept = pl.state != .Blocked
		pl.state = .Blocked
		return
	}
	if !pl.queued {
		pl.queued = true
		append(&job.order, e.pos)
	}
}

// ---- starting ----

// rollback_start begins a rollback; false (and the caller told) if one is
// running already.
rollback_start :: proc(
	s: ^Server,
	c: ^Client,
	f: Rollback_Filter,
	title: string,
	system: game.Edit_System,
	sync := false,
) -> bool {
	w := c.world
	j := &w.journal
	if w.rollback != nil {
		notice(s, c, "&cA rollback is already running here (/rollback status, /rollback cancel)")
		return false
	}
	job := new(Rollback_Job)
	job.filter = f
	job.action = action_begin(w, actor_of(s, c), system, c.command)
	job.caller = strings.clone(client_name(c))
	job.title = strings.clone(title)
	job.scanning = true
	job.ring_only = w.dir == "" || f.action != 0
	job.ring_next = j.head
	job.catch_up = j.head
	job.last_report = s.tick
	job.plan = make(map[game.Block_Pos]Plan, 1024)
	w.rollback = job
	if !job.ring_only {
		journal_flush(w)
		segs := journal_segments(w)
		job.segments = make([]u32, len(segs))
		for seq, i in segs {job.segments[len(segs) - 1 - i] = seq}
	}
	updates_cancel(w, cancel_wanted, job)
	j.report = {
		action = job.action,
	}
	log.infof("server rollback started action=%d by=%s %s", job.action, job.caller, title)
	if sync {
		for w.rollback == job {rollback_step(w)}
	}
	return true
}

@(private = "file")
cancel_wanted :: proc(w: ^World, u: Update, data: rawptr) -> bool {
	job := cast(^Rollback_Job)data
	f := job.filter
	if u.action == 0 {return false}
	if f.action != 0 {return u.action == u32(f.action)}
	if sys, has := f.system.?; has && sys != .Liquid {return false}
	if name, has := f.actor.?; has {
		info, known := action_info(&w.journal, u.action)
		return known && info.kind == .Character && info.actor == name
	}
	return true
}

// ---- over ticks ----

// rollback_tick advances the world's rollback one tick (before changes are
// told, so what it changes goes out in this tick's).
rollback_tick :: proc(w: ^World) {
	if w.rollback != nil {rollback_step(w)}
}

@(private = "file")
rollback_step :: proc(w: ^World) {
	s := w.server
	job := w.rollback
	j := &w.journal
	if job.cancelled {
		rollback_finish(w, "cancelled")
		return
	}
	if job.scanning {
		scan_step(w, job)
		if s.tick - job.last_report >= ROLLBACK_REPORT_TICKS {
			job.last_report = s.tick
			rollback_say(
				w,
				fmt.tprintf(
					"Rollback scanning (action %d): %d positions so far",
					job.action,
					len(job.plan),
				),
			)
		}
		return
	}
	// Catch up: what changed since the scan began.
	if job.catch_up < ring_oldest(j) {job.catch_up = ring_oldest(j)}
	for ; job.catch_up < j.head; job.catch_up += 1 {
		e := ring_at(j, job.catch_up)^
		info, known := action_info(j, e.action)
		fold_entry(job, e, info, known)
	}
	if job.cursor < len(job.order) {slice.sort_by(job.order[job.cursor:], pos_chunk_less)}
	applied, loads := 0, 0
	for job.cursor < len(job.order) && applied < ROLLBACK_APPLY_PER_TICK {
		p := job.order[job.cursor]
		pl := &job.plan[p]
		if pl.state == .Blocked || pl.restore == pl.expect {
			pl.queued = false
			job.cursor += 1
			continue
		}
		chunk := chunks_get(&w.chunks, game.chunk_of(p))
		if chunk == nil || chunk.state != .Ready {
			if !chunk_bring(w, game.chunk_of(p), &loads) {
				if loads >= ROLLBACK_LOADS_PER_TICK {break} 	// (more next tick)
				log.warnf("server rollback cannot find a chunk action=%d pos=%v", job.action, p)
				job.missing += 1
				pl.queued = false
				job.cursor += 1
			}
			continue
		}
		pl.queued = false
		job.cursor += 1
		current, _ := chunks_block(&w.chunks, p)
		switch {
		case current == pl.restore:
		case current != pl.expect:
			pl.kept = true
		case:
			if set_block(w, p, pl.restore, {job.action, report_system(j, job)}) {
				entity_restore(w, p, pl.restore_from)
				job.restored += 1
				applied += 1
			}
		}
	}
	if s.tick - job.last_report >= ROLLBACK_REPORT_TICKS {
		job.last_report = s.tick
		rollback_say(
			w,
			fmt.tprintf(
				"Rollback running (action %d): %d restored, %d left",
				job.action,
				job.restored,
				len(job.order) - job.cursor,
			),
		)
	}
	if job.cursor >= len(job.order) && job.catch_up >= j.head {rollback_finish(w, "done")}
}

// chunk_bring loads a chunk from the save (false: it cannot be, or this tick's
// loads are spent).
@(private = "file")
chunk_bring :: proc(w: ^World, pos: game.Chunk_Pos, loads: ^int) -> bool {
	if loads^ >= ROLLBACK_LOADS_PER_TICK {return false}
	if len(w.chunks.by_pos) + ROLLBACK_FREE_SLOTS > w.server.capacity {return false}
	if !chunk_load_saved(w, pos) {return false}
	loads^ += 1
	return true
}

@(private = "file")
pos_chunk_less :: proc(a, b: game.Block_Pos) -> bool {
	ca, cb := game.chunk_of(a), game.chunk_of(b)
	if ca != cb {return game.chunk_pos_less(ca, cb)}
	return game.block_pos_less(a, b)
}

// scan_step reads the next part of the journal into the plan.
@(private = "file")
scan_step :: proc(w: ^World, job: ^Rollback_Job) {
	j := &w.journal
	if job.ring_only {
		for n := 0; n < ROLLBACK_RING_PER_TICK; n += 1 {
			if job.ring_next <= ring_oldest(j) {job.scanning = false; break}
			job.ring_next -= 1
			e := ring_at(j, job.ring_next)^
			if e.age < job.filter.since {job.scanning = false; break}
			info, known := action_info(j, e.action)
			scan_entry(job, e, info, known)
		}
		finish_scan(job)
		return
	}
	if job.next_seg >= len(job.segments) {
		job.scanning = false
		finish_scan(job)
		return
	}
	seq := job.segments[job.next_seg]
	job.next_seg += 1
	seg, ok := segment_load(w, seq)
	if !ok {
		log.warnf("server rollback cannot read a journal segment seq=%d", seq)
		return
	}
	#reverse for e in seg.entries {
		info, known := seg.actions[e.action]
		scan_entry(job, e, info, known)
	}
	if seg.header.first_age <= job.filter.since {job.scanning = false}
	finish_scan(job)
}

// finish_scan: the plan is whole: its positions, sorted, are what is applied.
@(private = "file")
finish_scan :: proc(job: ^Rollback_Job) {
	if job.scanning {return}
	for p, &pl in job.plan {
		if pl.state != .Blocked && pl.restore != pl.expect {
			pl.queued = true
			append(&job.order, p)
		}
	}
	slice.sort_by(job.order[:], pos_chunk_less)
}

// rollback_say tells the caller (if still there) and the log.
@(private = "file")
rollback_say :: proc(w: ^World, text: string) {
	s := w.server
	job := w.rollback
	log.infof("server %s", text)
	if c := client_by_name(s, job.caller); c != nil && c.state == .Playing {notice(s, c, text)}
}

@(private = "file")
rollback_finish :: proc(w: ^World, how: string) {
	job := w.rollback
	j := &w.journal
	kept := 0
	shown := 0
	for p, pl in job.plan {
		if !pl.kept {continue}
		kept += 1
		if shown < 5 {
			shown += 1
			log.infof("server rollback kept a block action=%d pos=%v", job.action, p)

		}
	}
	j.report = {job.action, job.restored, kept, job.missing, true}
	rollback_say(
		w,
		fmt.tprintf(
			"Rollback %s (action %d): %d restored, %d kept (changed by others since), %d missing",
			how,
			job.action,
			job.restored,
			kept,
			job.missing,
		),
	)
	rollback_free(w)
}

// report_system: a rollback's changes are made as Rollback, an undo as Undo,
// a redo as Redo (the action's own system).
report_system :: proc(j: ^Journal, job: ^Rollback_Job) -> game.Edit_System {
	if a := action_live(j, job.action); a != nil {return a.system}
	return .Rollback
}

// ---- commands ----

// parse_where reads `radius <n> | sel | world` into a box (none: the whole
// world); !ok: a usage error; said: c was told why not.
@(private = "file")
parse_where :: proc(
	s: ^Server,
	c: ^Client,
	words: []string,
	default_sel: bool,
) -> (
	box: Maybe(Box),
	ok, said: bool,
) {
	switch {
	case len(words) == 0:
		if default_sel {return where_selection(s, c)}
		return nil, true, false
	case words[0] == "world" && len(words) == 1 && !default_sel:
		return nil, true, false
	case words[0] == "sel" && len(words) == 1:
		return where_selection(s, c)
	case words[0] == "radius" && len(words) == 2:
		n, parsed := parse_count(words[1], 256)
		if !parsed {return nil, false, false}
		p := [3]i32 {
			i32(math.floor(c.player.position.x)),
			i32(math.floor(c.player.position.y)),
			i32(math.floor(c.player.position.z)),
		}
		return Box{p - i32(n), p + i32(n)}, true, false
	}
	return nil, false, false
}

@(private = "file")
where_selection :: proc(s: ^Server, c: ^Client) -> (box: Maybe(Box), ok, said: bool) {
	b, has := selection_box(c)
	if !has {
		notice(s, c, "&cSelect a box first (/pos1, /pos2)")
		return nil, true, true
	}
	return b, true, false
}

@(private = "file")
parse_count :: proc(text: string, most: int) -> (n: int, ok: bool) {
	for ch in text {
		if ch < '0' || ch > '9' {return}
		n = n * 10 + int(ch - '0')
		if n > most {return}
	}
	return n, len(text) > 0 && n >= 1
}

// admin_rollback: /rollback player|system|area ... | status | cancel.
admin_rollback :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	w := c.world
	switch args[0] {
	case "status":
		job := w.rollback
		if job == nil {
			r := w.journal.report
			if r.action == 0 {notice(s, c, "No rollback has run here")} else {
				notice(
					s,
					c,
					fmt.tprintf(
						"Last rollback (action %d): %d restored, %d kept, %d missing",
						r.action,
						r.restored,
						r.kept,
						r.missing,
					),
				)
			}
			return true
		}
		notice(
			s,
			c,
			fmt.tprintf(
				"Rollback running (action %d): %s; %d restored, %d positions planned",
				job.action,
				job.title,
				job.restored,
				len(job.order),
			),
		)
		return true
	case "cancel":
		if w.rollback == nil {
			notice(s, c, "No rollback is running")
		} else {
			w.rollback.cancelled = true
		}
		return true
	}
	f: Rollback_Filter
	rest: []string
	system: game.Edit_System = .Rollback
	title: string
	box: Maybe(Box)
	ok, said: bool
	ticks: u64
	switch args[0] {
	case "player":
		if len(args) < 3 {return false}
		f.actor = args[1]
		ticks = duration_ticks(args[2]) or_return
		rest = args[3:]
		box, ok, said = parse_where(s, c, rest, false)
		title = fmt.tprintf("player %s", args[1])
	case "system":
		if len(args) < 3 {return false}
		f.system = system_by_name(args[1]) or_return
		ticks = duration_ticks(args[2]) or_return
		rest = args[3:]
		box, ok, said = parse_where(s, c, rest, false)
		title = fmt.tprintf("system %s", args[1])
	case "area":
		if len(args) < 2 {return false}
		ticks = duration_ticks(args[1]) or_return
		rest = args[2:]
		box, ok, said = parse_where(s, c, rest, true)
		title = "area"
	case:
		return false
	}
	if said {return true}
	if !ok {return false}
	now := age_of(s)
	f.since = now - min(now, ticks)
	f.box = box
	if oldest, has := oldest_age(w); has && f.since < oldest {
		notice(s, c, fmt.tprintf("History starts %s; using that", age_text(s, oldest)))
		f.since = oldest
	}
	rollback_start(s, c, f, title, system)
	return true
}

// oldest_age: the age the journal's records begin at (when it has any).
@(private = "file")
oldest_age :: proc(w: ^World) -> (age: u64, ok: bool) {
	j := &w.journal
	if w.dir != "" {
		if segs := journal_segments(w); len(segs) > 0 {
			if seg, loaded := segment_load(w, segs[0]); loaded {return seg.header.first_age, true}
		}
	}
	if j.head > ring_oldest(j) {return ring_at(j, ring_oldest(j)).age, true}
	return
}

@(private = "file")
duration_ticks :: proc(text: string) -> (ticks: u64, ok: bool) {
	seconds := duration_parse(text) or_return
	return u64(seconds) * game.TICK_RATE, true
}

@(private = "file")
system_by_name :: proc(name: string) -> (game.Edit_System, bool) {
	for sys in game.Edit_System {
		if strings.equal_fold(fmt.tprint(sys), name) ||
		   strings.equal_fold(
			   strings.to_lower(fmt.tprint(sys), context.temp_allocator),
			   name,
		   ) {return sys, true}
	}
	return {}, false
}

// admin_undo: /undo [n] undoes the caller's own last n actions.
admin_undo :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	n := 1
	if len(args) > 0 {
		parsed: bool
		if n, parsed = parse_count(args[0], UNDO_DEPTH); !parsed {return false}
	}
	undo_run(s, c, n, redo = false)
	return true
}

// admin_redo: /redo [n] does again what the caller undid.
admin_redo :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	n := 1
	if len(args) > 0 {
		parsed: bool
		if n, parsed = parse_count(args[0], UNDO_DEPTH); !parsed {return false}
	}
	undo_run(s, c, n, redo = true)
	return true
}

@(private = "file")
undo_run :: proc(s: ^Server, c: ^Client, n: int, redo: bool) {
	w := c.world
	j := &w.journal
	actor := actor_index_of(j, actor_of(s, c))
	stacks, has := &j.undo[actor]
	if !has {
		notice(s, c, "Nothing to redo" if redo else "Nothing to undo")
		return
	}
	stack := &stacks.redo if redo else &stacks.done
	done := 0
	for done < n && len(stack) > 0 {
		id := pop(stack)
		a := action_live(j, Action_Id(id))
		if a == nil || a.first == 0 || j.head - (a.first - 1) > u64(len(j.entries)) {
			notice(s, c, "&cToo old to undo; use /rollback")
			clear(stack)
			return
		}
		system: game.Edit_System = .Redo if redo else .Undo
		if w.rollback != nil {
			append(stack, id)
			notice(s, c, "&cA rollback is running; try again when it is done")
			return
		}
		sync := a.entries <= UNDO_SYNC_ENTRIES
		if !rollback_start(
			s,
			c,
			{action = Action_Id(id), box = nil},
			fmt.tprintf("%s action %d", "redo" if redo else "undo", id),
			system,
			sync,
		) {
			append(stack, id)
			return
		}
		made := w.journal.report.action
		// What was undone can be done again (the Undo action's entries are
		// rolled back), and what was redone can be undone again (the Redo's).
		if u := action_live(j, made); u != nil {
			append(&stacks.done if redo else &stacks.redo, u32(made))
		}
		done += 1
		if !sync {
			notice(s, c, "Big undo: running as a rollback")
			return
		}
	}
	if done == 0 {notice(s, c, "Nothing to redo" if redo else "Nothing to undo")}
}

@(private = "file")
actor_index_of :: proc(j: ^Journal, a: Actor) -> u32 {
	if i, ok := j.actor_keys[actor_key(a.kind, a.name)]; ok {return i}
	return max(u32)
}

// admin_history: /history <x y z> lists the last changes at a block.
admin_history :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	n: [3]i32
	parse_coords(args, n[:]) or_return
	j := &c.world.journal
	lines := make([dynamic]string, context.temp_allocator)
	for i := j.head; i > ring_oldest(j) && len(lines) < 8; i -= 1 {
		e := ring_at(j, i - 1)^
		if e.pos != n {continue}
		info, known := action_info(j, e.action)
		who := info.actor if known && info.kind != .World else "world"
		append(
			&lines,
			fmt.tprintf(
				"%s %s %s: %s -> %s (action %d)",
				age_text(s, e.age),
				who,
				strings.to_lower(fmt.tprint(e.how), context.temp_allocator),
				game.block_name(s.registry, e.old),
				game.block_name(s.registry, e.new),
				e.action,
			),
		)
	}
	if len(lines) == 0 {
		notice(s, c, fmt.tprintf("No recorded changes at %d %d %d", n.x, n.y, n.z))
		return true
	}
	for l in lines {notice(s, c, l)}
	return true
}
