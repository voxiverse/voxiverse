package core

import "common:game"
import "common:voxel"

// Support: a block with a support rule (game.has_support_rule: a plant stands on a block
// that holds it, a ladder is against a face that holds it, a door's upper half on its
// lower one) goes when what holds it does, and drops its item as if it had been broken by
// hand (block_drop); a door's two halves drop one item between them, the lower half's.
//
// A change settles the blocks it may have unsettled (supports_settle): the six beside a
// block that changed, every block of a bulk edit's box and around it. The supported
// blocks that still hold are a spread: a fill from those standing on something that needs
// no support, each step from a block to one it holds; the others lost their footing.
// Of those, the ones that go are the ones that fail support_holds once what they stood on
// has gone, among the checked blocks or beside one that went, lowest first (by y, then z,
// then x), each told and journaled as a change of its own with the cause's action and
// how Support. A settle looks SUPPORT_REACH blocks around what it checks and spreads at
// most SUPPORT_BUDGET cells; a block past either that may have lost its footing waits in
// the update queue (sim.odin) and settles in the next tick, so a tower or a field of them
// goes over as many ticks as it takes, never all in one.

SUPPORT_REACH :: 8 // blocks around the checked ones a settle looks at
SUPPORT_BUDGET :: 1 << 20 // cells each of a settle's spreads takes at most

// SUPPORT_STEPS: from a block to one it holds, as the support rules allow: up (a plant on
// a plant, a door's upper half) or across (a ladder on what it is against).
@(rodata)
SUPPORT_STEPS := [6][3]i32{{0, 1, 0}, {1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1}, {0, -1, 0}}

// supports_settle: the supported blocks among checked that no longer hold go, and the ones
// that stood on them, by the cause's action (see above).
supports_settle :: proc(w: ^World, checked: voxel.Mask, action: Action_Id) {
	t := &w.server.registry.blocks
	query := game.Block_Query{&w.chunks, chunks_block, t, {}}
	region := voxel.Bounds{checked.bounds.lo - SUPPORT_REACH, checked.bounds.hi + SUPPORT_REACH}
	region.lo.y = max(region.lo.y, game.WORLD_MIN_Y)
	region.hi.y = min(region.hi.y, game.WORLD_MAX_Y)
	// The checked blocks that no longer hold: nearly always none, and then nothing more.
	failing: voxel.Mask
	cursor := 0
	for lo, n in voxel.runs_next(checked, &cursor) {
		for k in 0 ..< n {
			if !support_fails(w, lo + {k, 0, 0}) {continue}
			if failing.words == nil {failing = voxel.mask_make(region, context.temp_allocator)}
			voxel.mask_set(&failing, lo + {k, 0, 0})
		}
	}
	if failing.words == nil {return}

	needs := make([]bool, t.count, context.temp_allocator)
	for b in 0 ..< t.count {needs[b] = game.has_support_rule(t, game.Block(b))}
	supported := voxel.mask_make(region, context.temp_allocator)
	world_mask(w, &supported, needs)

	// The blocks that hold: those standing on what needs no support hold from the start
	// (a block beyond the region counts as such); one standing on a supported block one
	// step back along SUPPORT_STEPS[i] holds when that one does (on[i]); one standing on
	// two, or failing, does not.
	held := voxel.mask_make(region, context.temp_allocator)
	on: [len(SUPPORT_STEPS)]voxel.Mask
	cursor = 0
	for lo, n in voxel.runs_next(supported, &cursor) {
		for k in 0 ..< n {
			p := lo + {k, 0, 0}
			b, _ := chunks_block(&w.chunks, p)
			if !game.support_holds(t, b, p, query) {continue}
			steps, count := support_steps(t, b)
			chained, along := 0, -1
			for step in steps[:count] {
				if !voxel.mask_get(supported, p - step) {continue}
				chained += 1
				for s, i in SUPPORT_STEPS {if s == step {along = i}}
			}
			switch {
			case chained == 0:
				voxel.mask_set(&held, p)
			case chained == 1 && along >= 0:
				if on[along].words ==
				   nil {on[along] = voxel.mask_make(region, context.temp_allocator)}
				voxel.mask_set(&on[along], p)
			}
		}
	}
	// A fill along one step at a time through what holds and what stands that way: a
	// block joins only from the one it stands on. A chain that turns needs a round per
	// turn; one turning more often than there are rounds, or a spread out of budget,
	// leaves blocks counted as lost that hold, which costs a look, never a wrong block.
	for _ in 0 ..< len(SUPPORT_STEPS) {
		grew := false
		for step, i in SUPPORT_STEPS {
			if on[i].words == nil {continue}
			budget := SUPPORT_BUDGET
			added, _ := voxel.fill(
				&held,
				on[i],
				step_element(step),
				&budget,
				context.temp_allocator,
			)
			if added > 0 {grew = true}
		}
		if !grew {break}
	}
	lost := voxel.mask_make(region, context.temp_allocator)
	voxel.mask_copy(&lost, supported)
	voxel.subtract(&lost, held)

	// What may go: the lost blocks joined to a failing one through lost blocks.
	beside := voxel.neighbours(1, voxel.CUBE, context.temp_allocator)
	may := voxel.mask_make(region, context.temp_allocator)
	voxel.mask_copy(&may, failing)
	budget := SUPPORT_BUDGET
	voxel.fill(&may, lost, beside, &budget, context.temp_allocator)

	// What goes, lowest first, again until a pass takes nothing: a block that fails once
	// what it stood on has gone, checked or beside one that went.
	gone := voxel.mask_make(region, context.temp_allocator)
	looked, stopped := 0, false
	passes: for {
		went := false
		cursor = 0
		for lo, n in voxel.runs_next(may, &cursor) {
			for k in 0 ..< n {
				p := lo + {k, 0, 0}
				if voxel.mask_get(gone, p) {continue}
				if !voxel.mask_get(checked, p) && !touches(gone, p) {continue}
				if looked >= SUPPORT_BUDGET {
					stopped = true
					break passes
				}
				looked += 1
				if !support_fails(w, p) {continue}
				b, _ := chunks_block(&w.chunks, p)
				if !set_block(w, p, .Air, {action, .Support}) {continue}
				voxel.mask_set(&gone, p)
				went = true
				if !(t.types[t.type_of[b]].place == .Door &&
					   game.state_is(t, b, "half", "upper")) {
					block_drop(w, p, b)
				}
			}
		}
		if !went {break}
	}

	// The next tick settles what this one could not look at: a supported block beside one
	// that went, beyond the region or past what the spreads reached, and when the passes
	// ran out of budget, every block they had still to look at.
	wait :: proc(w: ^World, t: ^game.Block_Table, p: game.Block_Pos, action: Action_Id) {
		b, loaded := chunks_block(&w.chunks, p)
		if loaded && game.has_support_rule(t, b) {schedule(w, p, 1, action)}
	}
	cursor = 0
	for lo, n in voxel.runs_next(gone, &cursor) {
		for k in 0 ..< n {
			for d in SUPPORT_STEPS {
				q := lo + {k, 0, 0} + d
				if voxel.mask_get(gone, q) || (!stopped && voxel.mask_get(may, q)) {continue}
				if voxel.bounds_has(region, q) && !voxel.mask_get(lost, q) {continue}
				wait(w, t, q, action)
			}
		}
	}
	if stopped {
		cursor = 0
		for lo, n in voxel.runs_next(failing, &cursor) {
			for k in 0 ..< n {
				if !voxel.mask_get(gone, lo + {k, 0, 0}) {wait(w, t, lo + {k, 0, 0}, action)}
			}
		}
	}
}

// support_fails: the block at p has a support rule and does not hold (support_holds).
support_fails :: proc(w: ^World, p: game.Block_Pos) -> bool {
	t := &w.server.registry.blocks
	b, loaded := chunks_block(&w.chunks, p)
	if !loaded || !game.has_support_rule(t, b) {return false}
	return !game.support_holds(t, b, p, {&w.chunks, chunks_block, t, {}})
}

// supports_check_box settles every block in lo..hi and around it (a bulk edit's), a piece
// at a time along a box longer than a mask holds with its reach (a bulk edit's volume is
// bounded, not its sides).
supports_check_box :: proc(w: ^World, lo, hi: game.Block_Pos, action: Action_Id) {
	PIECE :: voxel.MAX_EXTENT / 2
	all := voxel.Bounds{lo - 1, hi + 2}
	for y := all.lo.y; y < all.hi.y; y += PIECE {
		for z := all.lo.z; z < all.hi.z; z += PIECE {
			for x := all.lo.x; x < all.hi.x; x += PIECE {
				from := game.Block_Pos{x, y, z}
				to := game.Block_Pos {
					min(x + PIECE, all.hi.x),
					min(y + PIECE, all.hi.y),
					min(z + PIECE, all.hi.z),
				}
				supports_settle(w, voxel.mask_full({from, to}, context.temp_allocator), action)
			}
		}
	}
}

// support_steps: the steps from what holds b to b (it stands one step on from each), as
// support_holds reads them: up from under it, across from behind it.
@(private = "file")
support_steps :: proc(t: ^game.Block_Table, b: game.Block) -> (steps: [2][3]i32, count: int) {
	def := &t.defs[b]
	if t.types[t.type_of[b]].place == .Door || def.support != game.NO_TAG {
		steps[count] = {0, 1, 0}
		count += 1
	}
	if t.types[t.type_of[b]].place != .Door && (def.back_full || def.back != game.NO_TAG) {
		if dir, has := game.facing_vector(t, b); has {
			steps[count] = dir
			count += 1
		}
	}
	return
}

// step_element: the origin and one step, a fill's moves along it.
@(private = "file")
step_element :: proc(step: [3]i32) -> voxel.Mask {
	lo := [3]i32{min(step.x, 0), min(step.y, 0), min(step.z, 0)}
	m := voxel.mask_make(
		{lo, lo + {abs(step.x), abs(step.y), abs(step.z)} + 1},
		context.temp_allocator,
	)
	voxel.mask_set(&m, {})
	voxel.mask_set(&m, step)
	return m
}

// touches: a block beside p (one of the six) is in m.
@(private = "file")
touches :: proc(m: voxel.Mask, p: game.Block_Pos) -> bool {
	for d in SUPPORT_STEPS {if voxel.mask_get(m, p + d) {return true}}
	return false
}

// shapes_update_box makes every block in lo..hi and around it follow its
// neighbours (a fence joins what was set beside it), as part of cause.
shapes_update_box :: proc(w: ^World, lo, hi: game.Block_Pos, cause: Act) {
	reg := w.server.registry
	query := game.Block_Query{&w.chunks, chunks_block, &reg.blocks, {}}
	for y in lo.y - 1 ..= hi.y + 1 {
		for z in lo.z - 1 ..= hi.z + 1 {
			for x in lo.x - 1 ..= hi.x + 1 {
				p := game.Block_Pos{x, y, z}
				b, loaded := chunks_block(&w.chunks, p)
				if !loaded {continue}
				if updated := game.shape_update(reg, b, p, query); updated != b {
					set_block(w, p, updated, cause)
				}
			}
		}
	}
}
