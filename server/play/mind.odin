package play

import "core:math"

import "common:base"
import "common:game"
import "server:core"

// Minds: the small behaviours an open world's creatures are made of, each one call a
// game's think hook makes for one creature (its kind's brain is "game") on the Mind it
// keeps in its record on it (core.entity_data). A game composes them for each kind: a
// grazer wanders with its herd and flees, a guard warns before it fights, a sentry sleeps
// at its post until someone comes near, a bird flies in the air and lands, a fish swims and
// stays in the water. Nothing here names a creature; what a kind is (its speed, its
// attack, its body) stays its pack's.
//
// Walkers walk (core.entity_go, entity_keep: their own path, the body's physics). Fliers
// and swimmers glide (core.entity_glide: straight legs, no physics) between points the
// mind checks are all of their medium first (medium_clear), so a bird never passes
// through a hill and a fish never leaves the water.

// Mind_State: what a creature is doing. The game's own resting behaviour runs in Idle,
// Wander, Rest, Dormant and Hidden; the others are the procs' below.
Mind_State :: enum u8 {
	Idle, // standing, looking about
	Wander, // walking, flying or swimming somewhere near home
	Rest, // a flier on the ground; a grazer with its head down
	Watch, // a player is near: it faces it
	Flee, // running from what frightened or hurt it
	Warn, // someone is too near its ground: it shows it (temper_tick) before it fights
	Dormant, // a machine asleep at its post until someone comes near
	Hidden, // buried, waiting for prey to come over it
	Wake, // rousing from Dormant or Hidden (temper_tick): a moment to see it coming
	Fight, // going for its prey (fight_fair)
	Return, // going back to its home after a fight
	Follow, // keeping a player in sight from a distance (follow_at)
	Leave, // going away for good (leave)
}

// Mind: a creature's state of mind, kept by its game in its record on it. Zero is a mind
// that has not settled yet (mind_settle).
Mind :: struct {
	state:   Mind_State,
	settled: bool, // home is set
	wind:    i16, // ticks left of the wind-up before its blow or shot (fight_fair)
	ready:   i16, // ticks before it may wind up again
	timer:   i32, // ticks left in its state
	home:    [3]i32, // the block it keeps to: where it came, its post, its roost
}

FAR_THINK :: 8 // a creature with no player near thinks every this many ticks (mind_due)

// mind_settle: the creature makes where it stands its home, once.
mind_settle :: proc(w: ^core.World, h: game.Entity_Handle, m: ^Mind) {
	if m.settled {return}
	m.home, m.settled = block_of(core.entity_pos(w, h)), true
}

// mind_set: the creature does something else, for ticks.
mind_set :: proc(m: ^Mind, state: Mind_State, ticks: i32) {
	m.state, m.timer = state, ticks
}

// mind_due: whether a creature thinks this tick: always with a player near, else once in
// FAR_THINK ticks (staggered by its id), so the creatures nobody is near cost an eighth
// (their steps go on between: what they were sent to do, they do). Between its thoughts
// its clocks run on (its timer, its cooldown), so a state lasts as long either way.
mind_due :: proc(
	s: ^core.Server,
	w: ^core.World,
	h: game.Entity_Handle,
	m: ^Mind,
	near: bool,
) -> bool {
	if near || (s.tick + u64(core.entity_id(w, h))) % FAR_THINK == 0 {return true}
	m.timer -= 1
	if m.ready > 0 {m.ready -= 1}
	return false
}

// player_seen: c is playing, alive and has a body (not a spectator): a creature sees it,
// in any mode (a grazer flees a creative player too; only prey_fair ones are hunted).
player_seen :: proc(s: ^core.Server, c: ^core.Client) -> bool {
	if c.state != .Playing || c.dead {return false}
	abilities := game.derive_abilities(s.registry, c.mode, &c.inventory)
	return .Bodiless not_in abilities
}

// distance_to: blocks between two points, horizontally.
distance_to :: proc(a, b: [3]f64) -> f64 {
	d := a - b
	return math.sqrt(d.x * d.x + d.z * d.z)
}

// home_point: the bottom centre of a mind's home block.
home_point :: proc(m: ^Mind) -> [3]f64 {return place_point(m.home)}

// face: the creature turns a step (rate, 0..1) of the way to face p, and lifts its head
// at it (its pitch: a part with the `pitch` swing) from eye blocks over its feet.
face :: proc(w: ^core.World, h: game.Entity_Handle, p: [3]f64, eye: f64, rate: f32 = 0.2) {
	pos := core.entity_pos(w, h)
	to := p - (pos + {0, eye, 0})
	flat := math.sqrt(to.x * to.x + to.z * to.z)
	yaw, pitch := core.entity_yaw(w, h), core.entity_pitch(w, h)
	if flat > 1e-6 {yaw = turn_step(yaw, f32(math.atan2(-to.x, -to.z)), rate)}
	want := clamp(f32(math.atan2(to.y, max(flat, 1e-6))), -1, 1)
	core.entity_set_look(w, h, yaw, pitch + (want - pitch) * rate)
}

// head_to: the creature's head goes a step of the way to a pitch (down, -1.2: grazing;
// level, 0), its yaw as it is.
head_to :: proc(w: ^core.World, h: game.Entity_Handle, pitch: f32, rate: f32 = 0.2) {
	p := core.entity_pitch(w, h)
	core.entity_set_look(w, h, core.entity_yaw(w, h), p + (pitch - p) * rate)
}

// wander: the walker sets out for a random point within range blocks of home (each way),
// at its walking pace; the point.
wander :: proc(
	w: ^core.World,
	h: game.Entity_Handle,
	r: ^base.Rng,
	home: [3]f64,
	range: f64,
) -> [3]f64 {
	to := home + {base.rng_f64_range(r, -range, range), 0, base.rng_f64_range(r, -range, range)}
	core.entity_set_speed(w, h, 0)
	core.entity_go(w, h, to)
	return to
}

// flee: the walker runs from `from`, distance blocks straight away (horizontally, give or
// take a little), at speed (blocks a second).
flee :: proc(
	w: ^core.World,
	h: game.Entity_Handle,
	r: ^base.Rng,
	from: [3]f64,
	distance: f64,
	speed: f32,
) {
	pos := core.entity_pos(w, h)
	away := away_from(r, pos, from)
	to := pos + away * distance + {base.rng_f64_range(r, -2, 2), 0, base.rng_f64_range(r, -2, 2)}
	core.entity_set_speed(w, h, speed)
	core.entity_go(w, h, to)
}

// herd_center: where the others of the creature's kind within radius stand on average,
// and how many there are (0: none, and its own place).
herd_center :: proc(
	w: ^core.World,
	h: game.Entity_Handle,
	radius: f64,
) -> (
	center: [3]f64,
	n: int,
) {
	pos := core.entity_pos(w, h)
	for o in core.entities_of(w, core.entity_kind(w, h), pos, radius) {
		if o == h {continue}
		center += core.entity_pos(w, o)
		n += 1
	}
	if n == 0 {return pos, 0}
	return center / f64(n), n
}

// herd_wander: a herd animal's walk: within range of its herd's middle when others of
// its kind are within herd blocks (and its home moves with the herd), else as wander from
// its home; the point.
herd_wander :: proc(
	w: ^core.World,
	h: game.Entity_Handle,
	m: ^Mind,
	r: ^base.Rng,
	range, herd: f64,
) -> [3]f64 {
	center, n := herd_center(w, h, herd)
	if n > 0 {m.home = block_of(center)}
	return wander(w, h, r, home_point(m) if n == 0 else center, range)
}

// herd_mates: the others of the creature's kind within radius blocks, nearest first (the
// temp allocator): whom a fright spreads to (scare), whom a pack hunts with.
herd_mates :: proc(w: ^core.World, h: game.Entity_Handle, radius: f64) -> []game.Entity_Handle {
	near := core.entities_of(w, core.entity_kind(w, h), core.entity_pos(w, h), radius)
	out := make([dynamic]game.Entity_Handle, 0, len(near), context.temp_allocator)
	for o in near {if o != h {append(&out, o)}}
	return out[:]
}

// scare: the walker takes fright at `from` and flees it (flee) for ticks, unless it
// flees already: what a herd mate's fright does to the rest (herd_mates).
scare :: proc(
	w: ^core.World,
	h: game.Entity_Handle,
	m: ^Mind,
	r: ^base.Rng,
	from: [3]f64,
	distance: f64,
	speed: f32,
	ticks: i32,
) {
	if m.state == .Flee {return}
	mind_set(m, .Flee, ticks)
	flee(w, h, r, from, distance, speed)
}

// Temper: how a creature that fights is roused and calmed, the game's for each kind.
Temper :: struct {
	notice:   f64, // blocks from it (from home, when it keeps a post) within which a fair player rouses it
	near:     f64, // blocks: a guard that warned attacks one this near (0: it fights once roused)
	warn:     i32, // ticks it warns, or wakes, before it fights
	leash:    f64, // blocks from home past which it gives up the fight and goes back
	patience: i32, // ticks it fights on with its prey beyond notice before it gives up
	wind:     i16, // ticks it winds up each blow or shot (fight_fair)
	post:     bool, // it notices from its home, not from where it stands (a sentry at its post)
	may:      proc(s: ^core.Server, c: ^core.Client) -> bool, // whom it goes for (nil: prey_fair)
}

// temper_tick: one tick of a creature that fights when roused, after the game's own
// resting behaviour; the prey it fights (nil: none). Resting (any state but Warn, Wake,
// Fight and Return), a fair player within notice rouses it: a guard (near > 0) warns,
// facing it, and fights it once the warning ran out if it is still within near (if it
// backs off past notice, the guard calms down); a sleeper (Dormant, Hidden) wakes and
// then fights; any other fights after its warn ticks. Fighting, it goes for the fair
// player nearest it within notice of it (fight_fair), until none has been for patience ticks
// or it is past its leash, and then it returns home and rests (calm: Idle, or Dormant,
// Hidden for a sleeper). True `roused` while the temper has it: the game's own behaviour
// waits.
temper_tick :: proc(
	s: ^core.Server,
	w: ^core.World,
	h: game.Entity_Handle,
	m: ^Mind,
	t: Temper,
	calm: Mind_State,
) -> (
	prey: ^core.Client,
	roused: bool,
) {
	pos := core.entity_pos(w, h)
	from := home_point(m) if t.post else pos
	switch m.state {
	case .Warn:
		prey = prey_within(s, w, pos, t.notice, t.may)
		if prey == nil {
			mind_set(m, .Idle, 20)
			return nil, false
		}
		core.entity_stand(w, h)
		face(w, h, prey.player.position, 1, 0.4)
		m.timer -= 1
		if m.timer > 0 {return prey, true}
		if distance_to(pos, prey.player.position) <= t.near {
			mind_set(m, .Fight, t.patience)
		} else {
			m.timer = t.warn / 2
		}
		return prey, true
	case .Wake:
		core.entity_stand(w, h)
		prey = prey_within(s, w, from, t.notice * 2, t.may)
		if prey != nil {face(w, h, prey.player.position, 1, 0.3)}
		m.timer -= 1
		if m.timer <= 0 {mind_set(m, .Fight, t.patience)}
		return prey, true
	case .Fight:
		prey = prey_within(s, w, pos, t.notice, t.may)
		if prey != nil && distance_to(prey.player.position, home_point(m)) <= t.leash {
			m.timer = t.patience
			fight_fair(s, w, h, m, prey, t.wind)
			return prey, true
		}
		m.wind = 0
		m.timer -= 1
		if m.timer <= 0 || distance_to(pos, home_point(m)) > t.leash {
			mind_set(m, .Return, game.TICK_RATE * 30)
			core.entity_set_speed(w, h, 0)
			core.entity_go(w, h, home_point(m))
		} else {
			core.entity_stand(w, h)
		}
		return nil, true
	case .Return:
		m.timer -= 1
		if prey = prey_within(s, w, pos, t.notice, t.may); prey != nil {
			mind_set(m, .Fight, t.patience)
			return prey, true
		}
		if core.entity_arrived(w, h) || m.timer <= 0 {
			core.entity_stand(w, h)
			mind_set(m, calm, 0)
			return nil, false
		}
		return nil, true
	case .Idle, .Wander, .Rest, .Watch, .Flee, .Dormant, .Hidden, .Follow, .Leave:
		prey = prey_within(s, w, from, t.notice, t.may)
		if prey == nil {return nil, false}
		switch {
		case m.state == .Dormant || m.state == .Hidden:
			mind_set(m, .Wake, t.warn)
		case t.near > 0:
			mind_set(m, .Warn, t.warn)
		case:
			mind_set(m, .Wake, t.warn)
		}
		core.entity_stand(w, h)
		return prey, true
	}
	return nil, false
}

// provoke: the creature was hurt: a sleeper wakes (its warn ticks: it is seen waking),
// any other resting or warning creature fights at once, for patience ticks at least.
provoke :: proc(m: ^Mind, t: Temper) {
	switch m.state {
	case .Dormant, .Hidden:
		mind_set(m, .Wake, t.warn)
	case .Wake:
	case .Fight, .Return, .Idle, .Wander, .Rest, .Watch, .Flee, .Warn, .Follow, .Leave:
		mind_set(m, .Fight, max(t.patience, m.timer))
	}
}

// fight_fair: the creature goes for prey as its kind's attack says (hunt's band of distances,
// its reach, where a shooter shoots from), but winds up each blow or shot first: m.wind
// counts wind ticks down while it stands facing its prey (the game shows it: a raised
// arm, a drawn tail, a charging lens), and only then does it strike, if prey is still
// within its reach, or shoot, if it still sees it: a player who sees it coming steps out
// of reach or behind something. Then it waits its kind's cooldown.
fight_fair :: proc(
	s: ^core.Server,
	w: ^core.World,
	h: game.Entity_Handle,
	m: ^Mind,
	prey: ^core.Client,
	wind: i16,
) {
	info := game.kind_info(s.registry, core.entity_kind(w, h))
	a, fights := info.attack.?
	if !fights {return}
	feet := prey.player.position
	chest := feet + {0, 1.1, 0}
	distance := distance_to(core.entity_pos(w, h), feet)
	if m.ready > 0 {m.ready -= 1}
	if m.wind > 0 {
		core.entity_stand(w, h)
		face(w, h, chest, f64(info.box[1]) * 0.85, 0.5)
		m.wind -= 1
		if m.wind > 0 {return}
		if a.shot != 0 && distance >= f64(a.shoot[0]) {
			if core.entity_sees(w, h, chest) {core.entity_shoot(w, h, chest)}
		} else {
			core.entity_strike(w, h, prey)
		}
		m.ready = i16(min(a.cooldown * f32(game.TICK_RATE), 30000))
		return
	}
	core.entity_keep(w, h, feet, a.keep[0], a.keep[1])
	if m.ready > 0 {return}
	reach := distance - f64(info.box[0]) / 2 - game.PLAYER_WIDTH / 2 <= f64(a.reach)
	shoot :=
		a.shot != 0 &&
		distance >= f64(a.shoot[0]) &&
		distance <= f64(a.shoot[1]) &&
		core.entity_sees(w, h, chest)
	if !reach && !shoot {return}
	m.wind = max(wind, 1)
}

// FLY_TRIES: random points a flier or swimmer tries for a leg before it gives up for the tick.
FLY_TRIES :: 4

// medium_clear: a body width blocks wide and height high goes straight from `from` to
// `to` (its feet) through nothing but its medium: every block its box's corners and top
// pass through, a fifth of a block apart, is open (nothing a body collides with) and in
// water (water true: a swimmer's) or out of it (false: a flier's). A block not loaded is
// never clear.
medium_clear :: proc(
	s: ^core.Server,
	w: ^core.World,
	from, to: [3]f64,
	width, height: f64,
	water: bool,
) -> bool {
	d := to - from
	l := math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
	steps := max(int(l * 5), 1)
	half := width / 2 - 0.01
	corners := [4][2]f64{{-half, -half}, {half, -half}, {-half, half}, {half, half}}
	for i in 0 ..= steps {
		p := from + d * (f64(i) / f64(steps))
		for c in corners {
			for y := 0.0; y < height + 1; y += 1 {
				at := p + {c.x, min(y, height), c.y}
				if !medium_has(s, w, block_of(at), water) {return false}
			}
		}
	}
	return true
}

// medium_has: block p is open (loaded, nothing to collide with, not a gate's surface: a
// creature never flies or swims into a gate) and water, or not water.
medium_has :: proc(s: ^core.Server, w: ^core.World, p: game.Block_Pos, water: bool) -> bool {
	b, loaded := core.block_at(w, p)
	if !loaded || b == .Gate_Horizon || game.block_collides(&s.registry.blocks, b) {return false}
	_, wet := game.water_level(b)
	return wet == water
}

// glide_to: the creature glides straight to the block `to` is in (its feet at the block's
// bottom centre) if the way there is all its medium (medium_clear, its box: in water for
// a swimmer); false, and it stays, if not.
glide_to :: proc(
	s: ^core.Server,
	w: ^core.World,
	h: game.Entity_Handle,
	to: [3]f64,
	water: bool,
) -> bool {
	info := game.kind_info(s.registry, core.entity_kind(w, h))
	b := block_of(to)
	end := place_point(b)
	box := info.box
	if !medium_clear(s, w, core.entity_pos(w, h), end, f64(box[0]), f64(box[1]), water) {
		return false
	}
	return core.entity_glide(w, h, []game.Block_Pos{b})
}

// fly_wander: a flier sets out through the air for a random point within range blocks of
// home (each way, horizontally), low to high blocks over the ground there, at speed
// (blocks a second; 0: its walking pace); false when none of FLY_TRIES points is in the
// clear.
fly_wander :: proc(
	s: ^core.Server,
	w: ^core.World,
	h: game.Entity_Handle,
	r: ^base.Rng,
	home: [3]f64,
	range: f64,
	low, high: i32,
	speed: f32 = 0,
) -> bool {
	for _ in 0 ..< FLY_TRIES {
		x := i32(math.floor(home.x + base.rng_f64_range(r, -range, range)))
		z := i32(math.floor(home.z + base.rng_f64_range(r, -range, range)))
		ground, found := ground_at(s, w, x, i32(math.floor(home.y)), z, 16)
		if !found {continue}
		y := ground.y + i32(base.rng_int_range(r, int(low), int(high) + 1))
		core.entity_set_speed(w, h, speed)
		if glide_to(s, w, h, place_point({x, y, z}), false) {return true}
	}
	return false
}

// fly_circle: a flier's next leg round home: to a point radius blocks from home, step
// radians further round from where it is (a bird wheeling over its ground), low to high
// blocks over the ground there, at speed; false when the way is not clear.
fly_circle :: proc(
	s: ^core.Server,
	w: ^core.World,
	h: game.Entity_Handle,
	r: ^base.Rng,
	home: [3]f64,
	radius, step: f64,
	low, high: i32,
	speed: f32,
) -> bool {
	pos := core.entity_pos(w, h)
	a := math.atan2(pos.z - home.z, pos.x - home.x) + step
	x := i32(math.floor(home.x + base.cos(a) * radius))
	z := i32(math.floor(home.z + base.sin(a) * radius))
	ground, found := ground_at(s, w, x, i32(math.floor(home.y)), z, 16)
	if !found {return false}
	y := ground.y + i32(base.rng_int_range(r, int(low), int(high) + 1))
	core.entity_set_speed(w, h, speed)
	return glide_to(s, w, h, place_point({x, y, z}), false)
}

// fly_flee: a flier goes up and away from `from`, distance blocks off and low to high
// blocks over the ground, at speed; false when the way is blocked every time it tried.
fly_flee :: proc(
	s: ^core.Server,
	w: ^core.World,
	h: game.Entity_Handle,
	r: ^base.Rng,
	from: [3]f64,
	distance: f64,
	low, high: i32,
	speed: f32,
) -> bool {
	pos := core.entity_pos(w, h)
	for _ in 0 ..< FLY_TRIES {
		to := pos + away_from(r, pos, from) * distance
		ground, found := ground_at(
			s,
			w,
			i32(math.floor(to.x)),
			i32(math.floor(pos.y)),
			i32(math.floor(to.z)),
			16,
		)
		if !found {continue}
		y := ground.y + i32(base.rng_int_range(r, int(low), int(high) + 1))
		core.entity_set_speed(w, h, speed)
		if glide_to(s, w, h, {to.x, f64(y), to.z}, false) {return true}
	}
	return false
}

// land: a flier comes down onto ground within range blocks of home (where a walker one
// block wide stands, under the open sky); false when no try found a clear way.
land :: proc(
	s: ^core.Server,
	w: ^core.World,
	h: game.Entity_Handle,
	r: ^base.Rng,
	home: [3]f64,
	range: f64,
) -> bool {
	pos := core.entity_pos(w, h)
	for _ in 0 ..< FLY_TRIES {
		x := i32(math.floor(home.x + base.rng_f64_range(r, -range, range)))
		z := i32(math.floor(home.z + base.rng_f64_range(r, -range, range)))
		ground, found := ground_at(s, w, x, i32(math.floor(pos.y)), z, 24)
		if !found || !core.under_sky(w, ground) {continue}
		if glide_to(s, w, h, place_point(ground), false) {return true}
	}
	return false
}

// swim_wander: a swimmer sets out through the water for a random water block within range
// blocks of home (each way, and up to half of it up and down), at speed (0: its walking
// pace); false when none of FLY_TRIES points was in the water with a clear way.
swim_wander :: proc(
	s: ^core.Server,
	w: ^core.World,
	h: game.Entity_Handle,
	r: ^base.Rng,
	home: [3]f64,
	range: f64,
	speed: f32 = 0,
) -> bool {
	for _ in 0 ..< FLY_TRIES {
		to :=
			home +
			{
					base.rng_f64_range(r, -range, range),
					base.rng_f64_range(r, -range / 2, range / 2),
					base.rng_f64_range(r, -range, range),
				}
		core.entity_set_speed(w, h, speed)
		if glide_to(s, w, h, place_point(block_of(to)), true) {return true}
	}
	return false
}

// swim_flee: a swimmer darts from `from`, distance blocks away through the water, at
// speed; false when every way it tried leaves the water.
swim_flee :: proc(
	s: ^core.Server,
	w: ^core.World,
	h: game.Entity_Handle,
	r: ^base.Rng,
	from: [3]f64,
	distance: f64,
	speed: f32,
) -> bool {
	pos := core.entity_pos(w, h)
	for _ in 0 ..< FLY_TRIES {
		to := pos + away_from(r, pos, from) * distance + {0, base.rng_f64_range(r, -1, 1), 0}
		core.entity_set_speed(w, h, speed)
		if glide_to(s, w, h, place_point(block_of(to)), true) {return true}
	}
	return false
}

// follow_at: a flier keeps the player at between near and far blocks (horizontally),
// height blocks over the player's feet, facing it: when it is out of that band (or has
// arrived), it glides at speed (blocks a second) to the band's middle on the line between
// them; true while it holds the band.
follow_at :: proc(
	s: ^core.Server,
	w: ^core.World,
	h: game.Entity_Handle,
	c: ^core.Client,
	near, far, height: f64,
	speed: f32,
) -> bool {
	pos := core.entity_pos(w, h)
	feet := c.player.position
	d := distance_to(pos, feet)
	face(w, h, feet + {0, game.PLAYER_EYE, 0}, 0.4, 0.3)
	if d >= near && d <= far {return true}
	if !core.entity_arrived(w, h) && d >= near * 0.5 && d <= far * 1.5 {return false}
	away := pos - feet
	l := math.sqrt(away.x * away.x + away.z * away.z)
	if l < 1e-6 {away, l = {1, 0, 0}, 1}
	to := feet + {away.x, 0, away.z} / l * ((near + far) / 2) + {0, height, 0}
	core.entity_set_speed(w, h, speed)
	if !glide_to(s, w, h, to, false) {glide_to(s, w, h, pos + {0, 2, 0}, false)}
	return false
}

// leave: the creature goes for good: it glides up and away from `from`, distance blocks,
// and is gone once there (or once ticks run out on the way); true once it is gone.
leave :: proc(
	s: ^core.Server,
	w: ^core.World,
	h: game.Entity_Handle,
	m: ^Mind,
	r: ^base.Rng,
	from: [3]f64,
	distance: f64,
) -> bool {
	if m.state != .Leave {
		mind_set(m, .Leave, game.TICK_RATE * 20)
		pos := core.entity_pos(w, h)
		to := pos + away_from(r, pos, from) * distance + {0, distance / 3, 0}
		if !glide_to(s, w, h, to, false) {glide_to(s, w, h, pos + {0, distance / 3, 0}, false)}
	}
	m.timer -= 1
	if core.entity_arrived(w, h) || m.timer <= 0 {
		core.entity_gone(w, h)
		return true
	}
	return false
}

// prey_within: the player that may says a creature goes for (nil: prey_fair) nearest p
// within radius blocks, up and down as well as across (a creature in a cave does not
// notice a player on the ground over it); nil when there is none.
prey_within :: proc(
	s: ^core.Server,
	w: ^core.World,
	p: [3]f64,
	radius: f64,
	may: proc(s: ^core.Server, c: ^core.Client) -> bool = nil,
) -> ^core.Client {
	may := may if may != nil else prey_fair
	best: ^core.Client
	best_d := radius * radius
	for &c in s.clients {
		if c.world != w || !may(s, &c) {continue}
		d := c.player.position - p
		dd := d.x * d.x + d.y * d.y + d.z * d.z
		if dd < best_d {best, best_d = &c, dd}
	}
	return best
}

// crowded: at least most creatures of the kinds given stand within radius blocks of p:
// a game's cap on its creatures round each player, whatever their kinds' own caps.
crowded :: proc(w: ^core.World, p: [3]f64, radius: f64, most: int, kinds: []game.Kind_Id) -> bool {
	n := 0
	for k in kinds {
		n += len(core.entities_of(w, k, p, radius))
		if n >= most {return true}
	}
	return false
}

// block_of: the block a point is in.
block_of :: proc(p: [3]f64) -> game.Block_Pos {
	return {i32(math.floor(p.x)), i32(math.floor(p.y + 0.01)), i32(math.floor(p.z))}
}

// away_from: the way from `from` to pos, horizontally, as a unit (a random way when they
// stand on each other).
@(private = "file")
away_from :: proc(r: ^base.Rng, pos, from: [3]f64) -> [3]f64 {
	d := pos - from
	l := math.sqrt(d.x * d.x + d.z * d.z)
	if l < 1e-6 {
		a := base.rng_f64_range(r, 0, math.TAU)
		return {base.cos(a), 0, base.sin(a)}
	}
	return {d.x / l, 0, d.z / l}
}

// turn_step: an angle a step (rate) of the way to another, the short way round.
@(private = "file")
turn_step :: proc(from, to: f32, rate: f32) -> f32 {
	d := math.mod(to - from + 3 * math.PI, math.TAU) - math.PI
	return from + d * rate
}
