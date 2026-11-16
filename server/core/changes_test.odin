package core

import "core:testing"

import "common:game"

// A game's block hooks: editing may refuse a player's edit before it happens (the
// player is told why, the block stays), and block_changed hears of every change once a
// tick, before the game's tick: a player's (by that player), the game's own bulk edit
// (a box, by nobody).

@(private = "file")
Heard :: struct {
	changes: [8]Block_Change,
	count:   int,
}

@(private = "file")
heard :: proc(s: ^Server) -> ^Heard {return game_state(s, Heard)}

@(test)
test_a_game_hears_of_block_changes_and_may_refuse_an_edit :: proc(t: ^testing.T) {
	sess := new(Session)
	defer free(sess)
	config := harness_world()
	config.mode = "creative"
	config.game = {
		info = {id = "blocky", name = "Blocky"},
		server_state = Heard,
		editing = proc(
			s: ^Server,
			c: ^Client,
			at: game.Block_Pos,
			old, new: game.Block,
		) -> string {
			return "No stone here" if new == .Stone else ""
		},
		block_changed = proc(s: ^Server, w: ^World, change: Block_Change) {
			h := heard(s)
			if h.count < len(h.changes) {h.changes[h.count] = change}
			h.count += 1
		},
	}
	if !testing.expect(t, session_start(sess, {}, false, with = config)) {return}
	defer session_stop(sess)
	ready :: proc(data: rawptr) -> bool {
		sess := (^Session)(data)
		c := &sess.h.srv.clients[0]
		return sess.mirror.welcomed && c.state == .Playing && c.landing == nil
	}
	_, ok := harness_step_until(&sess.h, ready, sess, 300)
	if !testing.expect(t, ok, "the host never stood") {return}
	s := &sess.h.srv
	host := &s.clients[0]
	w := host.world
	at := game.Block_Pos{i32(host.player.position.x) + 2, 0, i32(host.player.position.z)}
	harness_step(&sess.h) // (what came before is told)
	heard(s).count = 0

	// Stone is refused, with the game's reason; the block stays air, nothing is heard.
	r := apply_edit(s, host, game.edit_plain(1, 0, at, .Stone))
	testing.expect(t, !r.accepted, "the game's refusal was not kept")
	b, _ := block_at(w, at)
	testing.expect_value(t, b, game.Block.Air)
	harness_step(&sess.h, 2)
	testing.expect(t, told(sess, "No stone here"), "the player was not told why")
	testing.expect_value(t, heard(s).count, 0)

	// Planks are let be: heard once, before the game's tick, by the host.
	r = apply_edit(s, host, game.edit_plain(2, 0, at, .Planks))
	testing.expect(t, r.accepted, "an edit the game allows was refused")
	testing.expect_value(t, heard(s).count, 0)
	harness_step(&sess.h)
	h := heard(s)
	if !testing.expect_value(t, h.count, 1) {return}
	testing.expect(t, h.changes[0].area == Box{at, at} && !h.changes[0].bulk)
	testing.expect(t, h.changes[0].old == .Air && h.changes[0].new == .Planks)
	testing.expect(t, h.changes[0].by == host, "not the host's")

	// The game's own fill: its box, in bulk, by nobody.
	area := Box{at + {0, 0, 2}, at + {3, 1, 4}}
	bulk_edit(w, {shape = area, op = .Set, block = .Glass}, game_act(s, w, .Structure))
	harness_step(&sess.h)
	if !testing.expect_value(t, h.count, 2) {return}
	testing.expect(t, h.changes[1].bulk && h.changes[1].area == area && h.changes[1].by == nil)
}

@(private = "file")
told :: proc(sess: ^Session, text: string) -> bool {
	for n in sess.mirror.notices {if n == text {return true}}
	return false
}
