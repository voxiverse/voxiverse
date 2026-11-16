package core

import "core:testing"

import "common:game"

// Belts (belts.odin): the world's conveyors carry what the game puts on them to their end,
// stepping only while something on them moves, telling players the items as they are put
// on and taken off, and spilling them when broken.

@(private = "file")
CONVEY_PACK :: `{"format": 1, "namespace": "convey", "version": "1.0.0", "title": "Convey", "requires": ["voxiverse"]}`
@(private = "file")
CONVEY_BLOCKS :: `{
	"belt": {"states": {"facing": ["north", "east", "south", "west"]}, "default": {"facing": "east"},
	         "textures": {"all": "voxiverse:stone"}, "place": "facing", "entity": {"kind": "belt", "speed": 3}}
}`

@(private = "file")
Convey_Rig :: struct {
	sess:  Session,
	files: [2]game.Pack_File,
}

@(test)
test_belts_carry_items_to_their_end :: proc(t: ^testing.T) {
	rig := new(Convey_Rig)
	defer free(rig)
	defer session_stop(&rig.sess)
	rig.files = {
		{"pack.json", transmute([]u8)string(CONVEY_PACK)},
		{"data/blocks/convey.json", transmute([]u8)string(CONVEY_BLOCKS)},
	}
	config := harness_world()
	config.game = {
		info = {id = "convey", name = "Convey"},
		pack = {"convey", rig.files[:]},
	}
	if !testing.expect(t, session_start(&rig.sess, {}, false, with = config)) {return}
	_, ok := harness_step_until(&rig.sess.h, proc(data: rawptr) -> bool {
			sess := (^Session)(data)
			return sess.mirror.welcomed && sess.h.srv.clients[0].state == .Playing
		}, &rig.sess, 600)
	if !testing.expect(t, ok, "never playing") {return}
	s := &rig.sess.h.srv
	w := s.home
	east, _ := game.registry_block(s.registry, "convey:belt")
	north, _ := game.state_set(&s.registry.blocks, east, "facing", "north")
	act := game_act(s, w, .Structure)
	// Four east, then north round a corner for two.
	for x in i32(0) ..< 4 {set_block(w, {x, 1, 2}, east, act)}
	set_block(w, {4, 1, 2}, north, act)
	set_block(w, {4, 1, 1}, north, act)
	stone := game.item_of_block(s.registry, .Stone)
	planks := game.item_of_block(s.registry, .Planks)
	testing.expect(t, belt_put(w, {0, 1, 2}, stone))
	testing.expect(t, !belt_put(w, {0, 1, 2}, planks), "room at a start just used")
	testing.expect(t, !belt_put(w, {9, 1, 9}, stone), "an item on no belt")
	harness_step(&rig.sess.h, 4)
	testing.expect(t, belt_put(w, {0, 1, 2}, planks))
	harness_step(&rig.sess.h, 2)
	// Told as it went on.
	told, has := rig.sess.mirror.belts[{0, 1, 2}]
	testing.expect(t, has && told.count == 2, "the player was not told the belt's items")

	harness_step(&rig.sess.h, 120)
	end := belt_peek(w, {4, 1, 1})
	if !testing.expect_value(t, len(end), 2) {return}
	testing.expect_value(t, end[0].item, stone)
	testing.expect_value(t, end[1].item, planks)
	testing.expect_value(t, end[0].at, game.LANE_END)
	// Nothing moving: no belt is stepped.
	harness_step(&rig.sess.h, 1)
	testing.expect_value(t, len(w.belts.awake), 0)
	moves := w.belts.moves
	harness_step(&rig.sess.h, 30)
	testing.expect_value(t, w.belts.moves, moves)

	// Taken off its end: the next comes up.
	item, took := belt_take(w, {4, 1, 1})
	testing.expect(t, took && item == stone)
	harness_step(&rig.sess.h, 30)
	testing.expect_value(t, belt_peek(w, {4, 1, 1})[0].at, game.LANE_END)

	// Broken: what it carried spills.
	lying := 0
	it := entities_each(w)
	for _ in entities_next(&it) {lying += 1}
	testing.expect(t, set_block(w, {4, 1, 1}, .Air, act))
	after := 0
	it = entities_each(w)
	for _ in entities_next(&it) {after += 1}
	testing.expect_value(t, after, lying + 1)
}
