package core

import "common:game"

// The flow behaviour: a fluid (data/sim/*.json, behaviour "flow") spreads by discrete
// cellular automata rules: a source (level 0) stays; flowing levels 1..n live as long
// as something feeds them (the fluid above, or beside it one level stronger), and spread
// down first, else sideways one level weaker, towards the nearest way down within `reach`
// blocks (every way, when there is none). Between two sources over firm ground a new source
// forms, if the rule says so. The numbers and the blocks are the rule's (game.Fluid);
// water's are assets/packs/voxiverse/data/sim/water.json.

@(private = "file", rodata)
SIDES := [4]game.Block_Pos{{1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1}}

// Flow: what the rule's code needs at hand.
@(private = "file")
Flow :: struct {
	w:       ^World,
	f:       ^game.Fluid,
	rule:    u16, // plus one: the key in the registry's flow_rule table
	weakest: i32, // the last flowing level
	falling: i32, // the falling level
}

@(private = "file")
flow_make :: proc(w: ^World, rule: u16) -> Flow {
	f := &w.server.registry.sim.rules[rule].fluid
	return {w, f, rule + 1, i32(len(f.levels)) - 1, i32(len(f.levels))}
}

// level_of: b's level in this fluid (false if b is not of it), by the registry's tables.
@(private = "file")
level_of :: #force_inline proc(fl: ^Flow, b: game.Block) -> (level: i32, ok: bool) {
	sim := &fl.w.server.registry.sim
	if int(b) >= len(sim.flow_rule) || sim.flow_rule[b] != fl.rule {return 0, false}
	return i32(sim.flow_level[b]) - 1, true
}

// takes_fluid: fluid of level may flow into a block that is b: air, or what gives way
// (tall grass; flowers wash away), or weaker fluid of this kind. A block of another
// fluid is never taken (fluids do not mix).
@(private = "file")
takes_fluid :: proc(fl: ^Flow, b: game.Block, level: i32) -> bool {
	if l, ours := level_of(fl, b); ours {
		if l == 0 || l == fl.falling {return false}
		return level == fl.falling || level < l
	}
	t := &fl.w.server.registry.blocks
	sim := &fl.w.server.registry.sim
	if int(b) < len(sim.flow_rule) && sim.flow_rule[b] != 0 {return false}
	return(
		b == .Air ||
		game.block_has(t, b, .Replaceable) ||
		(!game.block_collides(t, b) && game.block_has(t, b, .Breakable)) \
	)
}

// flow_restless: a cell of the fluid that could change: flowing, or a source next to
// somewhere it could flow (still lakes and seas are left alone).
flow_restless :: proc(w: ^World, p: game.Block_Pos, rule: u16) -> bool {
	fl := flow_make(w, rule)
	b, loaded := chunks_block(&w.chunks, p)
	level, ours := level_of(&fl, b)
	if !loaded || !ours {return false}
	if level != 0 {return true}
	for d in ([5]game.Block_Pos{{1, 0, 0}, {-1, 0, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}) {
		nb, n_loaded := chunks_block(&w.chunks, p + d)
		if n_loaded && takes_fluid(&fl, nb, fl.weakest) {return true}
	}
	return false
}

// flow_update: the fluid at p takes the state its neighbours give it, then spreads.
flow_update :: proc(w: ^World, p: game.Block_Pos, rule: u16, action: Action_Id) {
	fl := flow_make(w, rule)
	// (no action: woken by a chunk loading, it is the world's own)
	act := Act{action, .Liquid} if action != 0 else world_act(w, .Liquid)
	b, loaded := chunks_block(&w.chunks, p)
	level, ours := level_of(&fl, b)
	if !loaded || !ours {return}
	if level != 0 {
		want, alive := fed_level(&fl, p)
		if !alive {
			set_block(w, p, .Air, act)
			return
		}
		if want != level {
			set_block(w, p, game.fluid_block(fl.f, want), act)
			level = want
		}
	}
	// Down first.
	below := p + {0, -1, 0}
	under, under_loaded := chunks_block(&w.chunks, below)
	if !under_loaded {return}
	if takes_fluid(&fl, under, fl.falling) {
		set_block(w, below, fl.f.falling, act)
		return
	}
	// On firm ground (or on the fluid), sideways, a level weaker.
	if _, on_fluid := level_of(&fl, under); on_fluid && level != 0 && level != fl.falling {return}
	next := i32(1) if level == 0 || level == fl.falling else level + 1
	if next > fl.weakest {return}
	ways := ways_down(&fl, p)
	for d, i in SIDES {
		if !ways[i] {continue}
		n := p + d
		nb, n_loaded := chunks_block(&w.chunks, n)
		if n_loaded &&
		   takes_fluid(&fl, nb, next) {set_block(w, n, game.fluid_block(fl.f, next), act)}
	}
}

// fed_level: the level flowing fluid at p should have, from what feeds it (false:
// nothing does; it dries up).
@(private = "file")
fed_level :: proc(fl: ^Flow, p: game.Block_Pos) -> (level: i32, alive: bool) {
	w := fl.w
	above, _ := chunks_block(&w.chunks, p + {0, 1, 0})
	if _, ours := level_of(fl, above); ours {return fl.falling, true}
	sources := 0
	best := fl.falling
	for d in SIDES {
		nb, _ := chunks_block(&w.chunks, p + d)
		l, ours := level_of(fl, nb)
		if !ours {continue}
		if l == 0 {sources += 1}
		// Falling fluid feeds what is beside it as a source would (it only spreads where
		// it cannot fall, so no curtains form in the air).
		best = min(best, 0 if l == fl.falling else l)
	}
	if fl.f.sources_form && sources >= 2 {
		// Between two sources over firm ground (or a source): a source.
		under, _ := chunks_block(&w.chunks, p + {0, -1, 0})
		if l, ours := level_of(fl, under);
		   game.block_collides(&w.server.registry.blocks, under) || (ours && l == 0) {
			return 0, true
		}
	}
	if best >= fl.weakest {return 0, false}
	return best + 1, true
}

// ways_down: which sides lead to the nearest way down within reach (a block the fluid
// can fall from); every side it can take when none do.
@(private = "file")
ways_down :: proc(fl: ^Flow, p: game.Block_Pos) -> (ways: [4]bool) {
	reach := fl.f.reach
	best := reach + 1
	dist: [4]i32
	can_take: [4]bool
	for d, i in SIDES {
		nb, loaded := chunks_block(&fl.w.chunks, p + d)
		if !loaded || !takes_fluid(fl, nb, fl.weakest) {
			dist[i] = reach + 1
			continue
		}
		can_take[i] = true
		under, _ := chunks_block(&fl.w.chunks, p + d + {0, -1, 0})
		if takes_fluid(fl, under, fl.falling) {
			dist[i] = 1
			best = 1
			continue
		}
		if best <= 1 {
			dist[i] = reach + 1
			continue
		}
		dist[i] = distance_down(fl, p + d, d, 1, best)
		best = min(best, dist[i])
	}
	for _, i in SIDES {
		ways[i] = can_take[i] && (best > reach || dist[i] == best)
	}
	return
}

// distance_down: steps from p (reached in steps) to a block the fluid could fall from,
// going on in any direction but back (reach + 1: none).
@(private = "file")
distance_down :: proc(fl: ^Flow, p, came: game.Block_Pos, steps: i32, max_steps: i32) -> i32 {
	reach := fl.f.reach
	limit := min(reach, max_steps)
	if steps >= limit {return reach + 1}
	b, loaded := chunks_block(&fl.w.chunks, p)
	if !loaded || !takes_fluid(fl, b, fl.weakest) {return reach + 1}
	under, _ := chunks_block(&fl.w.chunks, p + {0, -1, 0})
	if takes_fluid(fl, under, fl.falling) {return steps}
	best := reach + 1
	for d in SIDES {
		if d == -came {continue}
		best = min(best, distance_down(fl, p + d, d, steps + 1, min(limit, best)))
	}
	return best
}
