package play

import "core:testing"

import "common:base"
import "common:game"
import "server:core"

// Minds (mind.odin) on the harness's flat world (grass at y -1, the feet at 0), with the
// base pack's creatures standing in for a game's: the dummy (a steered walker) flees,
// herds, flies and swims; the shambler (one that fights) warns, wakes and winds up.

@(private = "file")
Rig :: struct {
	sess: core.Session,
	s:    ^core.Server,
	w:    ^core.World,
	c:    ^core.Client,
	r:    base.Rng,
}

@(private = "file")
rig_start :: proc(t: ^testing.T, rig: ^Rig) -> bool {
	sess := &rig.sess
	if !testing.expect(
		t,
		core.session_start(sess, {}, false, with = core.harness_world()),
	) {return false}
	_, ok := core.harness_step_until(&sess.h, proc(data: rawptr) -> bool {
			sess := (^core.Session)(data)
			return sess.mirror.welcomed && sess.h.srv.clients[0].state == .Playing
		}, sess, 600)
	if !testing.expect(t, ok, "the player never came") {return false}
	rig.s = &sess.h.srv
	rig.w = rig.s.home
	rig.c = &rig.s.clients[0]
	rig.r = base.rng_make(7)
	core.game_mode(rig.s, rig.c, "survival")
	return true
}

@(private = "file")
kind :: proc(rig: ^Rig, id: string) -> game.Kind_Id {
	k, _ := game.registry_kind(rig.s.registry, id)
	return k
}

@(private = "file")
step :: proc(rig: ^Rig, ticks: int = 1) {
	for _ in 0 ..< ticks {core.harness_step(&rig.sess.h)}
}

// put: the player stands at p (its feet).
@(private = "file")
put :: proc(rig: ^Rig, p: [3]f64) {
	core.teleport(rig.s, rig.c, p, {0, 0})
	step(rig, 2)
}

@(private = "file")
fill :: proc(rig: ^Rig, lo, hi: game.Block_Pos, block: game.Block) {
	core.bulk_edit(
		rig.w,
		{shape = core.Box{lo, hi}, op = .Set, block = block},
		core.game_act(rig.s, rig.w, .Command),
	)
	step(rig)
}

@(test)
test_a_fleeing_creature_runs_from_what_frightened_it :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	defer core.session_stop(&rig.sess)
	if !rig_start(t, rig) {return}
	h := core.entity_spawn(rig.w, kind(rig, "voxiverse:dummy"), {3.5, 0, 0.5}, false)
	if !testing.expect(t, h != 0) {return}
	m: Mind
	mind_settle(rig.w, h, &m)
	testing.expect_value(t, m.home, [3]i32{3, 0, 0})
	scare(rig.w, h, &m, &rig.r, rig.c.player.position, 10, 4, 90)
	testing.expect_value(t, m.state, Mind_State.Flee)
	step(rig, 4 * game.TICK_RATE)
	d := distance_to(core.entity_pos(rig.w, h), rig.c.player.position)
	testing.expectf(t, d > 8, "it is %v blocks off", d)
}

// A herd's stray walks back to the others, and a fright spreads to its mates alone.
@(test)
test_a_herd_keeps_together_and_takes_fright_together :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	defer core.session_stop(&rig.sess)
	if !rig_start(t, rig) {return}
	dummy := kind(rig, "voxiverse:dummy")
	herd: [3]game.Entity_Handle
	for &h, i in herd {h = core.entity_spawn(rig.w, dummy, {12.5 + f64(i), 0, 6.5}, false)}
	stray := core.entity_spawn(rig.w, dummy, {-2.5, 0, 6.5}, false)
	if !testing.expect(t, stray != 0 && herd[2] != 0) {return}
	center, n := herd_center(rig.w, stray, 24)
	testing.expect_value(t, n, 3)
	testing.expect_value(t, center, [3]f64{13.5, 0, 6.5})
	m: Mind
	mind_settle(rig.w, stray, &m)
	herd_wander(rig.w, stray, &m, &rig.r, 2, 24)
	testing.expect_value(t, m.home, [3]i32{13, 0, 6})
	step(rig, 14 * game.TICK_RATE)
	d := distance_to(core.entity_pos(rig.w, stray), center)
	testing.expectf(t, d < 4, "the stray is %v blocks from its herd", d)

	mates := herd_mates(rig.w, herd[0], 8)
	testing.expect_value(t, len(mates), 3) // (the stray has come)
	minds: [3]Mind
	for o, i in mates {scare(rig.w, o, &minds[i], &rig.r, core.entity_pos(rig.w, herd[0]), 8, 4, 60)}
	for mi in minds {testing.expect_value(t, mi.state, Mind_State.Flee)}
	far := herd_mates(rig.w, herd[0], 0.5)
	testing.expect_value(t, len(far), 0)
}

@(private = "file")
GUARD :: Temper {
	notice   = 8,
	near     = 4,
	warn     = game.TICK_RATE * 2,
	leash    = 16,
	patience = game.TICK_RATE * 2,
	wind     = 6,
}

// temper: the creature's temper for ticks; the prey it last fought.
@(private = "file")
temper :: proc(
	rig: ^Rig,
	h: game.Entity_Handle,
	m: ^Mind,
	t: Temper,
	calm: Mind_State,
	ticks: int,
) {
	for _ in 0 ..< ticks {
		temper_tick(rig.s, rig.w, h, m, t, calm)
		step(rig)
	}
}

// A guard warns a player who comes near its ground and stands; one who stays too near is
// attacked once the warning ran out; one who goes off is left, and the guard goes home.
// A player who cannot be hurt is never warned.
@(test)
test_a_guard_warns_before_it_attacks :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	defer core.session_stop(&rig.sess)
	if !rig_start(t, rig) {return}
	h := core.entity_spawn(rig.w, kind(rig, "voxiverse:shambler"), {0.5, 0, 6.5}, false)
	if !testing.expect(t, h != 0) {return}
	m: Mind
	mind_settle(rig.w, h, &m)
	core.game_mode(rig.s, rig.c, "creative")
	put(rig, {0.5, 0, 0.5})
	temper(rig, h, &m, GUARD, .Idle, game.TICK_RATE)
	testing.expect_value(t, m.state, Mind_State.Idle)

	core.game_mode(rig.s, rig.c, "survival")
	health := rig.c.health
	temper(rig, h, &m, GUARD, .Idle, game.TICK_RATE)
	testing.expect_value(t, m.state, Mind_State.Warn)
	moved := distance_to(core.entity_pos(rig.w, h), {0.5, 0, 6.5})
	testing.expectf(t, moved < 0.5, "it moved %v while warning", moved)
	testing.expect_value(t, rig.c.health, health)
	temper(rig, h, &m, GUARD, .Idle, 2 * game.TICK_RATE)
	testing.expect_value(t, m.state, Mind_State.Warn) // (6 blocks off: still only a warning)
	testing.expect_value(t, rig.c.health, health)

	put(rig, {0.5, 0, 4})
	temper(rig, h, &m, GUARD, .Idle, 4 * game.TICK_RATE)
	testing.expect(t, rig.c.health < health, "it never attacked one standing too near")

	put(rig, {0.5, 0, -30})
	temper(rig, h, &m, GUARD, .Idle, 12 * game.TICK_RATE)
	testing.expect_value(t, m.state, Mind_State.Idle)
	back := distance_to(core.entity_pos(rig.w, h), home_point(&m))
	testing.expectf(t, back < 1, "it is %v blocks from home", back)
}

// A sentry sleeps at its post past its notice, wakes (a moment to see it coming) when a
// player comes near, fights, and sleeps again at its post once the player is gone. Hurt,
// it wakes whoever is near.
@(test)
test_a_sleeper_wakes_when_someone_comes_near :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	defer core.session_stop(&rig.sess)
	if !rig_start(t, rig) {return}
	h := core.entity_spawn(rig.w, kind(rig, "voxiverse:shambler"), {0.5, 0, 10.5}, false)
	if !testing.expect(t, h != 0) {return}
	m := Mind {
		state = .Dormant,
	}
	mind_settle(rig.w, h, &m)
	post := GUARD
	post.near, post.post, post.warn = 0, true, game.TICK_RATE
	put(rig, {0.5, 0, -2})
	temper(rig, h, &m, post, .Dormant, 2 * game.TICK_RATE)
	testing.expect_value(t, m.state, Mind_State.Dormant)
	put(rig, {0.5, 0, 4.5})
	temper(rig, h, &m, post, .Dormant, 2)
	testing.expect_value(t, m.state, Mind_State.Wake)
	health := rig.c.health
	temper(rig, h, &m, post, .Dormant, 5 * game.TICK_RATE)
	testing.expect(t, rig.c.health < health, "it woke and never fought")
	put(rig, {0.5, 0, -40})
	temper(rig, h, &m, post, .Dormant, 15 * game.TICK_RATE)
	testing.expect_value(t, m.state, Mind_State.Dormant)

	provoke(&m, post)
	testing.expect_value(t, m.state, Mind_State.Wake)
}

// A blow is wound up first: a player who steps out of reach while it winds up is not hit.
@(test)
test_a_wound_up_blow_can_be_escaped :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	defer core.session_stop(&rig.sess)
	if !rig_start(t, rig) {return}
	h := core.entity_spawn(rig.w, kind(rig, "voxiverse:shambler"), {0.5, 0, 1.6}, false)
	if !testing.expect(t, h != 0) {return}
	m: Mind
	put(rig, {0.5, 0, 0.5})
	health := rig.c.health
	for _ in 0 ..< game.TICK_RATE {
		fight_fair(rig.s, rig.w, h, &m, rig.c, 15)
		step(rig)
		if m.wind > 0 {break}
	}
	if !testing.expect(t, m.wind > 0, "it never wound up") {return}
	put(rig, {0.5, 0, -6})
	for _ in 0 ..< 15 {
		fight_fair(rig.s, rig.w, h, &m, rig.c, 15)
		step(rig)
	}
	testing.expect_value(t, rig.c.health, health)
	testing.expect(t, m.ready > 0, "the blow was not spent")
}

// in_medium: the creature's feet are in an open block of its medium.
@(private = "file")
in_medium :: proc(rig: ^Rig, h: game.Entity_Handle, water: bool) -> bool {
	return medium_has(rig.s, rig.w, block_of(core.entity_pos(rig.w, h)), water)
}

// A flier wanders through the air round a hill and never into it, keeps out of the
// water, flees up and away, and lands on open ground.
@(test)
test_a_flier_stays_in_the_air :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	defer core.session_stop(&rig.sess)
	if !rig_start(t, rig) {return}
	fill(rig, {4, 0, -3}, {7, 9, 3}, .Stone)
	fill(rig, {-8, -3, -3}, {-5, -1, 3}, .Water)
	fill(rig, {-2, 4, 8}, {-2, 4, 8}, .Gate_Horizon)
	testing.expect(t, !medium_has(rig.s, rig.w, {-2, 4, 8}, false), "a gate's surface is open air")
	testing.expect(t, medium_has(rig.s, rig.w, {-2, 4, 9}, false))
	testing.expect(t, !medium_has(rig.s, rig.w, {-6, -2, 0}, false), "water is open air")
	testing.expect(t, medium_has(rig.s, rig.w, {-6, -2, 0}, true))
	h := core.entity_spawn(rig.w, kind(rig, "voxiverse:dummy"), {0.5, 0, 0.5}, false)
	if !testing.expect(t, h != 0) {return}
	m: Mind
	mind_settle(rig.w, h, &m)
	flights, highest := 0, 0.0
	for _ in 0 ..< 20 * game.TICK_RATE {
		if core.entity_arrived(rig.w, h) || flights == 0 {
			if fly_wander(rig.s, rig.w, h, &rig.r, home_point(&m), 10, 2, 6, 6) {flights += 1}
		}
		step(rig)
		highest = max(highest, core.entity_pos(rig.w, h).y)
		if !testing.expectf(
			t,
			in_medium(rig, h, false),
			"in %v at %v",
			core.block_at(rig.w, block_of(core.entity_pos(rig.w, h))),
			core.entity_pos(rig.w, h),
		) {return}
	}
	testing.expectf(t, flights >= 5, "it flew %d times", flights)
	testing.expectf(t, highest >= 2, "it flew no higher than %v", highest)
	circled := 0
	for _ in 0 ..< 10 * game.TICK_RATE {
		if core.entity_arrived(rig.w, h) || circled == 0 {
			if fly_circle(rig.s, rig.w, h, &rig.r, home_point(&m), 8, 0.8, 4, 6, 6) {circled += 1}
		}
		step(rig)
		if !testing.expect(t, in_medium(rig, h, false), "it circled out of the air") {return}
	}
	testing.expectf(t, circled >= 3, "it circled %d legs", circled)

	put(rig, {0.5, 0, 0.5})
	before := distance_to(core.entity_pos(rig.w, h), rig.c.player.position)
	testing.expect(t, fly_flee(rig.s, rig.w, h, &rig.r, rig.c.player.position, 8, 3, 6, 8))
	step(rig, 3 * game.TICK_RATE)
	testing.expect(t, distance_to(core.entity_pos(rig.w, h), rig.c.player.position) > before)
	testing.expect(t, in_medium(rig, h, false))

	testing.expect(t, land(rig.s, rig.w, h, &rig.r, home_point(&m), 3))
	step(rig, 5 * game.TICK_RATE)
	testing.expect(t, core.entity_arrived(rig.w, h), "it never came down")
	testing.expect(
		t,
		standable(rig.s, rig.w, block_of(core.entity_pos(rig.w, h))),
		"it landed on nothing",
	)
}

// A swimmer wanders through its pool and darts from a player, never out of the water.
@(test)
test_a_swimmer_stays_in_the_water :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	defer core.session_stop(&rig.sess)
	if !rig_start(t, rig) {return}
	fill(rig, {-7, 0, 3}, {7, 5, 15}, .Stone) // (a basin over the ground: its chunks and those under them are loaded)
	fill(rig, {-6, 0, 4}, {6, 5, 14}, .Water)
	h := core.entity_spawn(rig.w, kind(rig, "voxiverse:dummy"), {0.5, 1, 9.5}, false)
	if !testing.expect(t, h != 0) {return}
	m: Mind
	mind_settle(rig.w, h, &m)
	swims := 0
	for i in 0 ..< 20 * game.TICK_RATE {
		if core.entity_arrived(rig.w, h) || swims == 0 {
			if swim_wander(rig.s, rig.w, h, &rig.r, home_point(&m), 8, 3) {swims += 1}
		}
		if i == 10 * game.TICK_RATE {
			swim_flee(rig.s, rig.w, h, &rig.r, rig.c.player.position, 6, 6)
		}
		step(rig)
		if !testing.expectf(
			t,
			in_medium(rig, h, true),
			"out of the water at %v",
			core.entity_pos(rig.w, h),
		) {return}
	}
	testing.expectf(t, swims >= 5, "it swam %d times", swims)
}

// A watcher keeps a player at a distance as the player moves, then leaves for good.
@(test)
test_a_watcher_follows_at_a_distance_then_leaves :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	defer core.session_stop(&rig.sess)
	if !rig_start(t, rig) {return}
	h := core.entity_spawn(rig.w, kind(rig, "voxiverse:dummy"), {20.5, 4, 0.5}, false)
	if !testing.expect(t, h != 0) {return}
	m: Mind
	held := 0
	for i in 0 ..< 12 * game.TICK_RATE {
		if i == 4 * game.TICK_RATE {put(rig, {-10.5, 0, 0.5})}
		if follow_at(rig.s, rig.w, h, rig.c, 6, 12, 3, 8) && i > 8 * game.TICK_RATE {held += 1}
		step(rig)
	}
	testing.expectf(t, held > 2 * game.TICK_RATE, "it held its distance for %d ticks", held)
	id := core.entity_id(rig.w, h)
	gone := false
	for _ in 0 ..< 25 * game.TICK_RATE {
		if leave(rig.s, rig.w, h, &m, &rig.r, rig.c.player.position, 20) {
			gone = true
			break
		}
		step(rig)
	}
	_, still := core.entity_find(rig.w, id)
	testing.expect(t, gone && !still, "it never left")
}

// The creatures nobody is near think once in FAR_THINK ticks; a game's cap counts every
// kind it names.
@(test)
test_far_minds_rest_and_crowds_are_capped :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	defer core.session_stop(&rig.sess)
	if !rig_start(t, rig) {return}
	dummy, shambler := kind(rig, "voxiverse:dummy"), kind(rig, "voxiverse:shambler")
	h := core.entity_spawn(rig.w, dummy, {3.5, 0, 0.5}, false)
	due := 0
	m := Mind {
		timer = 1000,
	}
	for _ in 0 ..< FAR_THINK * 10 {
		testing.expect(t, mind_due(rig.s, rig.w, h, &m, true))
		if mind_due(rig.s, rig.w, h, &m, false) {due += 1}
		step(rig)
	}
	testing.expect_value(t, due, 10)
	testing.expect_value(t, m.timer, 1000 - FAR_THINK * 10 + 10) // (its clock ran on between)
	for i in 0 ..< 3 {core.entity_spawn(rig.w, shambler, {-3.5, 0, 0.5 + f64(i)}, false)}
	step(rig)
	testing.expect(t, crowded(rig.w, {0, 0, 0}, 16, 4, {dummy, shambler}))
	testing.expect(t, !crowded(rig.w, {0, 0, 0}, 16, 5, {dummy, shambler}))
	testing.expect(t, !crowded(rig.w, {0, 0, 0}, 16, 2, {dummy}))
}
