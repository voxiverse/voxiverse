package engine

import "core:math"
import "core:testing"

import "client:render"
import "common:game"
import "common:protocol"

// feel_session: a session with room for puffs and entities, no server (the heap: a Session
// is past what a test thread's stack holds).
@(private = "file")
feel_session :: proc() -> ^Session {
	s := new(Session)
	s.puffs = make([dynamic]Puff, 0, MAX_PUFFS)
	return s
}

@(private = "file")
feel_free :: proc(s: ^Session) {
	delete(s.puffs)
	delete(s.entities)
	free(s)
}

// The feel clock runs with the frames, but never further than FEEL_LEAD ahead of the newest
// tick heard (a world standing still holds its effects) nor FEEL_LAG behind it (a hurried
// server's ticks are caught up at once).
@(test)
test_feel_clock_follows_the_ticks_heard :: proc(t: ^testing.T) {
	s := feel_session()
	defer feel_free(s)
	feel_advance(s, {}, 0.5)
	testing.expect_value(t, s.feel.clock, 0.5 * game.TICK_RATE) // (nothing heard: the frames alone)
	clock_heard(&s.render_clock, 100)
	feel_advance(s, {}, 0.05)
	testing.expect_value(t, s.feel.clock, 100 - FEEL_LAG)
	for _ in 0 ..< 20 {feel_advance(s, {}, 0.05)} 	// the server stopped: the clock waits
	testing.expect_value(t, s.feel.clock, 100 + FEEL_LEAD)
	before := s.feel.clock
	clock_heard(&s.render_clock, 101)
	feel_advance(s, {}, 0)
	testing.expect_value(t, s.feel.clock, before) // (never back)
	clock_heard(&s.render_clock, 600) // a hurry: caught up
	feel_advance(s, {}, 0.05)
	testing.expect_value(t, s.feel.clock, 600 - FEEL_LAG)
	s.rx.tick = 650
	testing.expect_value(t, feel_now(s), 650) // an effect of a message taken starts at its tick
	testing.expect_value(t, feel_age(s, 650), 0)
	testing.expect_value(t, feel_age(s, 599 - game.TICK_RATE), 1)
}

// A puff is where its age puts it, however the frames fell: thrown and falling with no drag,
// slowing toward its fall speed with drag.
@(test)
test_puff_moves_by_its_age :: proc(t: ^testing.T) {
	p := Puff {
		position = {1, 2, 3},
		velocity = {2, 4, 0},
		gravity  = 10,
	}
	testing.expect_value(t, puff_at(p, 0), [3]f64{1, 2, 3})
	at := puff_at(p, 0.5)
	testing.expect(t, abs(at.x - 2) < 1e-5 && abs(at.y - (2 + 2 - 1.25)) < 1e-5)
	p.drag = 2
	near := puff_at(p, 0.0001)
	testing.expect(t, abs(near.x - 1.0002) < 1e-5, "drag barely slows the first instant")
	far, farther := puff_at(p, 20), puff_at(p, 21)
	testing.expect(t, abs(far.x - farther.x) < 1e-5, "drag stops it across")
	testing.expect(t, abs((far.y - farther.y) - 5) < 1e-3, "and it falls at gravity / drag")
	testing.expect(t, abs(far.x - 2) < 1e-4, "having gone v / drag")
}

// Bursts never have more than MAX_BURST_PUFFS alive, nor take the engine's room past it;
// the puffs they made go with their life, and then bursts may make more.
@(test)
test_bursts_are_capped :: proc(t: ^testing.T) {
	s := feel_session()
	defer feel_free(s)
	for _ in 0 ..< 200 {burst(s, {0, 64, 0}, .Death)}
	testing.expect_value(t, s.feel.burst_puffs, MAX_BURST_PUFFS)
	testing.expect_value(t, len(s.puffs), MAX_BURST_PUFFS)
	for p in s.puffs {testing.expect(t, p.burst && p.color.a == 255)}
	burst(s, {0, 64, 0}, .Sparkle, {10, 200, 10, 255})
	testing.expect_value(t, len(s.puffs), MAX_BURST_PUFFS)
	testing.expect(t, puff_add(s, {life = 10}), "the engine's own effects still have room")

	d: render.Entity_Draw
	render.entity_draw_init(&d)
	defer render.entity_draw_destroy(&d)
	feel_advance(s, {}, 2) // longer than any burst lives
	entities_draw(s, &d)
	testing.expect_value(t, s.feel.burst_puffs, 0)
	testing.expect_value(t, len(s.puffs), 1)
	burst(s, {0, 64, 0}, .Impact, {10, 200, 10, 255}, scale = 2)
	testing.expect_value(t, s.feel.burst_puffs, 8)
	green := 0
	for p in s.puffs {if p.burst && p.color.g > p.color.r {green += 1}}
	testing.expect_value(t, green, 8)
}

// A flash on an entity stands ENTITY_FLASH_SECONDS on the feel clock, in its colour; a hurt
// one is red.
@(test)
test_entity_flash :: proc(t: ^testing.T) {
	s := feel_session()
	defer feel_free(s)
	s.entities[7] = {}
	_, flashing := entity_flashing(s, &s.entities[7])
	testing.expect(t, !flashing, "never flashed")
	entity_flash(s, 7, {255, 255, 255, 255})
	entity_flash(s, 8, {255, 255, 255, 255}) // (one not known: nothing)
	color, on := entity_flashing(s, &s.entities[7])
	testing.expect(t, on && color == {255, 255, 255, 255})
	feel_advance(s, {}, ENTITY_FLASH_SECONDS / 2)
	_, on = entity_flashing(s, &s.entities[7])
	testing.expect(t, on)
	feel_advance(s, {}, ENTITY_FLASH_SECONDS)
	_, on = entity_flashing(s, &s.entities[7])
	testing.expect(t, !on)
	testing.expect(
		t,
		math.abs(f32(s.feel.clock) - 1.5 * ENTITY_FLASH_SECONDS * game.TICK_RATE) < 1e-4,
	)
}

// Shakes die away and add up to a whole one at most; a fifth takes the place of the one with
// least left. With the setting off, or Reduce motion on, nothing moves the view at all.
@(test)
test_shakes_combine_decay_and_obey_the_setting :: proc(t: ^testing.T) {
	s := feel_session()
	defer feel_free(s)
	full := Settings {
		screen_shake = 1,
	}
	feel_advance(s, full, 0.1)
	move, turn := feel_view(&s.feel)
	testing.expect(t, move == {} && turn == {}, "nothing under way: still")
	shake(s, 0.3, 0.5)
	testing.expect(t, abs(feel_shaking(&s.feel) - 0.3) < 1e-5)
	shake(s, 0.3, 0.5)
	testing.expect(t, abs(feel_shaking(&s.feel) - 0.6) < 1e-5, "two add up")
	for _ in 0 ..< 4 {shake(s, 0.9, 1)}
	testing.expect_value(t, feel_shaking(&s.feel), 1) // (capped)
	feel_advance(s, full, 0.2)
	moved: f32
	for _ in 0 ..< 5 {
		feel_advance(s, full, 0.01)
		move, turn = feel_view(&s.feel)
		moved = max(moved, abs(move.x) + abs(move.y) + abs(move.z))
	}
	testing.expect(t, moved > 0 && moved <= 3 * SHAKE_MOVE, "it moves, within a whole shake")
	feel_advance(s, full, 1)
	testing.expect_value(t, feel_shaking(&s.feel), 0) // (over)

	kick(s, 3)
	feel_advance(s, full, KICK_PEAK)
	_, turn = feel_view(&s.feel)
	testing.expect(t, abs(turn.y - 3 * math.RAD_PER_DEG) < 1e-4, "a kick peaks at its degrees")
	for _ in 0 ..< 6 {kick(s, 4)}
	_, turn = feel_view(&s.feel)
	testing.expect(t, turn.y <= KICK_CAP * math.RAD_PER_DEG + 1e-5, "kicks are capped")
	half := full
	half.screen_shake = 0.5
	feel_advance(s, half, 0)
	_, low := feel_view(&s.feel)
	testing.expect(t, abs(low.y - turn.y / 2) < 1e-5, "the setting scales them")

	shake(s, 1, 2)
	for off in ([]Settings{{}, {screen_shake = 1, reduce_motion = true}}) {
		feel_advance(s, off, 0.01)
		move, turn = feel_view(&s.feel)
		testing.expect(t, move == {} && turn == {}, "off: the view stands")
	}
	feel_advance(s, full, 4)
	_, turn = feel_view(&s.feel)
	testing.expect(t, abs(turn.y) < 1e-3, "and settles")
}

// Floating texts are capped (the oldest gives way), cut at a whole letter, and gone after
// FLOAT_SECONDS; a pulse fades in PULSE_SECONDS.
@(test)
test_floats_are_capped_and_go :: proc(t: ^testing.T) {
	s := feel_session()
	defer feel_free(s)
	for i in 0 ..< MAX_FLOATS {
		float_text(s, {0, 0, 0}, "12", {255, 255, 255, 255})
		feel_advance(s, {}, 0.001)
		testing.expect_value(t, s.feel.floats[i].len, 2)
	}
	first := s.feel.floats[0].born
	float_text(s, {1, 2, 3}, "+5 coins and then a very long tail", {255, 255, 255, 255})
	testing.expect(t, s.feel.floats[0].born > first, "the oldest gave way")
	testing.expect_value(t, s.feel.floats[0].at, [3]f64{1, 2, 3})
	testing.expect_value(t, s.feel.floats[0].len, FLOAT_TEXT_MAX)
	float_text(s, {}, "ééééééééééééééééééé", {255, 255, 255, 255}) // (two bytes a letter)
	testing.expect_value(t, s.feel.floats[1].len, FLOAT_TEXT_MAX)
	float_text(s, {}, "éééééééééééééééééééé", {255, 255, 255, 255})
	testing.expect_value(t, s.feel.floats[2].len, FLOAT_TEXT_MAX) // (24 is whole: 12 letters)
	float_text(s, {}, "aéééééééééééééééééééé", {255, 255, 255, 255})
	testing.expect_value(t, s.feel.floats[3].len, FLOAT_TEXT_MAX - 1)
}

// A tween runs 0 to 1 along its curve over its seconds; one never started, and any under
// Reduce motion, is done.
@(test)
test_tween :: proc(t: ^testing.T) {
	s := feel_session()
	defer feel_free(s)
	tw: Tween
	testing.expect_value(t, tween_value(&tw, s, 0.5), 1)
	tween_start(&tw, s)
	testing.expect_value(t, tween_value(&tw, s, 0.5, .Linear), 0)
	feel_advance(s, {}, 0.25)
	testing.expect(t, abs(tween_value(&tw, s, 0.5, .Linear) - 0.5) < 1e-4)
	testing.expect(t, tween_value(&tw, s, 0.5, .Out_Cubic) > 0.5)
	feel_advance(s, {reduce_motion = true}, 0)
	testing.expect_value(t, tween_value(&tw, s, 0.5, .Linear), 1)
	feel_advance(s, {}, 1)
	testing.expect_value(t, tween_value(&tw, s, 0.5, .Out_Back), 1)

	f: Flash
	flash(&f, s, "WAVE 3", .Warn, 1)
	testing.expect_value(t, flash_shown(&f, s), "WAVE 3")
	feel_advance(s, {}, 1)
	testing.expect_value(t, flash_shown(&f, s), "")
}

@(private = "file", thread_local)
seen_log: [dynamic]Seen

// The game's seen hook hears what the engine showed: an entity hurt, with the health it
// lost; an entity dying, with what it had left; the player hurt and healed (a respawn is
// no heal), its shot hitting.
@(test)
test_seen_hook :: proc(t: ^testing.T) {
	s := feel_session()
	defer feel_free(s)
	defer delete(s.sounds)
	defer delete(seen_log)
	reg: game.Registry
	s.reg = &reg
	s.game.seen = proc(s: ^Session, e: Seen) {append(&seen_log, e)}
	s.entities[5] = {
		health     = 10,
		max_health = 10,
		last_seen  = {1, 2, 3},
	}
	record := protocol.Entity_Record {
		health     = 7,
		max_health = 10,
	}
	apply_entity(
		s,
		{kind = int(protocol.State_Kind.Entity), op = .Change, key = {a = 5}, value = &record},
	)
	event :: proc(s: ^Session, kind: protocol.Event_Kind, value: rawptr) {
		apply_event(s, {kind = len(protocol.State_Kind) + int(kind), op = .Event, value = value})
	}
	hurt := protocol.Entity_Hurt{5}
	event(s, .Entity_Hurt, &hurt)
	died := protocol.Entity_Died{5}
	event(s, .Entity_Died, &died)
	harm := protocol.Damage_Hit {
		yaw    = 4,
		amount = 1.5,
		known  = true,
	}
	event(s, .Damage_Hit, &harm)
	confirm := protocol.Hit_Confirm {
		kill = true,
	}
	event(s, .Hit_Confirm, &confirm)
	health :: proc(s: ^Session, h: protocol.Health) {
		h := h
		apply_health(s, {kind = int(protocol.State_Kind.Health), op = .Change, value = &h})
	}
	health(s, {10, 20, false, game.NO_ITEM, 0}) // (the first word: no heal)
	health(s, {14, 20, false, game.NO_ITEM, 0})
	health(s, {0, 20, true, game.NO_ITEM, 0})
	health(s, {20, 20, false, game.NO_ITEM, 0}) // (a respawn: no heal)
	for len(s.puffs) < MAX_PUFFS {append(&s.puffs, Puff{life = 10})} 	// (no room for debris: no world to break)
	blast := protocol.Explosion{{0, 64, 0}, 4}
	event(s, .Explosion, &blast)

	if !testing.expect_value(t, len(seen_log), 6) {return}
	testing.expect_value(t, seen_log[0].(Seen_Hurt).amount, 3)
	testing.expect_value(t, seen_log[0].(Seen_Hurt).at, [3]f64{1, 2.5, 3})
	testing.expect_value(t, seen_log[1].(Seen_Death).amount, 7)
	testing.expect_value(t, seen_log[2].(Seen_Harm).amount, 1.5)
	testing.expect(t, seen_log[3].(Seen_Hit).kill)
	testing.expect_value(t, seen_log[4].(Seen_Heal).amount, 4)
	testing.expect_value(t, seen_log[5].(Seen_Blast).radius, 4)
	testing.expect_value(t, blast_shake({0, 64, 0}, {3, 64, 0}, 4), 1)
	testing.expect_value(t, blast_shake({0, 64, 0}, {10, 64, 0}, 4), 0.5)
	testing.expect_value(t, blast_shake({0, 64, 0}, {20, 64, 0}, 4), 0)
	color, flashing := entity_flashing(s, &s.entities[5])
	testing.expect(t, flashing && color == HURT, "a hurt creature flashes red")
}
