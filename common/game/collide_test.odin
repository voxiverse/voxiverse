package game

import "core:testing"

import "common:base"

// Shared collision: collide_move and step_up give what body_step and
// player_step gave, cast_box finds the first hit, a box source collides like
// cells do.

@(private = "file")
Field :: struct {
	blocks: map[Block_Pos]Block,
	floor:  i32, // y below this: stone
}

@(private = "file")
field_query :: proc(f: ^Field, reg: ^Registry) -> Block_Query {
	return {f, proc(data: rawptr, p: Block_Pos) -> (Block, bool) {
			f := (^Field)(data)
			if b, ok := f.blocks[p]; ok {return b, true}
			return .Stone if p.y < f.floor else .Air, true
		}, &reg.blocks, {}}
}

@(private = "file")
SHAPES :: [?]string {
	"voxiverse:stone",
	"testpack:planks_slab[type=bottom]",
	"testpack:planks_slab[type=top]",
	"testpack:planks_stairs[facing=east,half=bottom]",
	"testpack:planks_stairs[facing=north,half=top]",
	"voxiverse:glass",
}

// random_field: 8x8x8 around the origin of random cells over a floor at y 0,
// every shape in the registry's states.
@(private = "file")
random_field :: proc(f: ^Field, reg: ^Registry, rng: ^base.Rng) {
	shapes: [len(SHAPES)]Block
	for s, i in SHAPES {
		b, ok := state_parse(reg, s)
		if !ok {panic(s)}
		shapes[i] = b
	}
	for x in i32(-4) ..< 4 {
		for y in i32(0) ..< 8 {
			for z in i32(-4) ..< 4 {
				if base.rng_int_max(rng, 3) == 0 {
					f.blocks[{x, y, z}] = shapes[base.rng_int_max(rng, len(shapes))]
				}
			}
		}
	}
}

@(private = "file")
random_box :: proc(rng: ^base.Rng) -> (position: [3]f64, half, height: f64) {
	position = {
		base.rng_f64_range(rng, -3, 3),
		base.rng_f64_range(rng, 0, 6),
		base.rng_f64_range(rng, -3, 3),
	}
	half = base.rng_f64_range(rng, 0.1, 0.5)
	height = base.rng_f64_range(rng, 0.2, 1.9)
	return
}

@(private = "file")
random_delta :: proc(rng: ^base.Rng) -> [3]f64 {
	return {
		base.rng_f64_range(rng, -0.6, 0.6),
		base.rng_f64_range(rng, -0.8, 0.8),
		base.rng_f64_range(rng, -0.6, 0.6),
	}
}

// The reference: body_step's loop as it was before collide_move (the same
// axes through sweep), copied here so the test compares against the old
// code, not against itself.
@(private = "file")
old_body_loop :: proc(
	q: Block_Query,
	position: [3]f64,
	width, height: f64,
	delta: [3]f64,
	velocity: [3]f32,
) -> (
	[3]f64,
	[3]f32,
	bool,
) {
	position, velocity, on_ground := position, velocity, false
	for axis in ([3]int{1, 0, 2}) {
		moved, hit := sweep(position, width, height, axis, delta[axis], q)
		position[axis] += moved
		if hit {
			if axis == 1 && delta.y < 0 {on_ground = true}
			velocity[axis] = 0
		}
	}
	return position, velocity, on_ground
}

// The reference: player_step's try_step_up as it was, with the player's
// constants passed in.
@(private = "file")
old_try_step_up :: proc(
	q: Block_Query,
	position: [3]f64,
	width, height: f64,
	from, delta: [3]f64,
	vel: [3]f32,
	step: f64,
) -> (
	p: [3]f64,
	v: [3]f32,
	ok: bool,
) {
	normal := abs(position.x - from.x) + abs(position.z - from.z)
	p = from
	rose, _ := sweep(p, width, height, 1, step, q)
	if rose <= 0 {return}
	p.y += rose
	v = vel
	for axis in ([2]int{0, 2}) {
		moved, hit := sweep(p, width, height, axis, delta[axis], q)
		p[axis] += moved
		if hit {v[axis] = 0}
	}
	dropped, landed := sweep(p, width, height, 1, -rose, q)
	if !landed {return}
	p.y += dropped
	if abs(p.x - from.x) + abs(p.z - from.z) <= normal {return}
	return p, v, true
}

@(test)
test_collide_matches_body_step :: proc(t: ^testing.T) {
	reg := states_registry(t)
	if reg == nil {return}
	f: Field
	defer delete(f.blocks)
	rng := base.rng_make(50)
	random_field(&f, reg, &rng)
	q := field_query(&f, reg)
	// A source that gives no boxes must change nothing either.
	none := q
	none.extra.boxes = proc(data: rawptr, lo, hi: [3]f64, out: ^[dynamic]World_Box) {}
	mismatches := 0
	for _ in 0 ..< 10_000 {
		pos, half, height := random_box(&rng)
		delta := random_delta(&rng)
		vel := [3]f32{f32(delta.x), f32(delta.y), f32(delta.z)} * 30
		wp, wv, wg := old_body_loop(q, pos, half * 2, height, delta, vel)
		for query in ([2]Block_Query{q, none}) {
			c := collide_move(query, pos, half, height, delta, vel, 0)
			if c.position != wp || c.velocity != wv || c.on_ground != wg || c.stepped {
				mismatches += 1
			}
		}
	}
	testing.expect_value(t, mismatches, 0)
}

@(test)
test_step_up_matches_player :: proc(t: ^testing.T) {
	reg := states_registry(t)
	if reg == nil {return}
	f: Field
	defer delete(f.blocks)
	rng := base.rng_make(51)
	random_field(&f, reg, &rng)
	q := field_query(&f, reg)
	stepped, mismatches := 0, 0
	for _ in 0 ..< 10_000 {
		pos := [3]f64 {
			base.rng_f64_range(&rng, -3, 3),
			f64(base.rng_int_max(&rng, 6)),
			base.rng_f64_range(&rng, -3, 3),
		}
		delta := random_delta(&rng)
		delta.y = -0.05 // standing: gravity presses down
		vel := [3]f32{f32(delta.x), 0, f32(delta.z)} * 30
		// player_step's moves, then its step-up.
		c := collide_move(q, pos, PLAYER_WIDTH / 2, PLAYER_HEIGHT, delta, vel, 0)
		if !c.on_ground || !(c.hit.x || c.hit.z) {continue}
		from := [3]f64{}
		{ 	// where the horizontal moves began: after the y move
			p := pos
			moved, _ := sweep(p, PLAYER_WIDTH, PLAYER_HEIGHT, 1, delta.y, q)
			p.y += moved
			from = p
		}
		wp, wv, wok := old_try_step_up(
			q,
			c.position,
			PLAYER_WIDTH,
			PLAYER_HEIGHT,
			from,
			delta,
			c.velocity,
			STEP_HEIGHT,
		)
		r, ok := step_up(
			q,
			c.position,
			PLAYER_WIDTH / 2,
			PLAYER_HEIGHT,
			from,
			delta,
			c.velocity,
			STEP_HEIGHT,
		)
		if ok != wok || (ok && (r.position != wp || r.velocity != wv)) {mismatches += 1}
		if ok {stepped += 1}
		// collide_move with a step does the same in one call.
		full := collide_move(q, pos, PLAYER_WIDTH / 2, PLAYER_HEIGHT, delta, vel, STEP_HEIGHT)
		if full.stepped != wok || (wok && full.position != wp) {mismatches += 1}
	}
	testing.expect_value(t, mismatches, 0)
	testing.expectf(
		t,
		stepped > 50,
		"only %d of the cases stepped up: the test is not testing",
		stepped,
	)
}

@(test)
test_step_up_heights :: proc(t: ^testing.T) {
	reg := states_registry(t)
	if reg == nil {return}
	climb :: proc(q: Block_Query, step: f64) -> bool {
		pos := [3]f64{0.5, 1, 0.5}
		delta := [3]f64{0.4, -0.05, 0}
		c := collide_move(q, pos, 0.3, 1.8, delta, {1, 0, 0}, step)
		return c.stepped && c.position.x > 0.5 + 0.2
	}
	slab, _ := state_parse(reg, "testpack:planks_slab[type=bottom]")
	for kind, name in ([?]string{"slab", "slab and block", "block"}) {
		f := Field {
			floor = 1,
		}
		defer delete(f.blocks)
		switch name {
		case 0:
			f.blocks[{1, 1, 0}] = slab
		case 1:
			f.blocks[{1, 1, 0}] = slab
			f.blocks[{2, 1, 0}] = .Stone
			f.blocks[{2, 2, 0}] = .Stone
		case 2:
			f.blocks[{1, 1, 0}] = .Stone
		}
		q := field_query(&f, reg)
		got, none := climb(q, 0.6), climb(q, 0)
		testing.expectf(t, !none, "%s: climbed with step 0", kind)
		if name == 2 {
			testing.expect(t, !got, "a full block was climbed with step 0.6")
		} else if name == 0 {
			testing.expect(t, got, "a slab (0.5) was not climbed with step 0.6")
		}
	}
	// A stair: two half-blocks one behind the other, 0.5 apart in height.
	f := Field {
		floor = 1,
	}
	defer delete(f.blocks)
	f.blocks[{1, 1, 0}] = slab
	q := field_query(&f, reg)
	testing.expect(t, climb(q, 0.6))
	f.blocks[{1, 1, 0}] = .Stone
	testing.expect(t, !climb(q, 0.6))
}

@(test)
test_cast_box :: proc(t: ^testing.T) {
	reg := states_registry(t)
	if reg == nil {return}
	f: Field
	defer delete(f.blocks)
	// A one-block wall at x = 5..6; a 0.3 box at 32 blocks a second (one
	// tick: 1.0667 blocks) starting 0.9 before it.
	f.blocks[{5, 5, 0}] = .Stone
	q := field_query(&f, reg)
	lo := [3]f64{4.6 - 0.15, 5.2, -0.15}
	hi := lo + {0.3, 0.3, 0.3}
	delta := [3]f64{32.0 / 30, 0, 0}
	fraction, axis, hit := cast_box(q, lo, hi, delta)
	want := (5 - hi.x) / delta.x
	testing.expect(t, hit && axis == 0)
	testing.expectf(t, abs(fraction - want) < 1e-9, "fraction %v, want %v", fraction, want)
	// Too thin for the end position to show it: start and end are both clear
	// of the one-block wall, the cast still hits.
	lo2 := [3]f64{3.9, 5.2, -0.15}
	_, _, hit2 := cast_box(q, lo2, lo2 + {0.3, 0.3, 0.3}, {2.6, 0, 0})
	testing.expect(t, hit2, "a box that ends beyond the wall passed through it")
	// A box starting inside a cell box is not stopped by it.
	inside := [3]f64{5.2, 5.2, 0.2}
	_, _, hit3 := cast_box(q, inside, inside + {0.3, 0.3, 0.3}, {0.1, 0, 0})
	testing.expect(t, !hit3, "a box already inside was stopped")
	// Nothing in the way: the whole move.
	fr, _, hit4 := cast_box(q, {0, 20, 0}, {0.3, 20.3, 0.3}, {1, 0, 0})
	testing.expect(t, !hit4 && fr == 1)

	// Random casts against a brute force: the box stepped in 1/1000 of the
	// delta, the first overlapping step.
	rf: Field
	defer delete(rf.blocks)
	rng := base.rng_make(52)
	random_field(&rf, reg, &rng)
	rq := field_query(&rf, reg)
	bad := 0
	for _ in 0 ..< 10_000 {
		pos, half, height := random_box(&rng)
		d := random_delta(&rng) * 3
		blo := pos - {half, 0, half}
		bhi := pos + {half, height, half}
		if box_blocked(rq, pos, half * 2, height) {continue} 	// starts overlapping: ignored
		got, _, ghit := cast_box(rq, blo, bhi, d)
		brute := 1.0
		whit := false
		for i in 0 ..= 1000 {
			s := f64(i) / 1000
			if box_blocked(rq, pos + d * s, half * 2, height) {
				brute, whit = f64(i) / 1000, true
				break
			}
		}
		// The brute force sees an overlap up to 1/1000 after the true impact,
		// and misses a sliver (a corner grazed) between its steps: then the box
		// must be overlapping just after the cast's impact and clear before it.
		agree := ghit == whit && (!ghit || (brute - 1.0 / 1000 <= got && got <= brute))
		sliver :=
			ghit &&
			whit &&
			got < brute &&
			box_blocked(rq, pos + d * min(got + 1e-5, 1), half * 2, height) &&
			!box_blocked(rq, pos + d * max(got - 1e-5, 0), half * 2, height)
		if !agree && !sliver {bad += 1}
	}
	testing.expect_value(t, bad, 0)
}

@(private = "file")
Floating :: struct {
	boxes: []World_Box,
}

@(private = "file")
floating_boxes :: proc(data: rawptr, lo, hi: [3]f64, out: ^[dynamic]World_Box) {
	for b in (^Floating)(data).boxes {append(out, b)}
}

@(test)
test_box_source :: proc(t: ^testing.T) {
	reg := states_registry(t)
	if reg == nil {return}
	f := Field {
		floor = 1,
	}
	defer delete(f.blocks)
	q := field_query(&f, reg)
	fl := Floating {
		boxes = {{lo = {0, 4, 0}, hi = {2, 5, 2}}},
	}
	q.extra = {&fl, floating_boxes}
	// A falling body lands on it.
	c := collide_move(q, {1, 6, 1}, 0.4, 0.9, {0, -2, 0}, {0, -10, 0}, 0)
	testing.expect(t, c.on_ground && c.position.y == 5 && c.velocity.y == 0)
	// A player walking at it from the side stops at its face.
	c = collide_move(q, {-1, 4, 1}, 0.3, 1.8, {1.5, 0, 0}, {5, 0, 0}, 0)
	testing.expect(t, c.hit.x && abs(c.position.x - (-0.3)) < 1e-9)
	// A cast hits it.
	fraction, axis, hit := cast_box(q, {-1, 4.2, 0.5}, {-0.7, 4.5, 0.8}, {2, 0, 0})
	testing.expect(t, hit && axis == 0 && abs(fraction - 0.35) < 1e-9)
	// And it is a box like a cell: one beside the player blocks the standing box.
	testing.expect(t, box_blocked(q, {1, 4, 1}, 0.6, 1.8))
	testing.expect(t, !box_blocked(q, {1, 5, 1}, 0.6, 1.8))
}
