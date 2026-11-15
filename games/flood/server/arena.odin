package flood_server

import "core:log"

import "common:game"
import "games:flood"
import "server:core"

// The arena: built for each round from its seed, then flooded a layer at a time. Every
// block goes through the edit journal under a cause of the game's (core.game_act).

// ARENA: what the game keeps loaded and builds in: the walls around the inside and the
// stone under its floor.
ARENA :: core.Box{{-1, -3, -1}, {flood.SIZE, flood.WALL_TOP, flood.SIZE}}

// INSIDE: the arena's inside, floor to ceiling.
INSIDE :: core.Box{{0, 0, 0}, {flood.SIZE - 1, flood.HEIGHT - 1, flood.SIZE - 1}}

// build: the walls, the stone under the floor (blasting through it finds stone, not the
// open flat world) and the round's arena, with no water; false while its chunks are not
// all loaded, unless force (the wait is over: what is there is built, and said).
build :: proc(s: ^core.Server, force: bool) -> bool {
	w := s.home
	f := state(s)
	ready := core.world_ready(w, ARENA)
	if !ready && !force {return false}
	act := core.game_act(s, w, .Structure)
	lo, hi := ARENA.lo, ARENA.hi
	walls := [4]core.Box {
		{{lo.x, lo.y, lo.z}, {lo.x, hi.y, hi.z}},
		{{hi.x, lo.y, lo.z}, {hi.x, hi.y, hi.z}},
		{{0, lo.y, lo.z}, {flood.SIZE - 1, hi.y, lo.z}},
		{{0, lo.y, hi.z}, {flood.SIZE - 1, hi.y, hi.z}},
	}
	for wall in walls {
		core.bulk_edit(w, {shape = wall, op = .Set, block = .Bedrock, partial = true}, act)
	}
	under := core.Box{{0, lo.y, 0}, {flood.SIZE - 1, -1, flood.SIZE - 1}}
	core.bulk_edit(w, {shape = under, op = .Set, block = .Stone, partial = true}, act)
	t := arena_template(f.seed, &f.goal)
	changed, _, _ := core.bulk_edit(
		w,
		{shape = INSIDE, op = .Paste, template = &t, partial = true},
		act,
	)
	log.infof(
		"flood arena built round=%d seed=%d rule=%s goal=%v changed=%d all_loaded=%v",
		f.round,
		f.seed,
		flood.RULE_NAMES[f.rule],
		f.goal,
		changed,
		ready,
	)
	f.level, f.rot_last, f.rotted = 0, 0, 0
	for &at in f.wet_at {at = -1}
	f.built = true
	return true
}

// Arena_Rng: the arena's own generator, so its seed alone decides it.
Arena_Rng :: struct {
	state: u64,
}

arena_next :: proc(r: ^Arena_Rng) -> u64 {
	r.state += 0x9e3779b97f4a7c15
	z := r.state
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return z ~ (z >> 31)
}

// arena_int: lo..hi inclusive.
arena_int :: proc(r: ^Arena_Rng, lo, hi: i32) -> i32 {
	if hi <= lo {return lo}
	return lo + i32(arena_next(r) % u64(hi - lo + 1))
}

// arena_template: the arena's blocks for a seed, SIZE x HEIGHT x SIZE (temp allocator),
// and where its goal platform is. Pillars rise from the floor (hook and climb targets);
// wide overhangs with a hole or two cross it (go round, or blast through); ledges are
// staggered 2..4 blocks apart, so a plain jump (1.25) never reaches the next, the boots'
// double jump sometimes does, and the hook and the rockets always do. The spawn stays
// clear, and the goal is a lamp platform in a corner with nothing over it.
arena_template :: proc(seed: u32, goal: ^[2]i32) -> game.Template {
	t := game.Template {
		size  = {flood.SIZE, flood.HEIGHT, flood.SIZE},
		cells = make([]u16, flood.SIZE * flood.HEIGHT * flood.SIZE, context.temp_allocator),
	}
	box :: proc(t: ^game.Template, lo, hi: [3]i32, b: game.Block) {
		for y in max(lo.y, 0) ..= min(hi.y, flood.HEIGHT - 1) {
			for z in max(lo.z, 0) ..= min(hi.z, flood.SIZE - 1) {
				for x in max(lo.x, 0) ..= min(hi.x, flood.SIZE - 1) {
					t.cells[game.template_index(t, {x, y, z})] = u16(b)
				}
			}
		}
	}
	in_spawn :: proc(x, z: i32) -> bool {return x >= 12 && x <= 20 && z >= 12 && z <= 20}
	r := Arena_Rng{u64(seed) * 0x2545f4914f6cdd1d + 1}
	box(&t, {0, 0, 0}, {flood.SIZE - 1, 0, flood.SIZE - 1}, .Stone)

	for _ in 0 ..< arena_int(&r, 4, 7) {
		w := arena_int(&r, 2, 3)
		x, z := arena_int(&r, 1, flood.SIZE - 1 - w), arena_int(&r, 1, flood.SIZE - 1 - w)
		if in_spawn(x, z) || in_spawn(x + w, z + w) {continue}
		top := arena_int(&r, 12, 64)
		b := game.Block.Log if arena_next(&r) % 2 == 0 else .Stone_Bricks
		box(&t, {x, 1, z}, {x + w - 1, top, z + w - 1}, b)
	}
	for y := i32(22); y < flood.GOAL_Y - 10; y += arena_int(&r, 18, 24) {
		w, d := arena_int(&r, 14, 22), arena_int(&r, 14, 22)
		x, z := arena_int(&r, 0, flood.SIZE - w), arena_int(&r, 0, flood.SIZE - d)
		box(&t, {x, y, z}, {x + w - 1, y, z + d - 1}, .Cobblestone)
		for _ in 0 ..< arena_int(&r, 1, 2) {
			hx, hz := arena_int(&r, x + 1, x + w - 4), arena_int(&r, z + 1, z + d - 4)
			box(&t, {hx, y, hz}, {hx + 2, y, hz + 2}, .Air)
		}
	}
	materials := [?]game.Block{.Dirt, .Planks, .Sandstone, .Clay, .Glass, .Stone, .Gravel}
	for y := i32(3); y < flood.GOAL_Y - 2; y += arena_int(&r, 2, 4) {
		band := min(int(y) * len(materials) / flood.GOAL_Y, len(materials) - 1)
		for _ in 0 ..< arena_int(&r, 2, 3) {
			w, d := arena_int(&r, 3, 7), arena_int(&r, 2, 5)
			x, z: i32
			if arena_next(&r) % 3 == 0 { 	// against a wall
				if arena_next(&r) % 2 == 0 {
					x = 0 if arena_next(&r) % 2 == 0 else flood.SIZE - w
					z = arena_int(&r, 0, flood.SIZE - d)
				} else {
					z = 0 if arena_next(&r) % 2 == 0 else flood.SIZE - d
					x = arena_int(&r, 0, flood.SIZE - w)
				}
			} else {
				x, z = arena_int(&r, 0, flood.SIZE - w), arena_int(&r, 0, flood.SIZE - d)
			}
			m := materials[band]
			if arena_next(&r) % 5 == 0 {m = materials[arena_next(&r) % len(materials)]}
			box(&t, {x, y, z}, {x + w - 1, y, z + d - 1}, m)
		}
	}
	box(&t, {12, 1, 12}, {20, 4, 20}, .Air) // the spawn, with a step up out of it
	corner := arena_next(&r) % 4
	far := i32(flood.SIZE - 2 - flood.GOAL_SIZE)
	goal^ = {2 if corner & 1 == 0 else far, 2 if corner & 2 == 0 else far}
	g := goal^
	box(
		&t,
		{g.x - 1, flood.GOAL_Y - 1, g.y - 1},
		{g.x + flood.GOAL_SIZE, flood.HEIGHT - 1, g.y + flood.GOAL_SIZE},
		.Air,
	)
	box(
		&t,
		{g.x, flood.GOAL_Y, g.y},
		{g.x + flood.GOAL_SIZE - 1, flood.GOAL_Y, g.y + flood.GOAL_SIZE - 1},
		.Lamp,
	)
	for c in ([4][2]i32{{0, 0}, {1, 0}, {0, 1}, {1, 1}}) { 	// a lamp post at each corner, seen from below
		post := g + c * (flood.GOAL_SIZE - 1)
		box(&t, {post.x, flood.GOAL_Y + 1, post.y}, {post.x, flood.GOAL_Y + 2, post.y}, .Lamp)
	}
	return t
}

// WATER: every water block, the falling one with them (a layer drained is all of them).
WATER :: [?]game.Block {
	.Water,
	.Water_1,
	.Water_2,
	.Water_3,
	.Water_4,
	.Water_5,
	.Water_6,
	.Water_7,
	.Water_Falling,
}

// water_tick moves the water a layer toward target: up, filling the air of the next
// layer, or down, draining the top one.
water_tick :: proc(s: ^core.Server, target: i32) {
	f := state(s)
	if target == f.level {return}
	w := s.home
	act := core.game_act(s, w, .Liquid)
	if target > f.level {
		f.level += 1
		layer := core.Box{{0, f.level, 0}, {flood.SIZE - 1, f.level, flood.SIZE - 1}}
		core.bulk_edit(
			w,
			{shape = layer, op = .Replace, from = .Air, block = .Water, partial = true},
			act,
		)
		return
	}
	layer := core.Box{{0, f.level, 0}, {flood.SIZE - 1, f.level, flood.SIZE - 1}}
	for b in WATER {
		core.bulk_edit(
			w,
			{shape = layer, op = .Replace, from = b, block = .Air, partial = true},
			act,
		)
	}
	f.level -= 1
}

// rot_tick: Rot: each block crumbles a few seconds after the water (or its splash) first
// reached its layer, at a moment of its own; under the water it becomes water.
rot_tick :: proc(s: ^core.Server, t: f32) {
	f := state(s)
	w := s.home
	if f.level > 0 {
		for y in 0 ..= min(f.level + flood.ROT_SPLASH, flood.HEIGHT - 1) {
			if f.wet_at[y] < 0 {f.wet_at[y] = t}
		}
	}
	act: Maybe(core.Act) // (one cause for the tick's crumbling, made when something crumbles)
	for y in i32(0) ..< flood.HEIGHT {
		at := f.wet_at[y]
		if at < 0 {break}
		begins := at + flood.ROT_DELAY
		if t < begins || f.rot_last > begins + flood.ROT_SPREAD {continue}
		for z in i32(0) ..< flood.SIZE {
			for x in i32(0) ..< flood.SIZE {
				due := begins + rot_moment(x, y, z, f.seed) * flood.ROT_SPREAD
				if due <= f.rot_last || due > t {continue}
				p := game.Block_Pos{x, y, z}
				b, loaded := core.block_at(w, p)
				if !loaded || b == .Air || b == .Lamp || b == .Bedrock {continue}
				if _, wet := game.water_level(b); wet {continue}
				if act == nil {act = core.game_act(s, w, .Liquid)}
				core.set_block(w, p, .Water if y <= f.level else .Air, act.?)
				f.rotted += 1
			}
		}
	}
	f.rot_last = t
}

// rot_moment: when in its layer's spread the block at x, y, z crumbles, 0..1, by the seed.
rot_moment :: proc(x, y, z: i32, seed: u32) -> f32 {
	h := u32(x) * 73856093 ~ u32(y) * 19349663 ~ u32(z) * 83492791 ~ seed * 2654435761
	h ~= h >> 13
	h *= 0x5bd1e995
	h ~= h >> 15
	return f32(h & 0xffff) / 65535
}
