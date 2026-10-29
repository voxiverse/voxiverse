package server

import "base:intrinsics"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import "../base"
import "../common/game"

// M45: the edit journal. test_grief_rolled_back is the exit check: a player
// builds a house, a pool, a chest and a field; a grief of every kind of change
// follows; one /rollback puts the world back, hash for hash.

// test_act: a cause for a test that changes blocks directly.
test_act :: proc(w: ^World) -> Act {
	return world_act(w, .Command)
}

GRIEF_SEED :: 45

Grief :: struct {
	sess:   ^Session,
	dir:    string,
	f:      game.Block_Pos, // the player's feet
	edit:   u32,
	chunks: [dynamic]game.Chunk_Pos, // the 5 x 3 x 5 around the player
	h0:     u64,
	t:      ^testing.T,
	at:     u64, // the age the grief began at
}

rules_still :: proc() -> game.Rules {
	r := game.RULES_DEFAULTS
	r.random_tick_speed = 0 // (nothing grows or spreads behind a test's back)
	return r
}

grief_config :: proc(dir: string, memory := 0, segment := 0) -> Config {
	return {
		seed = GRIEF_SEED,
		generator = .Earth,
		view_radius = 4,
		view_height = 2,
		allow_cheats = true,
		max_players = 1,
		rules = rules_still(),
		no_sheep = true,
		save_dir = dir,
		journal_memory = memory,
		journal_segment_bytes = segment,
	}
}

// grief_open starts the session and stands the player on the ground.
grief_open :: proc(
	t: ^testing.T,
	dir: string,
	config: Maybe(Config) = nil,
) -> (
	g: ^Grief,
	ok: bool,
) {
	g = new(Grief)
	g.t = t
	g.dir = dir
	g.sess = new(Session)
	cfg := config.? or_else grief_config(dir)
	if !testing.expect(t, session_start(g.sess, {}, false, with = cfg)) {return g, false}
	if !session_land(t, g.sess) {return g, false}
	grief_locate(g)
	return g, true
}

grief_locate :: proc(g: ^Grief) {
	c := &g.sess.h.srv.clients[0]
	p := c.player.position
	g.f = {i32(math.floor(p.x)), i32(math.floor(p.y)), i32(math.floor(p.z))}
	clear(&g.chunks)
	cp := game.chunk_of(g.f)
	for y in cp.y - 1 ..= cp.y + 1 {
		for z in cp.z - 2 ..= cp.z + 2 {
			for x in cp.x - 2 ..= cp.x + 2 {append(&g.chunks, game.Chunk_Pos{x, y, z})}
		}
	}
}

grief_close :: proc(g: ^Grief) {
	if g.sess != nil && g.sess.h.started {
		clear(&g.sess.failures) // (the mirror does not know every State record a chest sends)
		session_stop(g.sess)
	}
	free(g.sess)
	delete(g.chunks)
	free(g)
}

grief_srv :: proc(g: ^Grief) -> ^Server {return &g.sess.h.srv}
grief_client :: proc(g: ^Grief) -> ^Client {return &g.sess.h.srv.clients[0]}
grief_world :: proc(g: ^Grief) -> ^World {return grief_client(g).world}

run :: proc(g: ^Grief, ticks: int) {
	for _ in 0 ..< ticks {session_step(g.sess, false)}
}

cmd :: proc(g: ^Grief, format: string, args: ..any) {
	admin(grief_srv(g), grief_client(g), fmt.tprintf(format, ..args))
	run(g, 2)
}

// at: the block at an offset from the player's feet.
at :: proc(g: ^Grief, x, y, z: i32) -> game.Block_Pos {return g.f + {x, y, z}}

// box: "x1 y1 z1 x2 y2 z2" of offsets from the player's feet.
box :: proc(g: ^Grief, a, b: [3]i32) -> string {
	p, q := g.f + a, g.f + b
	return fmt.tprintf("%d %d %d %d %d %d", p.x, p.y, p.z, q.x, q.y, q.z)
}

// hand: an edit the way a client makes it (reach and place rules checked).
hand :: proc(g: ^Grief, pos: game.Block_Pos, b: game.Block) -> bool {
	g.edit += 1
	r := apply_edit(grief_srv(g), grief_client(g), game.edit_plain(g.edit, 0, pos, b))
	run(g, 1)
	return r.accepted
}

block_at_pos :: proc(w: ^World, p: game.Block_Pos) -> game.Block {
	b, _ := chunks_block(&w.chunks, p)
	return b
}

world_hash_here :: proc(g: ^Grief) -> u64 {
	return hash_chunks(grief_world(g), g.chunks[:])
}

// slot_of: the first slot of the player's inventory that holds item.
slot_of :: proc(g: ^Grief, item: game.Item) -> int {
	for st, i in grief_client(g).inventory.slots {if st.item == item && st.count > 0 {return i}}
	return 0
}

// grief_build: the house, the pool, the chest, the field.
grief_build :: proc(g: ^Grief) {
	cmd(g, "give @s hoe")
	cmd(g, "give @s planks 10")
	cmd(g, "fill %s planks", box(g, {3, -1, -2}, {7, 3, 2}))
	cmd(g, "fill %s air", box(g, {4, 0, -1}, {6, 2, 1}))
	cmd(g, "fill %s air", box(g, {3, 0, 0}, {3, 1, 0}))
	cmd(g, "fill %s stone", box(g, {-12, -1, -3}, {-6, 0, 3}))
	cmd(g, "fill %s water", box(g, {-11, 0, -2}, {-7, 0, 2}))
	chest := at(g, -3, 0, 2)
	cmd(g, "setblock %d %d %d chest", chest.x, chest.y, chest.z)
	cmd(g, "fill %s farmland", box(g, {-3, -1, -4}, {-2, -1, -4}))
	cmd(g, "fill %s wheat_0", box(g, {-3, 0, -4}, {-2, 0, -4}))
	cmd(g, "fill %s grass", box(g, {-1, -1, -2}, {-1, -1, -2}))
	cmd(g, "fill %s air", box(g, {-1, 0, -2}, {-1, 0, -2}))
	// Planks into the chest, the way a player does it.
	m := &g.sess.mirror
	sequence := m.prediction.next_sequence - 1
	mirror_send(m, game.Use_Block{chest, sequence})
	run(g, 3)
	inventory(m, .Click, slot_of(g, game.item_of_block(test_reg(), .Planks)))
	inventory(m, .Click, game.CHEST_BASE)
	run(g, 3)
	run(g, 300) // (the water settles)
}

// grief_do: every kind of change a griefer can make.
grief_do :: proc(g: ^Grief, bob: Action_Id = 0) {
	t := g.t
	g.at = age_of(grief_srv(g))
	for dz in ([]i32{-1, 1}) {
		for dy in i32(0) ..= 2 {testing.expect(t, hand(g, at(g, 3, dy, dz), .Air), "a house block could not be broken")}
	}
	for dy in i32(0) ..= 2 {testing.expect(t, hand(g, at(g, 3, dy, -1), .Stone), "stone could not be placed")}
	if bob != 0 { 	// bob builds a tower elsewhere
		for y in i32(0) ..< 5 {set_block(grief_world(g), at(g, 9, y, 6), .Cobblestone, {bob, .Command})}
	}
	cmd(g, "fill %s air", box(g, {3, 0, -2}, {7, 1, 2}))
	testing.expect(t, hand(g, at(g, -6, 0, 0), .Air), "the pool wall could not be broken")
	run(g, 60)
	roof := at(g, 5, 4, 0)
	cmd(g, "setblock %d %d %d water", roof.x, roof.y, roof.z)
	run(g, 30)
	inv := &grief_client(g).inventory // (the hoe into the hand: a swap, no item is made)
	hoe := slot_of(g, game.item_of_tool(.Hoe))
	inv.slots[0], inv.slots[hoe] = inv.slots[hoe], inv.slots[0]
	inv.selected = 0
	testing.expect(t, hand(g, at(g, -1, -1, -2), .Farmland), "the grass could not be tilled")
	testing.expect(
		t,
		hand(g, at(g, -3, -1, -4), .Air),
		"the soil under the wheat could not be broken",
	)
	m := &g.sess.mirror
	for _ in 0 ..< 3 {
		mirror_send(m, game.Fire{m.prediction.next_sequence - 1, -math.PI / 2, 0})
		run(g, 40)
	}
	testing.expect(t, hand(g, at(g, -3, 0, 2), .Air), "the chest could not be broken")
	if bob != 0 { 	// and puts stone where mallory broke a house block, last
		set_block(grief_world(g), at(g, 3, 2, 1), .Stone, {bob, .Command})
	}
	run(g, 100)
}

grief_wait_rollback :: proc(g: ^Grief) -> Rollback_Report {
	w := grief_world(g)
	for _ in 0 ..< 900 {
		if w.rollback == nil {break}
		run(g, 1)
	}
	return w.journal.report
}

// grief_rollback runs "/rollback <what>" covering the grief (and no more).
grief_rollback :: proc(g: ^Grief, what: string, area := "") -> Rollback_Report {
	seconds := (age_of(grief_srv(g)) - g.at) / game.TICK_RATE + 1
	cmd(g, "rollback %s %ds %s", what, seconds, area)
	return grief_wait_rollback(g)
}

grief_player :: proc(g: ^Grief) -> string {return fmt.tprintf(
		"player %s",
		client_name(grief_client(g)),
	)}

journal_hows :: proc(w: ^World) -> (seen: [game.Edit_System]bool) {
	j := &w.journal
	for i := ring_oldest(j); i < j.head; i += 1 {seen[ring_at(j, i).how] = true}
	return
}

scratch_dir :: proc(name: string) -> string {
	dir := fmt.aprintf("build/test_%s", name)
	os.remove_all(dir)
	return dir
}

@(test)
test_grief_rolled_back :: proc(t: ^testing.T) {
	dir := scratch_dir("grief")
	defer delete(dir)
	defer os.remove_all(dir)
	g, ok := grief_open(t, dir)
	defer grief_close(g)
	if !ok {return}
	grief_build(g)
	w := grief_world(g)
	g.h0 = world_hash_here(g)
	filled: [game.CHEST_SLOTS]game.Stack
	if e := block_entity_at(w, at(g, -3, 0, 2)); e != nil {filled = e.slots}
	testing.expect(t, !game.stack_empty(filled[0]), "the chest was not filled")
	grief_do(g)
	testing.expect(t, world_hash_here(g) != g.h0, "the grief changed nothing")
	hows := journal_hows(w)
	for how in ([]game.Edit_System{.Hand, .Till, .Command, .Explosion, .Liquid, .Support}) {
		testing.expectf(t, hows[how], "the journal has no entry made by %v", how)
	}
	r := grief_rollback(g, grief_player(g))
	run(g, 300)
	testing.expect(t, r.done, "the rollback did not finish")
	testing.expect_value(t, r.kept, 0)
	testing.expect_value(t, r.missing, 0)
	testing.expect_value(t, world_hash_here(g), g.h0)
	chest := at(g, -3, 0, 2)
	e := block_entity_at(w, chest)
	if testing.expect(t, e != nil, "the restored chest has no entity") {
		testing.expect(t, e.slots == filled, "the restored chest lacks its contents")
	}
	testing.expect_value(t, len(audit(grief_srv(g))), 0)
}

// The same grief, with bob making his own changes meanwhile.
@(test)
test_rollback_keeps_others :: proc(t: ^testing.T) {
	dir := scratch_dir("keeps")
	defer delete(dir)
	defer os.remove_all(dir)
	g, ok := grief_open(t, dir)
	defer grief_close(g)
	if !ok {return}
	grief_build(g)
	w := grief_world(g)
	g.h0 = world_hash_here(g)
	bob := action_begin(w, {.Character, "bob", false}, .Command)
	grief_do(g, bob)
	r := grief_rollback(g, grief_player(g))
	run(g, 300)
	testing.expect(t, r.done, "the rollback did not finish")
	// (the stone, and the water around it that it woke: its consequences are bob's)
	testing.expect(t, r.kept >= 1, "bob's stone should have been kept")
	testing.expect_value(t, r.missing, 0)
	for y in i32(0) ..< 5 {
		testing.expect_value(t, block_at_pos(w, at(g, 9, y, 6)), game.Block.Cobblestone)
	}
	testing.expect_value(t, block_at_pos(w, at(g, 3, 2, 1)), game.Block.Stone)
	testing.expect(t, world_hash_here(g) != g.h0, "bob's changes must stay")
}

// /rollback system touches only what that system changed; /rollback area only
// the selection.
@(test)
test_rollback_by_system_and_area :: proc(t: ^testing.T) {
	dir := scratch_dir("system")
	defer delete(dir)
	defer os.remove_all(dir)
	g, ok := grief_open(t, dir)
	defer grief_close(g)
	if !ok {return}
	grief_build(g)
	w := grief_world(g)
	j := &w.journal
	grief_do(g)
	before := j.head
	r := grief_rollback(g, "system liquid")
	testing.expect(t, r.done && r.restored > 0, "no water was rolled back")
	for i := before; i < j.head; i += 1 {
		e := ring_at(j, i)
		if e.action != u32(r.action) {continue}
		_, from_water := game.water_level(e.old)
		_, to_water := game.water_level(e.new)
		testing.expectf(
			t,
			from_water || to_water,
			"a liquid rollback changed %v to %v",
			e.old,
			e.new,
		)
	}
	// The selection: a few blocks of the house.
	a, b := at(g, 3, 0, -2), at(g, 5, 2, 0)
	cmd(g, "pos1 %d %d %d", a.x, a.y, a.z)
	cmd(g, "pos2 %d %d %d", b.x, b.y, b.z)
	before = j.head
	r = grief_rollback(g, "area", "sel")
	testing.expect(t, r.done && r.restored > 0, "the area rollback changed nothing")
	for i := before; i < j.head; i += 1 {
		e := ring_at(j, i)
		if e.action != u32(r.action) {continue}
		inside :=
			e.pos.x >= a.x &&
			e.pos.x <= b.x &&
			e.pos.y >= a.y &&
			e.pos.y <= b.y &&
			e.pos.z >= a.z &&
			e.pos.z <= b.z
		testing.expectf(
			t,
			inside || e.how == .Liquid || e.how == .Support,
			"an area rollback changed %v outside the selection",
			e.pos,
		)
	}
}

// After a restart the ring is empty: the rollback reads the segments.
@(test)
test_rollback_reads_disk :: proc(t: ^testing.T) {
	dir := scratch_dir("disk")
	defer delete(dir)
	defer os.remove_all(dir)
	g, ok := grief_open(t, dir)
	if !ok {grief_close(g); return}
	grief_build(g)
	g.h0 = world_hash_here(g)
	grief_do(g)
	chunks := make([dynamic]game.Chunk_Pos)
	defer delete(chunks)
	append(&chunks, ..g.chunks[:])
	h0, at_age, f := g.h0, g.at, g.f
	grief_close(g)
	g2, ok2 := grief_open(t, dir)
	defer grief_close(g2)
	if !ok2 {return}
	testing.expect_value(t, g2.f, f)
	g2.at = at_age
	clear(&g2.chunks)
	append(&g2.chunks, ..chunks[:])
	testing.expect_value(t, grief_world(g2).journal.head, 0)
	testing.expect(t, world_hash_here(g2) != h0, "the grief should have been saved")
	r := grief_rollback(g2, grief_player(g2))
	run(g2, 300)
	testing.expect(t, r.done, "the rollback did not finish")
	testing.expect_value(t, r.missing, 0)
	testing.expect_value(t, world_hash_here(g2), h0)
}

@(test)
test_undo_redo :: proc(t: ^testing.T) {
	g, ok := grief_open(t, "", grief_config("", memory = 1024))
	defer grief_close(g)
	if !ok {return}
	w := grief_world(g)
	h0 := world_hash_here(g)
	cmd(g, "fill %s stone", box(g, {3, 0, -4}, {6, 3, -1}))
	h1 := world_hash_here(g)
	testing.expect(t, h1 != h0)
	cmd(g, "undo")
	testing.expect_value(t, world_hash_here(g), h0)
	cmd(g, "redo")
	testing.expect_value(t, world_hash_here(g), h1)
	cmd(g, "undo")
	testing.expect_value(t, world_hash_here(g), h0)
	// A new edit clears what could be redone.
	testing.expect(t, hand(g, at(g, 2, 0, -3), .Stone))
	h2 := world_hash_here(g)
	cmd(g, "redo")
	testing.expect_value(t, world_hash_here(g), h2)
	// An action pushed out of the ring is too old.
	cmd(g, "fill %s stone", box(g, {3, 0, 3}, {4, 1, 4}))
	h3 := world_hash_here(g)
	for _ in 0 ..< 3 {
		cmd(g, "fill %s planks", box(g, {-9, -1, -9}, {-1, 3, -3}))
		cmd(g, "fill %s glass", box(g, {-9, -1, -9}, {-1, 3, -3}))
	}
	h4 := world_hash_here(g)
	cmd(g, "undo 32")
	testing.expect(t, world_hash_here(g) != h4, "the newest actions should be undone")
	testing.expect(t, w.journal.head > 1024)
	// ... down to the first that has left the ring: the stone at (3, 0, 3) stays.
	testing.expect_value(t, block_at_pos(w, at(g, 3, 0, 3)), game.Block.Stone)
	_ = h3
}

// copy_regions copies the region files of dir's home world into snapshot (a
// saved world's directory, as a snapshot is: its worlds/<address>/regions).
copy_regions :: proc(s: ^Server, w: ^World, snapshot: string) {
	from := fmt.tprintf("%s/regions", w.dir)
	to := fmt.tprintf("%s/%s/%s/regions", snapshot, WORLDS_DIR, game.address_dir(w.address))
	os.make_directory_all(to)
	entries, err := os.read_all_directory_by_path(from, context.temp_allocator)
	if err != nil {return}
	for e in entries {
		data, read_err := os.read_entire_file_from_path(
			fmt.tprintf("%s/%s", from, e.name),
			context.temp_allocator,
		)
		if read_err == nil {_ = os.write_entire_file(fmt.tprintf("%s/%s", to, e.name), data)}
	}
}

// M38's scripted session, with a save directory: its journal replayed onto
// the generator, and onto a snapshot saved in the middle, gives the world it
// ended with; a write that bypassed the pipeline is found.
@(test)
test_journal_replays :: proc(t: ^testing.T) {
	dir := scratch_dir("replay")
	snapshot := scratch_dir("replay_snapshot")
	defer delete(dir)
	defer delete(snapshot)
	defer os.remove_all(dir)
	defer os.remove_all(snapshot)
	sess := new(Session)
	defer free(sess)
	config := Config {
		seed         = DETERMINISM_SEED,
		generator    = .Earth,
		view_radius  = 4,
		view_height  = 2,
		allow_cheats = true,
		max_players  = 1,
		save_dir     = dir,
	}
	if !testing.expect(t, session_start(sess, {}, false, with = config)) {return}
	defer session_stop(sess)
	if !session_land(t, sess) {return}
	sess.script_at = sess.h.srv.tick
	s := &sess.h.srv
	w := s.home
	snapshot_age: u64
	bypass: game.Block_Pos
	for _ in 0 ..< 3600 {
		session_step(sess, true)
		switch ticks_of(sess) {
		case 1000:
			save(s)
			snapshot_age = age_of(s)
			copy_regions(s, w, snapshot)
		case 3500:
			c := &s.clients[0]
			p := c.player.position
			bypass = {i32(math.floor(p.x)), i32(math.floor(p.y)) + 6, i32(math.floor(p.z))}
		}
	}
	testing.expect(t, w.journal.head > 100, "the script should have changed many blocks")
	r := journal_replay(w, "", 0)
	testing.expectf(t, r.problem == "", "replay from the generator: %s", r.problem)
	testing.expect_value(t, r.live, r.replayed)
	testing.expect(t, r.entries > 100 && r.chunks > 0)
	r = journal_replay(w, snapshot, snapshot_age)
	testing.expectf(t, r.problem == "", "replay from the snapshot: %s", r.problem)
	testing.expect_value(t, r.live, r.replayed)
	testing.expect(t, r.entries > 0 && u64(r.entries) < w.journal.head)
	// A block written around the pipeline is named.
	testing.expect(t, chunks_set_block(&w.chunks, bypass, .Gravel))
	r = journal_replay(w, "", 0)
	text := fmt.tprintf("(%d, %d, %d)", bypass.x, bypass.y, bypass.z)
	testing.expectf(
		t,
		r.problem != "" && contains(r.problem, text),
		"the bypass at %s went unnoticed: %q",
		text,
		r.problem,
	)
}

@(private = "file")
contains :: proc(s, sub: string) -> bool {
	for i in 0 ..= len(s) - len(sub) {if s[i:][:len(sub)] == sub {return true}}
	return false
}

@(private = "file")
Declared :: struct {
	actors:  map[u32]struct{},
	actions: map[u32]struct{},
	bad:     int,
	first:   string,
}

@(private = "file")
entry_less :: proc(a, b: game.Journal_Entry) -> bool {
	if a.age != b.age {return a.age < b.age}
	if a.pos != b.pos {return game.block_pos_less(a.pos, b.pos)}
	if a.action != b.action {return a.action < b.action}
	return u32(a.new) < u32(b.new)
}

// What is on disk is what is in the ring, and every segment reads alone.
@(test)
test_journal_matches_disk :: proc(t: ^testing.T) {
	dir := scratch_dir("matches")
	defer delete(dir)
	defer os.remove_all(dir)
	g, ok := grief_open(t, dir, grief_config(dir, segment = 4096))
	if !ok {grief_close(g); return}
	grief_build(g)
	grief_do(g)
	w := grief_world(g)
	j := &w.journal
	journal_flush(w)
	ring := make([dynamic]game.Journal_Entry, context.temp_allocator)
	for i := ring_oldest(j); i < j.head; i += 1 {append(&ring, ring_at(j, i)^)}
	disk := make([dynamic]game.Journal_Entry, context.temp_allocator)
	segments := journal_segments(w)
	testing.expect(t, len(segments) >= 3, "small segments should have rolled over")
	for seq in segments {
		path := segment_path(w, seq)
		data, err := os.read_entire_file_from_path(path, context.temp_allocator)
		testing.expect(t, err == nil)
		d := Declared {
			actors  = make(map[u32]struct{}, 8, context.temp_allocator),
			actions = make(map[u32]struct{}, 8, context.temp_allocator),
		}
		res := game.journal_read_segment(
			test_reg(),
			data,
			proc(user: rawptr, rec: game.Journal_Record) {
				d := cast(^Declared)user
				#partial switch v in rec {
				case game.Journal_Actor:
					d.actors[v.index] = {}
				case game.Journal_Action:
					if v.actor not_in d.actors {d.bad += 1}
					d.actions[v.id] = {}
				case game.Journal_Changes:
					for c in v.changes {if c.action not_in d.actions {d.bad += 1}}
				}
			},
			&d,
		)
		testing.expect_value(t, res.status, game.Segment_Status.Whole)
		testing.expect_value(t, d.bad, 0) // (declared before first use, in this segment)
		testing.expect_value(t, int(res.header.seq), int(seq))
		seg, _ := segment_decode(test_reg(), data)
		append(&disk, ..seg.entries[:])
	}
	testing.expect_value(t, len(disk), len(ring))
	slice_sort(ring[:])
	slice_sort(disk[:])
	for i in 0 ..< min(len(ring), len(disk)) {
		if ring[i] != disk[i] {
			testing.expectf(t, false, "entry %d differs: ring %v, disk %v", i, ring[i], disk[i])
			break
		}
	}
	last := segments[len(segments) - 1]
	address := strings.clone(game.address_dir(w.address))
	defer delete(address)
	grief_close(g)
	// A segment written after the last save is not described by the save:
	// when the world starts again it is dropped, and what the saved one has
	// after the save's end is cut.
	journal_path :: proc(dir: string, address: string, seq: u32) -> string {
		return fmt.tprintf("%s/%s/%s/%s/%08d.vxj", dir, WORLDS_DIR, address, JOURNAL_DIR, seq)
	}
	saved := strings.clone(journal_path(dir, address, last))
	defer delete(saved)
	size_before := file_size_of(saved)
	stray := strings.clone(journal_path(dir, address, last + 7))
	defer delete(stray)
	testing.expect(t, os.write_entire_file(stray, []u8{1, 2, 3}) == nil)
	f, open_err := os.open(saved, {.Write, .Append})
	testing.expect(t, open_err == nil)
	if open_err == nil {
		_, _ = os.write(f, []u8{9, 9, 9, 9, 9, 9, 9})
		os.close(f)
	}
	testing.expect_value(t, file_size_of(saved), size_before + 7)
	g2, ok2 := grief_open(t, dir)
	defer grief_close(g2)
	if !ok2 {return}
	testing.expect(t, !os.exists(stray), "a segment after the saved one must be deleted at start")
	testing.expect_value(t, file_size_of(saved), size_before)
}

@(private = "file")
file_size_of :: proc(path: string) -> int {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	return len(data) if err == nil else -1
}

@(private = "file")
slice_sort :: proc(s: []game.Journal_Entry) {
	slice.sort_by(s, entry_less)
}

grief_close_keep :: proc(g: ^Grief) {
	if g.sess != nil && g.sess.h.started {
		clear(&g.sess.failures)
		session_stop(g.sess)
		g.sess.h.started = false
	}
}

// The journal's cost: M11's flood (10 000 flowing blocks), 20 blasts of radius
// 6 and ten 32 x 32 x 32 fills over 600 ticks. Its time is a small share of
// the ticks', and a small mean per tick (optimized in CI; four times the
// allowance in a debug run).
@(test)
test_journal_cost :: proc(t: ^testing.T) {
	config := grief_config("")
	config.view_radius = 7 // (the flood's square, corners too)
	config.journal_timed = true
	g, ok := grief_open(t, "", config)
	defer grief_close(g)
	if !ok {return}
	s := grief_srv(g)
	w := grief_world(g)
	started := s.tick
	measure :: proc(g: ^Grief, total, wall_ns: ^i64, body: proc(g: ^Grief, n: int), n: int) {
		from := u64(intrinsics.read_cycle_counter())
		cpu := base.thread_cpu_us() // (this thread's CPU time: other tests run on other threads)
		body(g, n)
		total^ += i64(u64(intrinsics.read_cycle_counter()) - from)
		wall_ns^ += 1000 * (base.thread_cpu_us() - cpu)
	}
	total, wall_ns: i64
	// The platform and the layer of sources over it.
	measure(g, &total, &wall_ns, proc(g: ^Grief, _: int) {
			p := g.f
			x0, z0, y := p.x - 50, p.z - 50, p.y + 12
			cmd(g, "fill %d %d %d %d %d %d stone", x0 - 1, y, z0 - 1, x0 + 100, y + 1, z0 + 100)
			cmd(g, "fill %d %d %d %d %d %d air", x0, y + 1, z0, x0 + 99, y + 1, z0 + 99)
			cmd(g, "fill %d %d %d %d %d %d water", x0, y + 8, z0, x0 + 99, y + 8, z0 + 99)
		}, 0)
	for tick in 0 ..< 600 {
		measure(g, &total, &wall_ns, proc(g: ^Grief, tick: int) {
				w := grief_world(g)
				p := g.f
				switch {
				case tick % 30 == 10 && tick < 600:
					n := i32(tick / 30)
					if n < 20 {
						at := [3]f64 {
							f64(p.x - 40 + (n % 5) * 20),
							f64(p.y - 6),
							f64(p.z - 40 + (n / 5) * 20),
						}
						explode(w, at, 6, action_begin(w, {.World, "", false}, .Explosion))
					}
				case tick % 60 == 20 && tick < 600:
					n := i32(tick / 60)
					cmd(
						g,
						"fill %d %d %d %d %d %d %s",
						p.x + n * 3 - 20,
						p.y - 40,
						p.z - 20,
						p.x + n * 3 + 11,
						p.y - 9,
						p.z + 11,
						"stone" if n % 2 == 0 else "dirt",
					)
				}
				session_step(g.sess, false)
			}, tick)
	}
	cost := w.journal.cost_cycles
	share := f64(cost) / f64(total)
	per_tick_ms := share * f64(wall_ns) / f64(s.tick - started) / 1e6
	log_line := fmt.tprintf(
		"journal cost: %.2f%% of the ticks' time, %.3f ms per tick (%d entries)",
		share * 100,
		per_tick_ms,
		w.journal.head,
	)
	fmt.println(log_line)
	testing.expectf(
		t,
		w.journal.head > 20000,
		"the scenario changed only %d blocks",
		w.journal.head,
	)
	if base.budget_applies() {
		testing.expectf(
			t,
			share <= 0.05,
			"the journal's share of tick time is too high: %s",
			log_line,
		)
		testing.expectf(
			t,
			per_tick_ms <= 0.5,
			"the journal's mean per tick is too high: %s",
			log_line,
		)
	}
}

// M48c: a filled chest broken, the server restarted: the rollback finds the
// chest's value in the segment files (the ring and the memory are empty); a
// compacted journal still holds it.
chest_after_restart :: proc(t: ^testing.T, name: string, compact: bool) {
	dir := scratch_dir(name)
	defer delete(dir)
	defer os.remove_all(dir)
	cfg := compact_config(dir, 60 if compact else 1 << 40, 0, 0)
	g, ok := grief_open(t, dir, cfg)
	if !ok {grief_close(g); return}
	grief_build(g)
	chest := at(g, -3, 0, 2)
	filled: [game.CHEST_SLOTS]game.Stack
	if e := block_entity_at(grief_world(g), chest); e != nil {filled = e.slots}
	testing.expect(t, !game.stack_empty(filled[0]), "the chest was not filled")
	g.at = age_of(grief_srv(g))
	testing.expect(t, hand(g, chest, .Air), "the chest could not be broken")
	run(g, 60)
	testing.expect(t, block_entity_at(grief_world(g), chest) == nil, "the chest entity stayed")
	if compact { 	// later history, so that the segment holding the break is compacted
		compact_history(g)
		run(g, 100)
		for _ in 0 ..< 8 {
			testing.expect(t, world_save(grief_world(g)))
			run(g, 2)
		}
		_, compacted, _ := segments_size(grief_world(g))
		testing.expect(t, compacted >= 1, "segments should have been compacted")
	}
	at_age, f := g.at, g.f
	chunks := make([dynamic]game.Chunk_Pos)
	defer delete(chunks)
	append(&chunks, ..g.chunks[:])
	grief_close(g)
	g2, ok2 := grief_open(t, dir, cfg)
	defer grief_close(g2)
	if !ok2 {return}
	testing.expect_value(t, g2.f, f)
	g2.at = at_age
	testing.expect_value(t, grief_world(g2).journal.head, 0)
	testing.expect_value(t, len(grief_world(g2).journal.entities), 0)
	r := grief_rollback(g2, grief_player(g2))
	run(g2, 300)
	testing.expect(t, r.done, "the rollback did not finish")
	e := block_entity_at(grief_world(g2), chest)
	if testing.expect(t, e != nil, "the restored chest has no entity") {
		testing.expect(t, e.slots == filled, "the restored chest lacks its contents")
	}
	testing.expect_value(t, len(audit(grief_srv(g2))), 0)
}

@(test)
test_chest_restored_after_restart :: proc(t: ^testing.T) {
	chest_after_restart(t, "chest_restart", false)
}

@(test)
test_chest_restored_from_compacted :: proc(t: ^testing.T) {
	chest_after_restart(t, "chest_compacted", true)
}
