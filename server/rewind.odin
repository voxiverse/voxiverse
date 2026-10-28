package server

import "core:math"

import "../common/game"

// Lag compensation: what a shooter saw is not what the server has now. Every
// tick the server keeps where each player and each hittable creature stood
// (a ring of the last REWIND_MAX_TICKS+1 ticks); a shot rewinds its targets
// by the shooter's latency, capped at REWIND_MAX_TICKS (about 250 ms: a player
// with more lag aims at what the cap allows, the price of their connection).
// Only the shot's ray test sees the old positions; nothing else moves.

REWIND_MAX_TICKS :: 8 // about 250 ms at 30 Hz
REWIND_RING :: REWIND_MAX_TICKS + 2

// Rewind_Body: where one thing stood at the end of a tick.
Rewind_Body :: struct {
	id:       u32, // a player's id, a creature's entity id
	position: [3]f64,
	crouched: bool,
}

Rewind_Frame :: struct {
	tick:      u64, // the tick it was taken at the end of (0: none)
	players:   [dynamic]Rewind_Body, // heap
	creatures: [dynamic]Rewind_Body,
}

Rewind :: struct {
	frames: [REWIND_RING]Rewind_Frame,
}

rewind_destroy :: proc(r: ^Rewind) {
	for &f in r.frames {
		delete(f.players)
		delete(f.creatures)
	}
	r^ = {}
}

// rewind_record: w's bodies as they stand, filed under this tick.
rewind_record :: proc(s: ^Server, w: ^World) {
	f := &w.rewind.frames[s.tick % REWIND_RING]
	clear(&f.players)
	clear(&f.creatures)
	f.tick = s.tick
	for &c, i in s.clients {
		if c.state != .Playing || c.world != w {continue}
		append(&f.players, Rewind_Body{u32(i), c.player.position, c.player.crouched})
	}
	for &ent in w.entities.list {
		if !game.ENTITY_INFO[ent.kind].hittable {continue}
		append(&f.creatures, Rewind_Body{ent.id, ent.body.position, false})
	}
}

// rewind_ticks: how many ticks back a shooter with latency_ms sees the world:
// their round trip and the client's interpolation delay, within the cap.
rewind_ticks :: proc(latency_ms: f32) -> int {
	ticks := int(math.round(f64(latency_ms) / 1000 * game.TICK_RATE))
	return clamp(ticks, 0, REWIND_MAX_TICKS)
}

// rewind_frame: the frame k ticks before the last finished one (nil: k is 0,
// or the ring does not have it: test against where things are).
rewind_frame :: proc(s: ^Server, w: ^World, k: int) -> ^Rewind_Frame {
	if k <= 0 || s.tick <= u64(k) + 1 {return nil}
	want := s.tick - 1 - u64(k) // (the tick now being run has no frame yet)
	f := &w.rewind.frames[want % REWIND_RING]
	if f.tick != want {return nil}
	return f
}

// rewind_body: where the body with id stood in f (false: it was not there).
rewind_body :: proc(bodies: []Rewind_Body, id: u32) -> (b: Rewind_Body, ok: bool) {
	for x in bodies {if x.id == id {return x, true}}
	return {}, false
}
