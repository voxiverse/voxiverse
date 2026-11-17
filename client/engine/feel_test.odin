package engine

import "core:math"
import "core:testing"

import "client:render"
import "common:game"

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
	feel_advance(s, 0.5)
	testing.expect_value(t, s.feel.clock, 0.5 * game.TICK_RATE) // (nothing heard: the frames alone)
	clock_heard(&s.render_clock, 100)
	feel_advance(s, 0.05)
	testing.expect_value(t, s.feel.clock, 100 - FEEL_LAG)
	for _ in 0 ..< 20 {feel_advance(s, 0.05)} 	// the server stopped: the clock waits
	testing.expect_value(t, s.feel.clock, 100 + FEEL_LEAD)
	before := s.feel.clock
	clock_heard(&s.render_clock, 101)
	feel_advance(s, 0)
	testing.expect_value(t, s.feel.clock, before) // (never back)
	clock_heard(&s.render_clock, 600) // a hurry: caught up
	feel_advance(s, 0.05)
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
	feel_advance(s, 2) // longer than any burst lives
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
	feel_advance(s, ENTITY_FLASH_SECONDS / 2)
	_, on = entity_flashing(s, &s.entities[7])
	testing.expect(t, on)
	feel_advance(s, ENTITY_FLASH_SECONDS)
	_, on = entity_flashing(s, &s.entities[7])
	testing.expect(t, !on)
	testing.expect(
		t,
		math.abs(f32(s.feel.clock) - 1.5 * ENTITY_FLASH_SECONDS * game.TICK_RATE) < 1e-4,
	)
}
