package core

import "core:testing"

import "common:game"
import "server:grid"

// Grids (grids.odin): a world's network follows its blocks: built, broken, as a game's
// edits make and unmake them.

@(private = "file")
LINES_PACK :: `{"format": 1, "namespace": "lines", "version": "1.0.0", "title": "Lines", "requires": ["voxiverse"]}`
@(private = "file")
LINES_BLOCKS :: `{
	"cable": {"textures": {"all": "voxiverse:stone"}},
	"pole": {"textures": {"all": "voxiverse:planks"}},
	"lamp": {"textures": {"all": "voxiverse:glass"}, "entity": {"kind": "machine", "slots": 0}}
}`

@(private = "file")
Lines_Rig :: struct {
	sess:  Session,
	files: [2]game.Pack_File,
}

@(test)
test_a_grid_follows_the_blocks :: proc(t: ^testing.T) {
	rig := new(Lines_Rig)
	defer free(rig)
	defer session_stop(&rig.sess)
	rig.files = {
		{"pack.json", transmute([]u8)string(LINES_PACK)},
		{"data/blocks/lines.json", transmute([]u8)string(LINES_BLOCKS)},
	}
	config := harness_world()
	config.game = {
		info = {id = "lines", name = "Lines"},
		pack = {"lines", rig.files[:]},
	}
	if !testing.expect(t, session_start(&rig.sess, {}, false, with = config)) {return}
	_, ok := harness_step_until(&rig.sess.h, proc(data: rawptr) -> bool {
			sess := (^Session)(data)
			return sess.mirror.welcomed && sess.h.srv.clients[0].state == .Playing
		}, &rig.sess, 600)
	if !testing.expect(t, ok, "never playing") {return}
	s := &rig.sess.h.srv
	w := s.home
	cable, _ := game.registry_block(s.registry, "lines:cable")
	pole, _ := game.registry_block(s.registry, "lines:pole")
	lamp, _ := game.registry_block(s.registry, "lines:lamp")
	ty := s.registry.blocks.type_of
	act := game_act(s, w, .Structure)
	// Two lamps on a cable before the grid opens: found as it opens.
	for x in i32(0) ..< 4 {set_block(w, {x, 1, 0}, cable, act)}
	set_block(w, {0, 2, 0}, lamp, act)
	set_block(w, {3, 2, 0}, lamp, act)
	g := grid_open(
		w,
		{{type = ty[cable]}, {type = ty[pole], reach = 4}, {type = ty[lamp], node = true}},
	)
	testing.expect_value(t, len(grid_parts(w, g)), 1)
	testing.expect(t, grid_node(w, g, {0, 2, 0}))
	// A pole three blocks off reaches the line, a lamp by it joins.
	set_block(w, {7, 1, 0}, pole, act)
	set_block(w, {8, 1, 0}, lamp, act)
	parts := grid_parts(w, g)
	testing.expect_value(t, len(parts), 1)
	testing.expect_value(t, len(parts[0].members), 8)
	// The pole broken: the far lamp is cut off.
	set_block(w, {7, 1, 0}, .Air, act)
	testing.expect_value(t, len(grid_parts(w, g)), 2)
	a, _ := grid_part_at(w, g, {0, 2, 0})
	b, _ := grid_part_at(w, g, {8, 1, 0})
	testing.expect(t, a != b, "a lamp the broken pole fed is still on the line")
	_ = grid.MAX_REACH
}
