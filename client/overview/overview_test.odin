package overview

import "core:testing"

import "client:engine"
import "client:ui"

// The parts of commanding from above that need no frame: a selection's picks and its
// control groups, entities that leave the session or the side falling out of both, the
// minimap's points both ways and the fog's cells. (A box drawn with the pointer over a
// battle is played whole by games/skirmish's client tests, which do not run while the game
// is shelved.)

@(test)
test_a_selection_keeps_groups_and_drops_the_gone :: proc(t: ^testing.T) {
	s := new(engine.Session)
	defer free(s)
	defer delete(s.entities)
	for id in u32(1) ..= 5 {s.entities[id] = {
			team = 1 if id != 5 else 2,
		}}
	sel := new(Selection)
	defer free(sel)
	selection_add(sel, 1)
	selection_add(sel, 2)
	selection_add(sel, 2) // (once)
	selection_add(sel, 5)
	testing.expect_value(t, len(selected(sel)), 3)
	group_keep(sel, 3)
	selection_remove(sel, 1)
	testing.expect(t, !is_selected(sel, 1) && is_selected(sel, 2))
	selection_clear(sel)
	testing.expect(t, group_pick(sel, 3))
	testing.expect_value(t, len(selected(sel)), 3)
	testing.expect(t, !group_pick(sel, 4), "an empty group picked")
	// 2 dies and 5 is not of the side: both fall out, of the set and of the group.
	delete_key(&s.entities, 2)
	selection_prune(sel, s, 1)
	testing.expect_value(t, len(selected(sel)), 1)
	testing.expect_value(t, selected(sel)[0], 1)
	selection_clear(sel)
	group_pick(sel, 3)
	testing.expect_value(t, len(selected(sel)), 1)
}

@(test)
test_the_minimap_and_the_fog_map_points :: proc(t: ^testing.T) {
	m: Minimap
	testing.expect(t, minimap_init(&m, {-64, -64}, {63, 63}, 0, 32, 2))
	defer delete(m.colors)
	testing.expect_value(t, m.size, [2]int{64, 64})
	r := ui.Rect{1000, 500, 256, 256}
	p := minimap_point(&m, r, 0, 32)
	testing.expect_value(t, p, [2]f32{1128, 692})
	back := minimap_world(&m, r, p)
	testing.expect_value(t, back, [2]f64{0, 32})

	f: Fog
	testing.expect(t, fog_init(&f, {-64, -64}, {63, 63}, 0, 32) == nil)
	defer {delete(f.seen); delete(f.explored); delete(f.height)}
	i, on := fog_cell(&f, -64, -64)
	testing.expect(t, on && i == 0)
	_, off := fog_cell(&f, 64.5, 0)
	testing.expect(t, !off, "a cell past the map")
	f.seen[i] = true
	testing.expect(t, fog_sees(&f, -63.5, -63.5) && !fog_sees(&f, -60, -64))
}
