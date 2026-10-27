package server

import "base:intrinsics"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

import "../common/game"

// The edit journal (docs/journal.md): every block a world's state changes,
// who caused it (an action, by an actor, through a system) and how. One
// pipeline writes it: set_block and bulk_edit take the cause (an Act), check
// admit, write the block and call journal_entry. A ring in memory keeps the
// recent entries; a world with a save directory also appends them to segment
// files (journal/00000001.vxj, ...), which rollback and replay read.

JOURNAL_MEMORY :: 1 << 18 // entries in the ring (8 MiB)
JOURNAL_SEGMENT_BYTES :: 4 << 20
JOURNAL_FLUSH_TICKS :: 30
JOURNAL_FLUSH_BYTES :: 64 * 1024
ACTIONS_PRUNE_TICKS :: 300
UNDO_DEPTH :: 32
JOURNAL_DIR :: "journal"

Action_Id :: distinct u32

// Act: the cause a block change is made with.
Act :: struct {
	action: Action_Id,
	how:    game.Edit_System,
}

Actor :: struct {
	kind:   game.Actor_Kind,
	name:   string,
	bypass: bool, // may edit protected regions
}

Admit :: enum u8 {
	Yes,
	Protected,
}

@(private = "file")
Actor_Entry :: struct {
	kind: game.Actor_Kind,
	name: string, // owned
}

// Live_Action: an action in memory, with what undo and the quotas need.
Live_Action :: struct {
	using rec: game.Journal_Action, // command: owned
	entries:   u32, // changes made under it
	first:     u64, // 1 + the ring index of its first entry (0: none yet)
}

Undo_Stacks :: struct {
	done: [dynamic]u32, // action ids, oldest first
	redo: [dynamic]u32,
}

Journal :: struct {
	entries:      []game.Journal_Entry, // a ring
	head:         u64, // entries ever appended this session
	actions:      [dynamic]Live_Action, // ids actions_base ..< next_action
	actions_base: u32,
	next_action:  u32,
	actors:       [dynamic]Actor_Entry, // index 0: the world
	actor_keys:   map[string]u32, // kind byte + name -> index (keys owned)
	undo:         map[u32]Undo_Stacks, // by actor index
	tick_actions: [game.Edit_System]Action_Id, // the world's own action per system this tick
	tick_hash:    game.Hasher, // a stepped server's entries and actions of this tick
	// On disk (only with a save directory):
	pending:      [dynamic]game.Journal_Entry, // appended this tick, not encoded yet
	out:          game.Writer, // encoded records, not yet written
	out_age:      u64, // the age of the first record in out
	file:         ^os.File, // the open segment
	seq:          u32, // the segment records go to
	file_bytes:   u64, // written to the open segment
	declared:     map[u64]struct{}, // actors (bit 62) and actions declared in this segment
	last_tick:    u64, // the age of the last Tick record encoded (+1; 0: none in this segment)
	last_flush:   u64, // the server tick of the last write
	// Tests:
	cost_cycles:  u64, // Config.journal_timed: cycles spent in the journal
	report:       Rollback_Report, // the newest rollback's
}

// Where a world's journal resumes after a start: what its world.cfg says.
Journal_Resume :: struct {
	known:       bool,
	segment:     u32,
	offset:      u64,
	next_action: u32,
}

// age_of: the universe's tick count across runs.
age_of :: proc(s: ^Server) -> u64 {return s.age_base + s.tick}

// Config.journal_timed: the journal's time is counted in cycles of the
// processor's counter (a clock read costs more than a journal_entry call).
@(private = "file")
timed :: proc(s: ^Server) -> u64 {
	return u64(intrinsics.read_cycle_counter()) if s.config.journal_timed else 0
}

@(private = "file")
spent :: proc(w: ^World, from: u64) {
	if w.server.config.journal_timed {
		w.journal.cost_cycles += u64(intrinsics.read_cycle_counter()) - from
	}
}

// journal_init makes w's journal (its world is started: the arena exists).
journal_init :: proc(w: ^World, arena: mem.Allocator) {
	s := w.server
	j := &w.journal
	size := s.config.journal_memory if s.config.journal_memory > 0 else JOURNAL_MEMORY
	j.entries = make([]game.Journal_Entry, size, arena)
	j.tick_hash = game.hasher_make()
	j.next_action = max(w.journal_resume.next_action, 1)
	j.actions_base = j.next_action
	append(&j.actors, Actor_Entry{}) // the world
	j.actor_keys[strings.clone(actor_key(.World, ""))] = 0
	if w.dir != "" {
		game.writer_init(&j.out, capacity = 1 << 16)
		journal_resume(w)
	}
}

journal_close :: proc(w: ^World) {
	j := &w.journal
	if w.started && w.dir != "" {
		journal_flush(w)
		if j.file != nil {os.close(j.file)}
	}
	for a in j.actions {delete(a.command)}
	delete(j.actions)
	for a in j.actors {delete(a.name)}
	delete(j.actors)
	for k in j.actor_keys {delete(k)}
	delete(j.actor_keys)
	for _, &u in j.undo {
		delete(u.done)
		delete(u.redo)
	}
	delete(j.undo)
	delete(j.pending)
	delete(j.declared)
	game.writer_destroy(&j.out)
	j^ = {}
}

actor_key :: proc(kind: game.Actor_Kind, name: string) -> string {
	return strings.concatenate({string([]u8{u8(kind)}), name}, context.temp_allocator)
}

// actor_index: the journal's index of an actor (made when first seen).
@(private = "file")
actor_index :: proc(j: ^Journal, a: Actor) -> u32 {
	key := actor_key(a.kind, a.name)
	if i, ok := j.actor_keys[key]; ok {return i}
	i := u32(len(j.actors))
	name := a.name[:min(len(a.name), game.MAX_ACTOR_NAME)]
	append(&j.actors, Actor_Entry{a.kind, strings.clone(name)})
	j.actor_keys[strings.clone(key)] = i
	return i
}

// actor_of: a client's character as the actor of what it does.
actor_of :: proc(s: ^Server, c: ^Client) -> Actor {
	return {.Character, client_name(c), allowed(s, c, "world.protect.bypass")}
}

// action_begin makes an action: one cause, whose entries and consequences
// carry its id.
action_begin :: proc(
	w: ^World,
	actor: Actor,
	system: game.Edit_System,
	command := "",
) -> Action_Id {
	s := w.server
	from := timed(s)
	defer spent(w, from)
	j := &w.journal
	cmd := command[:min(len(command), game.MAX_ACTION_COMMAND)]
	for len(cmd) < len(command) && len(cmd) > 0 && command[len(cmd)] & 0xc0 == 0x80 {
		cmd = cmd[:len(cmd) - 1] // (not in the middle of a character)
	}
	rec := Live_Action {
		id      = j.next_action,
		age     = age_of(s),
		actor   = actor_index(j, actor),
		system  = system,
		bypass  = actor.bypass,
		command = strings.clone(cmd),
	}
	j.next_action += 1
	append(&j.actions, rec)
	if s.config.stepped {
		h := &j.tick_hash
		game.hasher_mix(h, u64(rec.id) | u64(rec.actor) << 32)
		game.hasher_mix(h, u64(rec.system) | u64(u8(rec.bypass)) << 8 | rec.age << 16)
		game.hasher_bytes(h, transmute([]u8)rec.command)
		game.hasher_bytes(h, transmute([]u8)j.actors[rec.actor].name)
	}
	return Action_Id(rec.id)
}

// action_world: the world's own action for system in this tick, made on
// first use (random ticks and flows do not make an action per block).
action_world :: proc(w: ^World, system: game.Edit_System) -> Action_Id {
	j := &w.journal
	if j.tick_actions[system] == 0 {j.tick_actions[system] = action_begin(w, {}, system)}
	return j.tick_actions[system]
}

// world_act: the world's own cause for system.
world_act :: proc(w: ^World, system: game.Edit_System) -> Act {
	return {action_world(w, system), system}
}

action_live :: proc(j: ^Journal, id: Action_Id) -> ^Live_Action {
	if u32(id) < j.actions_base || u32(id) >= j.next_action {return nil}
	return &j.actions[u32(id) - j.actions_base]
}

// act_current: act, with an action that has been freed replaced by the
// world's (so memory and disk always agree).
act_current :: proc(w: ^World, act: Act) -> Act {
	if act.action != 0 && action_live(&w.journal, act.action) != nil {return act}
	return world_act(w, act.how)
}

// admit: whether the actor of act may change the block at p. The one place
// a change can be refused for who caused it (region protection, M45b;
// capabilities and budgets, M52).
admit :: proc(w: ^World, act: Act, p: game.Block_Pos) -> Admit {
	return .Yes
}

ring_at :: proc(j: ^Journal, i: u64) -> ^game.Journal_Entry {
	return &j.entries[i % u64(len(j.entries))]
}

// ring_oldest: the index of the oldest entry still in the ring.
ring_oldest :: proc(j: ^Journal) -> u64 {
	return j.head - min(j.head, u64(len(j.entries)))
}

// journal_entry records that the block at p changed from old to new.
journal_entry :: proc(w: ^World, act: Act, p: game.Block_Pos, old, new: game.Block) {
	from := timed(w.server)
	defer spent(w, from)
	one := [1]game.Journal_Entry{{pos = p, old = old, new = new}}
	journal_append(w, act, one[:])
}

// journal_batch records many changes made by one act (a bulk edit's chunk):
// entries hold pos, old and new.
journal_batch :: proc(w: ^World, act: Act, entries: []game.Journal_Entry) {
	from := timed(w.server)
	defer spent(w, from)
	journal_append(w, act, entries)
}

@(private = "file")
journal_append :: proc(w: ^World, act: Act, entries: []game.Journal_Entry) {
	s := w.server
	j := &w.journal
	if len(entries) == 0 {return}
	age := age_of(s)
	a := action_live(j, act.action)
	if a != nil && a.first == 0 {
		a.first = j.head + 1
		undo_push(j, a)
	}
	hashing := s.config.stepped
	size := u64(len(j.entries))
	for &e in entries {
		e.action, e.how, e.age = u32(act.action), act.how, age
		j.entries[j.head % size] = e
		j.head += 1
		if hashing {game.entry_hash(&j.tick_hash, e)}
	}
	if a != nil {a.entries += u32(len(entries))}
	if w.dir != "" {append(&j.pending, ..entries)}
}

// undo_push notes a character's action in its undo stack; a new action of
// its own clears what it could redo.
@(private = "file")
undo_push :: proc(j: ^Journal, a: ^Live_Action) {
	if a.actor == 0 {return}
	switch a.system {
	case .Undo, .Redo, .Rollback:
		return
	case .Hand,
	     .Till,
	     .Command,
	     .Structure,
	     .Explosion,
	     .Liquid,
	     .Random_Tick,
	     .Support,
	     .Gate,
	     .Graze:
	}
	u, has := &j.undo[a.actor]
	if !has {
		j.undo[a.actor] = {}
		u = &j.undo[a.actor]
	}
	append(&u.done, a.id)
	if len(u.done) > UNDO_DEPTH {ordered_remove(&u.done, 0)}
	clear(&u.redo)
}

// journal_tick runs at the end of every tick: encode what changed, write it
// when due, forget the tick's world actions, free actions nobody refers to.
journal_tick :: proc(w: ^World) {
	s := w.server
	j := &w.journal
	if !w.started {return}
	if w.dir != "" {
		journal_encode(w)
		if len(j.out.buf) >= JOURNAL_FLUSH_BYTES || s.tick - j.last_flush >= JOURNAL_FLUSH_TICKS {
			journal_flush(w)
		}
	}
	j.tick_actions = {}
	if s.tick % ACTIONS_PRUNE_TICKS == 0 {actions_prune(w)}
}

// actions_prune frees the actions below the smallest id that a ring entry,
// a queued update or a live entity still names.
@(private = "file")
actions_prune :: proc(w: ^World) {
	j := &w.journal
	lowest := j.next_action
	for i := ring_oldest(j); i < j.head; i += 1 {
		if a := ring_at(j, i).action; a != 0 {lowest = min(lowest, a)}
	}
	u := &w.updates
	for k in 0 ..< u.count {if a := u.heap[k].action; a != 0 {lowest = min(lowest, a)}}
	for &e in w.entities.list {if e.action != 0 {lowest = min(lowest, e.action)}}
	if lowest <= j.actions_base {return}
	n := int(lowest - j.actions_base)
	for a in j.actions[:n] {delete(a.command)}
	remove_range(&j.actions, 0, n)
	j.actions_base = lowest
}

// ---- on disk ----

journal_dir :: proc(w: ^World) -> string {
	return filepath.join({w.dir, JOURNAL_DIR}, context.temp_allocator) or_else JOURNAL_DIR
}

segment_path :: proc(w: ^World, seq: u32) -> string {
	name := fmt.tprintf("%08d.vxj", seq)
	return filepath.join({journal_dir(w), name}, context.temp_allocator) or_else name
}

// journal_segments: the sequence numbers of the segment files, ascending.
journal_segments :: proc(w: ^World) -> []u32 {
	seqs := make([dynamic]u32, context.temp_allocator)
	entries, err := os.read_all_directory_by_path(journal_dir(w), context.temp_allocator)
	if err != nil {return seqs[:]}
	for e in entries {
		if len(e.name) != 12 || !strings.has_suffix(e.name, ".vxj") {continue}
		if n, ok := strconv.parse_uint(e.name[:8], 10); ok {append(&seqs, u32(n))}
	}
	slice.sort(seqs[:])
	return seqs[:]
}

// journal_resume makes the journal agree with the save: segments after the
// one the save recorded are deleted, and it is cut at the recorded offset
// (the loaded regions do not have the later edits).
@(private = "file")
journal_resume :: proc(w: ^World) {
	j := &w.journal
	r := w.journal_resume
	os.make_directory_all(journal_dir(w))
	last := u32(0)
	for seq in journal_segments(w) {
		path := segment_path(w, seq)
		if !r.known || seq > r.segment {
			if err := os.remove(path); err != nil {
				log.errorf("server cannot remove a journal segment path=%s error=%v", path, err)
			}
			continue
		}
		last = seq
		if seq == r.segment {journal_cut(path, r.offset)}
	}
	j.seq = last
	if last > 0 { 	// (a save records where the journal ends: here, until something is written)
		data, _ := os.read_entire_file_from_path(segment_path(w, last), context.temp_allocator)
		j.file_bytes = u64(len(data))
	}
}

// journal_cut truncates a segment to offset (or to its last good record when
// the file is shorter than the save says).
@(private = "file")
journal_cut :: proc(path: string, saved: u64) {
	offset := saved
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {return}
	size := u64(len(data))
	if size < offset {
		read := game.journal_read_segment(data, nil)
		log.warnf(
			"server journal segment is shorter than its save path=%s have=%d saved=%d",
			path,
			size,
			offset,
		)
		offset = u64(read.valid_bytes)
		if offset == size {return}
	} else if size == offset {
		return
	}
	f, open_err := os.open(path, {.Write})
	if open_err != nil {
		log.errorf("server cannot open a journal segment path=%s error=%v", path, open_err)
		return
	}
	defer os.close(f)
	if cut_err := os.truncate(f, i64(offset)); cut_err != nil {
		log.errorf("server cannot cut a journal segment path=%s error=%v", path, cut_err)
	}
}

@(private = "file")
declare_key_actor :: proc(i: u32) -> u64 {return 1 << 62 | u64(i)}

// journal_encode turns the entries appended since the last encode into
// records: a Tick, the actors and actions they name (first use in this
// segment), and Changes grouped by chunk in the order appended.
journal_encode :: proc(w: ^World) {
	s := w.server
	j := &w.journal
	if len(j.pending) == 0 {return}
	from := timed(s)
	defer spent(w, from)
	// A segment ends at its size: the next record begins another.
	limit :=
		u64(s.config.journal_segment_bytes) if s.config.journal_segment_bytes > 0 else JOURNAL_SEGMENT_BYTES
	if j.seq > 0 && j.file != nil && j.file_bytes + u64(len(j.out.buf)) >= limit {
		journal_write_out(w)
		os.close(j.file)
		j.file = nil // (the next flush begins the next segment)
		clear(&j.declared)
		j.last_tick = 0
	}
	if len(j.out.buf) == 0 {j.out_age = j.pending[0].age}
	Keyed :: struct {
		chunk: game.Chunk_Pos,
		order: int,
	}
	changes := make([dynamic]game.Journal_Change, 0, 256, context.temp_allocator)
	// One run per age (entries are appended in age order: a command run
	// between two ticks is in the tick after it), grouped by chunk inside.
	for run_start := 0; run_start < len(j.pending); {
		run_age := j.pending[run_start].age
		run_end := run_start
		for run_end < len(j.pending) && j.pending[run_end].age == run_age {run_end += 1}
		if j.last_tick != run_age + 1 {
			game.journal_write_record(
				&j.out,
				game.Journal_Tick{run_age, time.to_unix_nanoseconds(time.now()) / 1_000_000},
			)
			j.last_tick = run_age + 1
		}
		order := make([]Keyed, run_end - run_start, context.temp_allocator)
		for i in run_start ..< run_end {order[i - run_start] = {game.chunk_of(j.pending[i].pos), i}}
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
				e := j.pending[order[end].order]
				declare_action(w, e.action)
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
			game.journal_write_record(&j.out, game.Journal_Changes{chunk, changes[:]})
			start = end
		}
		run_start = run_end
	}
	clear(&j.pending)
}

// declare_action writes the action and its actor into the segment if it has
// not been (so every segment reads alone).
@(private = "file")
declare_action :: proc(w: ^World, id: u32) {
	j := &w.journal
	if u64(id) in j.declared {return}
	a := action_live(j, Action_Id(id))
	if a == nil {return}
	if declare_key_actor(a.actor) not_in j.declared {
		j.declared[declare_key_actor(a.actor)] = {}
		who := j.actors[a.actor]
		game.journal_write_record(&j.out, game.Journal_Actor{a.actor, who.kind, who.name})
	}
	j.declared[u64(id)] = {}
	game.journal_write_record(&j.out, a.rec)
}

// journal_append writes one record on its own (Save, Params).
journal_note :: proc(w: ^World, rec: game.Journal_Record) {
	if w.dir == "" {return}
	journal_encode(w)
	j := &w.journal
	if len(j.out.buf) == 0 {j.out_age = age_of(w.server)}
	game.journal_write_record(&j.out, rec)
}

// journal_flush writes the encoded records to the open segment (begun if
// need be).
journal_flush :: proc(w: ^World) {
	s := w.server
	if w.dir == "" {return}
	from := timed(s)
	defer spent(w, from)
	journal_encode(w)
	journal_write_out(w)
}

// journal_write_out appends the encoded records to the open segment.
@(private = "file")
journal_write_out :: proc(w: ^World) {
	s := w.server
	j := &w.journal
	j.last_flush = s.tick
	if len(j.out.buf) == 0 {return}
	if j.file == nil {
		j.seq += 1 // (the last one used, so far)
		path := segment_path(w, j.seq)
		f, err := os.open(path, {.Write, .Create, .Trunc})
		if err != nil {
			log.errorf("server cannot open a journal segment path=%s error=%v", path, err)
			clear(&j.out.buf)
			return
		}
		j.file = f
		hw := game.Writer{}
		game.writer_init(&hw, context.temp_allocator, 64)
		game.journal_write_header(&hw, {seq = j.seq, first_age = j.out_age})
		os.write(f, hw.buf[:])
		j.file_bytes = u64(len(hw.buf))
	}
	if _, err := os.write(j.file, j.out.buf[:]); err != nil {
		log.errorf("server cannot write the journal seq=%d error=%v", j.seq, err)
	}
	j.file_bytes += u64(len(j.out.buf))
	clear(&j.out.buf)
}

// journal_save_point: at a save, everything is on disk and a Save record
// ends it; the world.cfg written after names this end.
journal_save_point :: proc(w: ^World) {
	if w.dir == "" {return}
	journal_note(w, game.Journal_Save{age_of(w.server)})
	journal_flush(w)
}

// Loaded_Segment: a segment read whole, entries in the order written, each
// with the age of the Tick before it.
Loaded_Segment :: struct {
	header:  game.Journal_Header,
	status:  game.Segment_Status,
	valid:   int,
	entries: [dynamic]game.Journal_Entry,
	actions: map[u32]Action_Info,
	params:  [dynamic]u64, // the ages generator parameters changed in it
}

// Action_Info: what an entry's action says, from a segment or the ring.
Action_Info :: struct {
	kind:    game.Actor_Kind,
	actor:   string,
	system:  game.Edit_System,
	command: string,
}

@(private = "file")
Loading :: struct {
	seg:    ^Loaded_Segment,
	age:    u64,
	actors: map[u32]Actor_Entry,
}

// segment_load reads segment seq of w (temp allocator).
segment_load :: proc(w: ^World, seq: u32) -> (seg: Loaded_Segment, ok: bool) {
	data, err := os.read_entire_file_from_path(segment_path(w, seq), context.temp_allocator)
	if err != nil {return}
	return segment_decode(data)
}

// segment_decode decodes a segment's bytes (temp allocator).
segment_decode :: proc(data: []u8) -> (seg: Loaded_Segment, ok: bool) {
	seg.entries = make([dynamic]game.Journal_Entry, context.temp_allocator)
	seg.actions = make(map[u32]Action_Info, 16, context.temp_allocator)
	seg.params = make([dynamic]u64, context.temp_allocator)
	l := Loading {
		seg    = &seg,
		actors = make(map[u32]Actor_Entry, 16, context.temp_allocator),
	}
	r := game.journal_read_segment(data, proc(user: rawptr, rec: game.Journal_Record) {
			l := cast(^Loading)user
			switch v in rec {
			case game.Journal_Tick:
				l.age = v.age
			case game.Journal_Actor:
				l.actors[v.index] = {v.kind, strings.clone(v.name, context.temp_allocator)}
			case game.Journal_Action:
				who := l.actors[v.actor]
				l.seg.actions[v.id] = {
					who.kind,
					who.name,
					v.system,
					strings.clone(v.command, context.temp_allocator),
				}
			case game.Journal_Changes:
				origin := game.chunk_origin(v.chunk)
				for c in v.changes {
					append(
						&l.seg.entries,
						game.Journal_Entry {
							pos = origin + game.local_from_index(int(c.index)),
							old = c.old,
							new = c.new,
							action = c.action,
							how = c.how,
							age = l.age,
						},
					)
				}
			case game.Journal_Save:
			case game.Journal_Params:
				append(&l.seg.params, v.age)
			}
		}, &l)
	seg.header, seg.status, seg.valid = r.header, r.status, r.valid_bytes
	return seg, r.status != .Bad_Header
}

// action_info: the actor and system of an action in the ring's memory.
action_info :: proc(j: ^Journal, id: u32) -> (info: Action_Info, ok: bool) {
	a := action_live(j, Action_Id(id))
	if a == nil {return}
	who := j.actors[a.actor]
	return {who.kind, who.name, a.system, a.command}, true
}

journal_hash :: proc(w: ^World) -> u64 {
	j := &w.journal
	h := j.tick_hash
	j.tick_hash = game.hasher_make()
	return game.hasher_finish(h)
}

// age_text: how long ago an age was ("3m ago").
age_text :: proc(s: ^Server, age: u64) -> string {
	now := age_of(s)
	secs := (now - min(age, now)) / game.TICK_RATE
	switch {
	case secs < 90:
		return fmt.tprintf("%ds ago", secs)
	case secs < 90 * 60:
		return fmt.tprintf("%dm ago", secs / 60)
	case secs < 48 * 3600:
		return fmt.tprintf("%dh ago", secs / 3600)
	}
	return fmt.tprintf("%dd ago", secs / 86400)
}
