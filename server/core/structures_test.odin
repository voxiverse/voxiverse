package core

import "core:testing"

import "common:game"

// A game's building as itself: it fits where its cells are clear and its ground even
// enough; it goes up in one bulk edit through the journal, turned as asked; taken down,
// its blocks go and what changed since stays; a template written as text holds its rows.

@(test)
test_structure_fits_places_and_goes :: proc(t: ^testing.T) {
	h := new(Harness)
	defer free(h)
	config := harness_world()
	if !testing.expect(t, harness_start(h, config)) {return}
	defer harness_stop(h)
	w := h.srv.home
	area := Box{{-8, -4, -8}, {16, 8, 16}}
	world_keep(w, area)
	ready :: proc(data: rawptr) -> bool {return world_ready(
			(^World)(data),
			{{-8, -4, -8}, {16, 8, 16}},
		)}
	if _, ok := harness_step_until(h, ready, w, 300); !testing.expect(t, ok) {return}
	planks := u16(game.Block.Planks)
	// A hut 3 x 2 x 2 (x by z): planks walls, its front row open below, air inside.
	tmpl, built := game.template_build({"PPP/P_P", "PPP/PPP"}, "P_", {planks, u16(game.Block.Air)})
	if !testing.expect(t, built) {return}
	defer delete(tmpl.cells)
	testing.expect_value(t, tmpl.size, [3]i32{3, 2, 2})
	_, uneven := game.template_build({"PP/P", "PP/PP"}, "P", {planks})
	testing.expect(t, !uneven, "rows of uneven length were taken")

	// The flat world's ground is y -1: the hut stands on y 0.
	testing.expect_value(t, structure_fit(w, &tmpl, {0, 0, 0}, 0), Structure_Fit.Fits)
	testing.expect_value(t, structure_fit(w, &tmpl, {0, 1, 0}, 0), Structure_Fit.Uneven)
	testing.expect_value(
		t,
		structure_fit(w, &tmpl, {0, 1, 0}, 0, max_step = 1),
		Structure_Fit.Fits,
	)
	testing.expect_value(t, structure_fit(w, &tmpl, {0, -1, 0}, 0), Structure_Fit.Blocked)
	set_block(w, {4, 0, 4}, .Stone, world_act(w, .Command))
	testing.expect_value(t, structure_fit(w, &tmpl, {4, 0, 3}, 1), Structure_Fit.Blocked)

	journal := w.journal.next_action
	changed, result := structure_place(w, &tmpl, {0, 0, 0}, 1, world_act(w, .Structure))
	testing.expect_value(t, result, Bulk_Result.Done)
	testing.expect_value(t, changed, 11) // (12 cells, one of them air)
	testing.expect_value(t, w.journal.next_action, journal + 1)
	// Turned a quarter, its x is the template's z: 2 x 2 x 3.
	b, _ := chunks_block(&w.chunks, {1, 1, 2})
	testing.expect_value(t, b, game.Block.Planks)
	b, _ = chunks_block(&w.chunks, {2, 0, 0})
	testing.expect_value(t, b, game.Block.Air)

	// Someone changes one of its blocks; taken down, that one stays.
	set_block(w, {0, 1, 0}, .Stone, world_act(w, .Command))
	changed, result = structure_remove(w, &tmpl, {0, 0, 0}, 1, world_act(w, .Structure))
	testing.expect_value(t, result, Bulk_Result.Done)
	testing.expect_value(t, changed, 10)
	b, _ = chunks_block(&w.chunks, {0, 1, 0})
	testing.expect_value(t, b, game.Block.Stone)
	b, _ = chunks_block(&w.chunks, {1, 1, 2})
	testing.expect_value(t, b, game.Block.Air)
}
