package rally_server

import "core:log"

import "common:game"
import "games:rally"
import "server:core"

// The course: laid out from its seed (rally.course_plan, which the client lays out too)
// and built in the sky over the flat world, through the edit journal as the game's.

// AREA: the box the course is built in (and kept loaded).
AREA :: core.Box {
	{0, rally.TOP - 1, -rally.WIDTH / 2},
	{rally.LENGTH - 1, rally.TOP + rally.RISE + 6, rally.WIDTH / 2 - 1},
}

// build: the course of the universe's seed; false while its chunks are not all loaded,
// unless force (the wait is over: what is there is built, and said).
build :: proc(s: ^core.Server, force: bool) -> bool {
	d := state(s)
	w := s.home
	loaded := core.world_ready(w, AREA)
	if !loaded && !force {return false}
	t := course_template(&d.course, d.pad, d.gate, d.hazard)
	act := core.game_act(s, w, .Structure)
	core.bulk_edit(w, {shape = AREA, op = .Paste, template = &t, partial = true}, act)
	log.infof(
		"rally course built seed=%d platforms=%d all_loaded=%v",
		d.seed,
		d.course.count,
		loaded,
	)
	d.built = true
	return true
}

// course_template: the course's blocks over AREA (temp memory): each platform of its
// kind's stone (the start and the finish lit), a gate of glowing posts and a beam over
// each checkpoint's platform, the hazard strips, and a beam of logs over each wide gap.
course_template :: proc(c: ^rally.Course, pad, gate, hazard: game.Block) -> game.Template {
	o := AREA.lo
	t := game.template_make(AREA.hi - AREA.lo + 1, context.temp_allocator)
	box :: proc(t: ^game.Template, o, lo, hi: [3]i32, b: game.Block) {
		game.template_fill(t, lo - o, hi - o, b)
	}
	stones := [?]game.Block{.Stone_Bricks, .Sandstone, .Planks, .Cobblestone, .Clay}
	for p, i in c.platforms[:c.count] {
		b := stones[i % len(stones)]
		#partial switch p.kind {
		case .Start, .Finish:
			b = pad
		}
		box(&t, o, p.lo, p.hi, b)
	}
	for k in 1 ..= rally.CHECKPOINTS {
		g := c.checkpoints[k]
		for side in ([2]i32{-3, 3}) {
			box(&t, o, {g.x, g.y - 2, g.z + side}, {g.x, g.y + 3, g.z + side}, gate)
		}
		box(&t, o, {g.x, g.y + 3, g.z - 3}, {g.x, g.y + 3, g.z + 3}, gate)
	}
	for h in c.hazards[:c.hazard_n] {box(&t, o, h.lo, h.hi, hazard)}
	for post in c.posts {
		if post.x == 0 {continue}
		box(&t, o, post - {1, 0, 1}, post + {1, 0, 1}, .Log)
	}
	return t
}

// place_at: where a racer stands at checkpoint k (its seat a step aside on the start),
// looking down the course.
place_at :: proc(c: ^rally.Course, k: int, seat: int) -> [3]f64 {
	g := c.checkpoints[k]
	side := f64(0)
	if k == 0 {side = f64(seat % 5) - 2}
	return {f64(g.x) + 0.5, f64(g.y), f64(g.z) + 0.5 + side}
}

// EAST: the look down the course (east, level).
EAST :: [2]f32{-1.5707964, 0}
