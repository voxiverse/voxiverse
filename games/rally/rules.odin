package rally

import "core:fmt"

import "common:base"
import "common:game"

// Rally: a race through a course of platforms in the sky, from the start pad through its
// checkpoints in order to the finish. Gaps to jump, steps up, hazard strips that send you
// back, and wide gaps that want the hook or a rocket's push. Falling off, or touching a
// hazard, puts you back at your last checkpoint. Every race starts on a countdown; each
// racer's time and splits are kept, and the personal bests and the course record stay with
// the universe. The course is the universe's: the same every race, so times compare.
//
// This is its shared package: the course's plan (both sides lay it out from its seed:
// the server builds it, the client marks its checkpoints), the rules and what the server
// tells the players (records.odin). The server part (games/rally/server) builds the
// course and times the races; the client part (games/rally/client) shows them.

INFO :: game.Game_Info {
	id          = "rally",
	name        = "Rally",
	description = "Race the sky course through its checkpoints; beat the record.",
}

// The course: platforms over the flat world, from x 0 eastward, around z 0, their tops at
// TOP and up.
TOP :: 24
FALL :: TOP - 8 // a racer below this has fallen: back to its last checkpoint
LENGTH :: 256 // blocks the course may run east
WIDTH :: 24 // ... and wide, z -WIDTH/2 ..< WIDTH/2
RISE :: 12 // ... and the layers over TOP it may climb

MAX_PLATFORMS :: 40
MAX_HAZARDS :: 16
CHECKPOINTS :: 6 // the gates after the start; the last is the finish

// Seconds.
COUNTDOWN :: 3.0 // a race's count (alone)
COUNTDOWN_MANY :: 5.0 // ... with others to race
RACE_MAX :: 240.0 // the race ends anyway
RESULTS :: 6.0 // the times shown, before the next race
BUILD_WAIT :: 6.0

Phase :: enum u8 {
	Waiting, // nobody here
	Countdown, // the racers on the start, counted down
	Racing,
	Results,
}

// Platform: a box of the course (its top layer is what is stood on).
Platform :: struct {
	lo, hi: [3]i32,
	kind:   Platform_Kind,
}

Platform_Kind :: enum u8 {
	Plain,
	Start,
	Gate, // a checkpoint's platform: its gate over it
	Finish,
}

// Course: the plan of a course, from its seed.
Course :: struct {
	platforms:   [MAX_PLATFORMS]Platform,
	count:       int,
	hazards:     [MAX_HAZARDS]Platform, // strips across platforms
	hazard_n:    int,
	checkpoints: [CHECKPOINTS + 1][3]i32, // 0: the start; then each gate's middle (its floor's block over the platform)
	posts:       [4][3]i32, // the hook posts over the widest gaps (y: the beam's layer); x 0: none
}

// course_plan: the course of a seed. Platforms run east, each 3 to 5 blocks long, gaps of
// 2 to 4 blocks between them (a running jump crosses 4), sometimes a step up or down a
// layer, sometimes a sidestep; every few a gate, and two gaps 6 to 7 blocks wide with a
// post over them for the hook (or a rocket's push, or the boots' double jump). Some
// platforms carry a hazard strip across their middle, to be jumped.
course_plan :: proc(seed: u32) -> (c: Course) {
	r := base.rng_make(u64(seed) ~ 0x7a11e)
	roll :: proc(r: ^base.Rng, lo, hi: i32) -> i32 {return base.rng_roll(r, lo, hi)}
	add :: proc(c: ^Course, lo, hi: [3]i32, kind: Platform_Kind) {
		c.platforms[c.count] = {lo, hi, kind}
		c.count += 1
	}
	add(&c, {0, TOP - 1, -3}, {6, TOP, 3}, .Start)
	c.checkpoints[0] = {3, TOP + 1, 0}
	x, y, z := i32(7), i32(TOP), i32(0)
	gates := 0
	posts := 0
	per_gate := 4
	for step := 1; gates < CHECKPOINTS; step += 1 {
		last := step % per_gate == 0 && gates == CHECKPOINTS - 1
		gate := step % per_gate == 0
		wide := !gate && posts < len(c.posts) && step % per_gate == 2 && (step / per_gate) % 2 == 1
		gap := roll(&r, 2, 4)
		if wide {gap = roll(&r, 6, 7)}
		dy := i32(0)
		switch base.rng_int_max(&r, 4) {
		case 0:
			dy = 1
		case 1:
			dy = -1
		}
		y = clamp(y + dy, TOP, TOP + RISE - 4)
		dz := roll(&r, -2, 2)
		z = clamp(z + dz, -WIDTH / 2 + 4, WIDTH / 2 - 5)
		x0 := x + gap
		long := roll(&r, 3, 5)
		half := roll(&r, 1, 2)
		if gate {long, half = 5, 2}
		if wide {
			post := [3]i32{x + gap / 2, y + 5, z}
			c.posts[posts] = post
			posts += 1
		}
		kind := Platform_Kind.Plain
		if gate {kind = .Finish if last else .Gate}
		add(&c, {x0, y - 1, z - half}, {x0 + long - 1, y, z + half}, kind)
		if gate {
			gates += 1
			c.checkpoints[gates] = {x0 + long / 2, y + 1, z}
		} else if long == 5 && base.rng_int_max(&r, 3) == 0 && c.hazard_n < MAX_HAZARDS {
			c.hazards[c.hazard_n] = {{x0 + 2, y, z - half}, {x0 + 2, y, z + half}, .Plain}
			c.hazard_n += 1
		}
		x = x0 + long
		assert(c.count < MAX_PLATFORMS && x < LENGTH)
	}
	return
}

// at_checkpoint: p (a racer's feet) is in checkpoint k's gate (k 0: on the start).
at_checkpoint :: proc(c: ^Course, k: int, p: [3]f64) -> bool {
	g := c.checkpoints[k]
	return(
		p.x >= f64(g.x) - 1.5 &&
		p.x <= f64(g.x) + 2.5 &&
		abs(p.z - (f64(g.z) + 0.5)) <= 3 &&
		p.y >= f64(g.y) - 0.5 &&
		p.y < f64(g.y) + 3 \
	)
}

// clock: ticks as a race's clock reads them, "1:05.3".
clock :: proc(ticks: u32) -> string {
	tenths := ticks * 10 / game.TICK_RATE
	return fmt.tprintf("%d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
}

// delta: a split against the best's, "-1.3" or "+0.4" (tenths of a second).
delta :: proc(ticks: i32) -> string {
	tenths := ticks * 10 / game.TICK_RATE
	sign := "+" if tenths >= 0 else "-"
	a := abs(tenths)
	return fmt.tprintf("%s%d.%d", sign, a / 10, a % 10)
}
