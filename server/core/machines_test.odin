package core

import "core:testing"

import "common:game"

// Machines (machines.odin): a game's blocks with a record, slots and a schedule: built and
// broken as blocks are, thinking only when woken, in batches by kind, showing players
// what the game says.

@(private = "file")
WORKS_PACK :: `{"format": 1, "namespace": "works", "version": "1.0.0", "title": "Works", "requires": ["voxiverse"]}`
@(private = "file")
WORKS_BLOCKS :: `{
	"oven": {"textures": {"all": "voxiverse:stone"}, "entity": {"kind": "machine", "slots": 2}},
	"mill": {"textures": {"all": "voxiverse:planks"}, "entity": {"kind": "machine", "slots": 0}}
}`

@(private = "file")
Oven :: struct {
	thought: u32,
	heat:    f32,
}

@(private = "file")
Oven_Shown :: struct {
	heat: u8,
}

// Works_Log: what the test game's hooks saw.
@(private = "file")
Works_Log :: struct {
	batches: [16]Works_Batch,
	count:   int,
	used:    game.Block_Pos,
	uses:    int,
}

@(private = "file")
Works_Batch :: struct {
	kind: game.Block_Type,
	n:    int,
	tick: u64,
}

@(private = "file")
Works_Rig :: struct {
	sess:  Session,
	files: [2]game.Pack_File,
}

@(private = "file")
works_think :: proc(s: ^Server, w: ^World, kind: game.Block_Type, at: []game.Block_Pos) {
	l := game_state(s, Works_Log)
	l.batches[l.count] = Works_Batch{kind, len(at), s.tick}
	l.count += 1
	for p in at {
		if o := machine_data(w, p, Oven); o != nil {o.thought += 1}
	}
}

@(private = "file")
works_use :: proc(s: ^Server, c: ^Client, at: game.Block_Pos) -> string {
	l := game_state(s, Works_Log)
	l.used, l.uses = at, l.uses + 1
	return ""
}

@(private = "file")
works_start :: proc(t: ^testing.T, rig: ^Works_Rig) -> bool {
	rig.files = {
		{"pack.json", transmute([]u8)string(WORKS_PACK)},
		{"data/blocks/works.json", transmute([]u8)string(WORKS_BLOCKS)},
	}
	config := harness_world()
	config.game = {
		info = {id = "works", name = "Works"},
		pack = {"works", rig.files[:]},
		server_state = Works_Log,
		machine_data = Oven,
		machine_shown = Oven_Shown,
		machines = works_think,
		machine_use = works_use,
	}
	if !testing.expect(t, session_start(&rig.sess, {}, false, with = config)) {return false}
	_, ok := harness_step_until(&rig.sess.h, proc(data: rawptr) -> bool {
			sess := (^Session)(data)
			return sess.mirror.welcomed && sess.h.srv.clients[0].state == .Playing
		}, &rig.sess, 600)
	return testing.expect(t, ok, "never playing")
}

@(test)
test_machines_think_when_woken_in_batches_by_kind :: proc(t: ^testing.T) {
	rig := new(Works_Rig)
	defer free(rig)
	defer session_stop(&rig.sess)
	if !works_start(t, rig) {return}
	s := &rig.sess.h.srv
	w := s.home
	oven, _ := game.registry_block(s.registry, "works:oven")
	mill, _ := game.registry_block(s.registry, "works:mill")
	act := game_act(s, w, .Structure)
	ovens := [3]game.Block_Pos{{3, 1, 0}, {1, 1, 0}, {2, 1, 0}}
	for p in ovens {testing.expect(t, set_block(w, p, oven, act))}
	testing.expect(t, set_block(w, {0, 1, 4}, mill, act))
	l := game_state(s, Works_Log)

	// Built: a zero record, slots of its kind, asleep.
	o := machine_data(w, ovens[0], Oven)
	if !testing.expect(t, o != nil) {return}
	testing.expect_value(t, o^, Oven{})
	testing.expect_value(t, len(machine_slots(w, ovens[0])), 2)
	testing.expect_value(t, len(machine_slots(w, {0, 1, 4})), 0)
	testing.expect(t, machine_data(w, {9, 1, 9}, Oven) == nil, "a record where no machine is")
	harness_step(&rig.sess.h, 10)
	testing.expect_value(t, l.count, 0)

	// Woken: each thinks once, when due, the ovens in one call and the mill in another.
	for p in ovens {machine_wake(w, p, 5)}
	machine_wake(w, {0, 1, 4}, 5)
	machine_wake(w, ovens[0], 9) // (already sooner: stays at 5)
	woken := s.tick
	harness_step(&rig.sess.h, 4)
	testing.expect_value(t, l.count, 0)
	harness_step(&rig.sess.h, 4)
	if !testing.expect_value(t, l.count, 2) {return}
	oven_type := s.registry.blocks.type_of[oven]
	testing.expect_value(t, l.batches[0].kind, min(oven_type, s.registry.blocks.type_of[mill]))
	for b in l.batches[:l.count] {
		testing.expect_value(t, b.n, 3 if b.kind == oven_type else 1)
		testing.expect_value(t, b.tick, woken + 5)
	}
	for p in ovens {testing.expect_value(t, machine_data(w, p, Oven).thought, 1)}
	harness_step(&rig.sess.h, 20)
	testing.expect_value(t, l.count, 2) // (once per wake)

	// Asleep again when told.
	machine_wake(w, ovens[1], 2)
	machine_sleep(w, ovens[1])
	harness_step(&rig.sess.h, 5)
	testing.expect_value(t, l.count, 2)

	// What it shows reaches the player who has its chunk.
	shown := Oven_Shown{7}
	machine_show(w, ovens[2], &shown)
	harness_step(&rig.sess.h, 3)
	got, told := rig.sess.mirror.machines[ovens[2]]
	testing.expect(t, told && got[0] == 7, "the player was not shown the machine")

	// Used: the game hears it.
	c := &s.clients[0]
	c.player.position = {2.5, 1, 2.5}
	use_block(s, c, ovens[1])
	testing.expect_value(t, l.uses, 1)
	testing.expect_value(t, l.used, ovens[1])

	// Broken: gone, what it held spilled, never thinking again.
	machine_slots(w, ovens[0])[1] = {game.item_of_block(s.registry, .Stone), 4, 0, 0}
	machine_wake(w, ovens[0], 1)
	testing.expect(t, set_block(w, ovens[0], .Air, act))
	testing.expect(t, machine_data(w, ovens[0], Oven) == nil)
	before := l.count
	harness_step(&rig.sess.h, 3)
	testing.expect_value(t, l.count, before)
}
