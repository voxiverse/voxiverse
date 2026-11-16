package horde_server

import "core:log"

import "common:base"
import "common:game"
import "games:horde"
import "server:core"
import "server:play"

// The yard: built for each run from its seed, so a run begins whole whatever the last
// one's blasts carved. Every block goes through the edit journal as the game's.

// YARD: the walled ground the runs are fought in.
YARD :: play.Arena {
	size     = {horde.SIZE, horde.HEIGHT, horde.SIZE},
	wall_top = horde.WALL_TOP,
	depth    = 2,
}

// build: the yard for the run's seed, walls and all; false while its chunks are not all
// loaded, unless force (the wait is over: what is there is built, and said).
build :: proc(s: ^core.Server, force: bool) -> bool {
	d := state(s)
	t := yard_template(d.seed, d.shop, d.lair)
	built, loaded := play.arena_build(s, s.home, YARD, &t, force)
	if !built {return false}
	log.infof("horde yard built run=%d seed=%d all_loaded=%v", d.run, d.seed, loaded)
	d.built = true
	return true
}

// yard_template: the yard's blocks for a seed (temp memory). A floor of packed earth
// with paths of gravel from each lair to the middle; the shop's counter in the middle,
// a lamp post at each of its corners; cover scattered from the seed: crates to duck
// behind, pillars, low walls; the lairs' gates in the corners. The middle (where the
// survivors stand) and the paths stay clear.
yard_template :: proc(seed: u32, shop, lair: game.Block) -> game.Template {
	S :: horde.SIZE
	M :: horde.MID
	t := game.template_make({S, horde.HEIGHT, S}, context.temp_allocator)
	box :: game.template_fill
	r := base.rng_make(u64(seed) ~ 0x40de)
	roll :: proc(r: ^base.Rng, lo, hi: i32) -> i32 {
		return lo + i32(base.rng_int_max(r, int(hi - lo + 1)))
	}
	box(&t, {0, 0, 0}, {S - 1, 0, S - 1}, .Dirt)
	for x in i32(0) ..< S {
		for z in i32(0) ..< S {
			if (x * 7 + z * 13 + i32(seed % 5)) % 9 == 0 {box(&t, {x, 0, z}, {x, 0, z}, .Grass)}
		}
	}
	// The paths: a diagonal of gravel from each lair to the middle.
	for l in horde.LAIRS {
		for k in i32(0) ..= 16 {
			x := l.x + (M - l.x) * k / 16
			z := l.y + (M - l.y) * k / 16
			box(&t, {x - 1, 0, z - 1}, {x + 1, 0, z + 1}, .Gravel)
		}
	}
	clear :: proc(x, z: i32) -> bool {
		near_middle := abs(x - M) <= 6 && abs(z - M) <= 6
		on_path := false
		for l in horde.LAIRS {
			// (the distance from the path's line, in a box test: near either diagonal)
			dx, dz := x - l.x, z - l.y
			lx, lz := M - l.x, M - l.y
			cross := abs(dx * lz - dz * lx)
			on_path ||= cross <= 3 * max(abs(lx), abs(lz))
		}
		return near_middle || on_path
	}
	// Cover: crates, pillars, low walls.
	for _ in 0 ..< roll(&r, 10, 14) {
		x, z := roll(&r, 3, S - 5), roll(&r, 3, S - 5)
		if clear(x, z) || clear(x + 1, z + 1) {continue}
		box(&t, {x, 1, z}, {x + 1, roll(&r, 1, 2), z + 1}, .Planks)
	}
	for _ in 0 ..< roll(&r, 4, 6) {
		x, z := roll(&r, 3, S - 4), roll(&r, 3, S - 4)
		if clear(x, z) {continue}
		box(&t, {x, 1, z}, {x, roll(&r, 4, 7), z}, .Stone_Bricks)
	}
	for _ in 0 ..< roll(&r, 3, 5) {
		long := roll(&r, 3, 5)
		x, z := roll(&r, 3, S - 4 - long), roll(&r, 3, S - 4 - long)
		if base.rng_int_max(&r, 2) == 0 {
			if clear(x, z) || clear(x + long, z) {continue}
			box(&t, {x, 1, z}, {x + long - 1, 1, z}, .Cobblestone)
		} else {
			if clear(x, z) || clear(x, z + long) {continue}
			box(&t, {x, 1, z}, {x, 1, z + long - 1}, .Cobblestone)
		}
	}
	// The shop's counter, lit, with a lamp post at each corner a block away.
	sp := horde.SHOP
	box(&t, {sp.x, 1, sp.z}, {sp.x + 1, 1, sp.z + 1}, shop)
	for c in ([4][2]i32{{-2, -2}, {3, -2}, {-2, 3}, {3, 3}}) {
		box(&t, {sp.x + c.x, 1, sp.z + c.y}, {sp.x + c.x, 3, sp.z + c.y}, .Log)
		box(&t, {sp.x + c.x, 4, sp.z + c.y}, {sp.x + c.x, 4, sp.z + c.y}, .Lamp)
	}
	// The lairs: a gate of the lair block in each corner, open toward the middle.
	for l in horde.LAIRS {
		ox := i32(-1) if l.x < M else 1
		oz := i32(-1) if l.y < M else 1
		box(&t, {l.x + ox, 1, l.y + oz}, {l.x + ox, 3, l.y + oz}, lair)
		box(&t, {l.x, 1, l.y + oz}, {l.x, 3, l.y + oz}, lair)
		box(&t, {l.x + ox, 1, l.y}, {l.x + ox, 3, l.y}, lair)
		box(&t, {l.x - 1, 0, l.y - 1}, {l.x + 1, 0, l.y + 1}, .Cobblestone)
	}
	return t
}

// stand_point: where survivor `seat` stands at the start of a wave: round the counter,
// facing out.
stand_point :: proc(seat: int) -> (at: [3]f64, look: [2]f32) {
	places := [8][2]f64{{-3, 0}, {4, 1}, {1, -3}, {0, 4}, {-3, 3}, {4, -2}, {-2, -3}, {3, 4}}
	p := places[seat % len(places)]
	at = {f64(horde.MID) + p.x, 1, f64(horde.MID) + p.y}
	away := at + (at - {horde.MID, 1, horde.MID})
	return at, play.look_at(at, {away.x, 1.6, away.z})
}
