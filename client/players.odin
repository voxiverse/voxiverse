package client

import "core:math"

import "../game"

// The other players: what the server last said about each, kept as a few
// timed snapshots and shown a little in the past (INTERPOLATION_TICKS), in
// between two of them, so they move smoothly although updates come at the
// tick rate and the network jitters.

SNAPSHOTS :: 8
INTERPOLATION_TICKS :: 3 // 100 ms at 30 Hz: covers a late or lost update
STALE_TICKS :: 2 * game.TICK_RATE // no news this long: out of sight

Other_Player :: struct {
	name:      string,
	snapshots: [SNAPSHOTS]Snapshot, // oldest first
	count:     int,
}

Snapshot :: struct {
	tick:       u32,
	position:   [3]f64, // feet
	yaw, pitch: f32,
	flying:     bool,
}

// Other_View: where to draw another player now.
Other_View :: struct {
	position:   [3]f64,
	yaw, pitch: f32,
	flying:     bool,
}

// other_snapshot adds what a Players message said (older or repeated ticks
// are ignored: the network may reorder).
other_snapshot :: proc(o: ^Other_Player, tick: u32, e: game.Player_Entry) {
	if o.count > 0 && game.sequence_before_or_at(tick, o.snapshots[o.count - 1].tick) {return}
	if o.count == SNAPSHOTS {
		copy(o.snapshots[:], o.snapshots[1:])
		o.count -= 1
	}
	o.snapshots[o.count] = {tick, e.position, e.yaw, e.pitch, e.flying}
	o.count += 1
}

// other_view: the player at server time `at` (in ticks, fractional),
// between the snapshots around it (the nearest one at either end); false
// if there is nothing recent enough to show.
other_view :: proc(o: ^Other_Player, at: f64) -> (v: Other_View, ok: bool) {
	if o.count == 0 {return}
	newest := o.snapshots[o.count - 1]
	if at - f64(newest.tick) > STALE_TICKS {return}
	if at >= f64(newest.tick) {return view_of(newest), true}
	for i := o.count - 1; i > 0; i -= 1 {
		a, b := o.snapshots[i - 1], o.snapshots[i]
		if at < f64(a.tick) {continue}
		t := (at - f64(a.tick)) / f64(b.tick - a.tick)
		return {
				position = a.position + (b.position - a.position) * t,
				yaw = lerp_angle(a.yaw, b.yaw, f32(t)),
				pitch = a.pitch + (b.pitch - a.pitch) * f32(t),
				flying = b.flying,
			},
			true
	}
	return view_of(o.snapshots[0]), true
}

// render_tick: the server time to show the others at, from the newest tick
// heard and the time since.
render_tick :: proc(newest_tick: u32, seconds_since: f32) -> f64 {
	return f64(newest_tick) + f64(seconds_since) * game.TICK_RATE - INTERPOLATION_TICKS
}

@(private = "file")
view_of :: proc(s: Snapshot) -> Other_View {
	return {s.position, s.yaw, s.pitch, s.flying}
}

// lerp_angle turns the short way round.
@(private = "file")
lerp_angle :: proc(a, b, t: f32) -> f32 {
	d := math.mod(b - a + 3 * math.PI, math.TAU) - math.PI
	return a + d * t
}
