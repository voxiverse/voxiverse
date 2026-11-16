package arena_server

import "core:log"

import "common:base"
import "common:game"
import "games:arena"
import "server:core"
import "server:play"

// The courtyard: built for each match from its seed, so a match begins whole whatever
// the last one's rockets carved. Every block goes through the edit journal under a
// cause of the game's (core.game_act).

// COURTYARD: the walled ground the matches are fought in: SIZE square, HEIGHT from the
// floor, bedrock walls to WALL_TOP, stone under the floor (a rocket through it finds
// stone, not the open flat world).
COURTYARD :: play.Arena {
	size     = {arena.SIZE, arena.HEIGHT, arena.SIZE},
	wall_top = arena.WALL_TOP,
	depth    = 3,
}

// Theme: the materials of a courtyard.
Theme :: struct {
	floor, inlay, keep, tower, cover, bridge, pillar: game.Block,
}

THEMES :: [?]Theme {
	{.Stone, .Stone_Bricks, .Stone_Bricks, .Stone_Bricks, .Cobblestone, .Planks, .Log},
	{.Sandstone, .Clay, .Sandstone, .Sandstone, .Clay, .Planks, .Log},
	{.Cobblestone, .Gravel, .Stone_Bricks, .Cobblestone, .Stone, .Glass, .Spruce_Log},
	{.Clay, .Sandstone, .Planks, .Stone_Bricks, .Planks, .Planks, .Log},
}

// build: the courtyard for the match's seed, walls and all; false while its chunks are
// not all loaded, unless force (the wait is over: what is there is built, and said).
build :: proc(s: ^core.Server, force: bool) -> bool {
	a := state(s)
	t := courtyard(a.seed, &a.spawns)
	built, loaded := play.arena_build(s, s.home, COURTYARD, &t, force)
	if !built {return false}
	log.infof("arena courtyard built match=%d seed=%d all_loaded=%v", a.match, a.seed, loaded)
	a.built = true
	return true
}

// courtyard: the blocks of the inside for a seed, SIZE x HEIGHT x SIZE (temp
// allocator), and where its spawn points are. A floor with an inlaid ring; a low keep
// in the middle, stepped on every side; four towers, each with a stair, joined in
// pairs by bridges; posts to hook onto; low walls for cover; the spawn points along
// the walls, kept clear.
courtyard :: proc(seed: u32, spawns: ^[arena.SPAWNS][3]f64) -> game.Template {
	S :: arena.SIZE
	t := game.template_make({S, arena.HEIGHT, S}, context.temp_allocator)
	box :: game.template_fill
	r := base.rng_make(u64(seed) ~ 0xa7e4a)
	roll :: proc(r: ^base.Rng, lo, hi: i32) -> i32 {
		return lo + i32(base.rng_int_max(r, int(hi - lo + 1)))
	}
	themes := THEMES
	th := themes[base.rng_int_max(&r, len(themes))]

	// The floor, and its ring.
	box(&t, {0, 0, 0}, {S - 1, 0, S - 1}, th.floor)
	ring := roll(&r, 7, 11)
	box(&t, {ring, 0, ring}, {S - 1 - ring, 0, S - 1 - ring}, th.inlay)
	box(&t, {ring + 1, 0, ring + 1}, {S - 2 - ring, 0, S - 2 - ring}, th.floor)

	// The keep: three steps up to a square top at y 3.
	half := roll(&r, 2, 4)
	c := i32(S / 2)
	for step in i32(0) ..< 3 {
		k := half + 2 - step
		box(&t, {c - k, 1, c - k}, {c + k - 1, 1 + step, c + k - 1}, th.keep)
	}

	// The towers, one in each quarter, as tall as each other, a stair up the side
	// that faces the middle of the wall; a bridge joins each pair across x.
	tall := roll(&r, 5, 8)
	width := roll(&r, 3, 4)
	at := tall + roll(&r, 1, 2) // (room for the whole stair between it and the wall)
	corners := [4][2]i32 {
		{at, at},
		{S - at - width, at},
		{at, S - at - width},
		{S - at - width, S - at - width},
	}
	for q, i in corners {
		box(&t, {q.x, 1, q.y}, {q.x + width - 1, tall, q.y + width - 1}, th.tower)
		box(&t, {q.x, tall + 1, q.y}, {q.x, tall + 1, q.y}, .Lamp)
		box(
			&t,
			{q.x + width - 1, tall + 1, q.y + width - 1},
			{q.x + width - 1, tall + 1, q.y + width - 1},
			.Lamp,
		)
		// The stair: toward the near wall in z, a step a block.
		dir := i32(-1) if i < 2 else 1
		face := q.y - 1 if dir < 0 else q.y + width
		for k in i32(1) ..= tall {
			z := face + dir * (tall - k)
			box(&t, {q.x + 1, 1, z}, {q.x + width - 2 if width > 3 else q.x + 1, k, z}, th.tower)
		}
	}
	for pair in ([2][2]int{{0, 1}, {2, 3}}) {
		a, b := corners[pair[0]], corners[pair[1]]
		mid := a.y + width / 2
		box(&t, {a.x + width, tall, mid - 1}, {b.x - 1, tall, mid}, th.bridge)
		// A gap in the middle of the bridge: a jump, or the hook.
		box(&t, {c - 1, tall, mid - 1}, {c, tall, mid}, .Air)
	}

	// Posts to hook onto, and low walls to hide behind.
	for _ in 0 ..< roll(&r, 4, 6) {
		x, z := roll(&r, 3, S - 4), roll(&r, 3, S - 4)
		box(&t, {x, 1, z}, {x, roll(&r, 5, 12), z}, th.pillar)
	}
	for _ in 0 ..< roll(&r, 10, 14) {
		long := roll(&r, 3, 6)
		x, z := roll(&r, 2, S - 3 - long), roll(&r, 2, S - 3 - long)
		if base.rng_int_max(&r, 2) == 0 {
			box(&t, {x, 1, z}, {x + long - 1, 2, z}, th.cover)
		} else {
			box(&t, {x, 1, z}, {x, 2, z + long - 1}, th.cover)
		}
	}

	// The spawn points: the corners and the middles of the walls, two in from them,
	// cleared three wide and high, each looking at the keep.
	places := [arena.SPAWNS][2]i32 {
		{2, 2},
		{S / 2, 2},
		{S - 3, 2},
		{S - 3, S / 2},
		{S - 3, S - 3},
		{S / 2, S - 3},
		{2, S - 3},
		{2, S / 2},
	}
	for p, i in places {
		box(&t, {p.x - 1, 1, p.y - 1}, {p.x + 1, 3, p.y + 1}, .Air)
		spawns[i] = {f64(p.x) + 0.5, 1, f64(p.y) + 0.5}
	}
	return t
}
