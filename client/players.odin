package client

import "core:math"
import "core:time"

import "../common/game"

// The other players and the entities: what the server last said about
// each, kept as a few timed snapshots (a Track) and shown a little in the
// past (INTERPOLATION_TICKS), in between two of them, so they move smoothly
// although updates come at the tick rate and the network jitters.

SNAPSHOTS :: 8
INTERPOLATION_TICKS :: 3 // 100 ms at 30 Hz: covers a late or lost update
STALE_SECONDS :: 2 // no snapshot for this long: the connection is lost, nothing is shown

Other_Player :: struct {
	name:  string,
	worn:  [game.WORN_SLOTS]game.Item, // head to feet (Player_Worn)
	track: Track,
}

// Other_Entity: an entity near us (entities.odin draws it).
Other_Entity :: struct {
	kind:      game.Entity_Kind,
	stack:     game.Stack, // a dropped item's
	flags:     game.Sheep_Flags, // a sheep's looks
	track:     Track,
	hurt_at:   time.Tick, // when it was last hit (flash)
	stride:    f32, // blocks walked, for its legs
	last_seen: [3]f64, // where it was drawn last frame
}

Track :: struct {
	snapshots: [SNAPSHOTS]Snapshot, // oldest first
	count:     int,
}

Snapshot :: struct {
	tick:       u32,
	position:   [3]f64, // feet
	yaw, pitch: f32,
	flying:     bool,
	crouched:   bool,
}

// Other_View: where to draw another player now.
Other_View :: struct {
	position:   [3]f64,
	yaw, pitch: f32,
	flying:     bool,
	crouched:   bool,
}

// track_add adds a snapshot (older or repeated ticks are ignored: the
// network may reorder).
track_add :: proc(o: ^Track, snapshot: Snapshot) {
	if o.count > 0 &&
	   game.sequence_before_or_at(snapshot.tick, o.snapshots[o.count - 1].tick) {return}
	if o.count == SNAPSHOTS {
		copy(o.snapshots[:], o.snapshots[1:])
		o.count -= 1
	}
	o.snapshots[o.count] = snapshot
	o.count += 1
}

// other_snapshot adds what a Player_Motion record said about a player.
other_snapshot :: proc(o: ^Other_Player, tick: u32, m: game.Player_Motion) {
	track_add(&o.track, {tick, m.position, m.yaw, m.pitch, m.flying, m.crouched})
}

// other_view: the player at server time `at` (in ticks, fractional),
// between the snapshots around it (the nearest one at either end); false
// if nothing is known of it yet.
other_view :: proc(o: ^Other_Player, at: f64) -> (v: Other_View, ok: bool) {
	return track_view(&o.track, at)
}

// track_hold records that the thing is unchanged as of `tick`: snapshots
// carry only what changed, so a record that is still present and absent
// from the delta stood still. Without this the track would glide from its
// old sample to the next change across the whole time it stood.
track_hold :: proc(o: ^Track, tick: u32) {
	if o.count == 0 {return}
	held := o.snapshots[o.count - 1]
	held.tick = tick
	track_add(o, held)
}

// track_view: where a track puts its thing at server time `at`.
track_view :: proc(o: ^Track, at: f64) -> (v: Other_View, ok: bool) {
	if o.count == 0 {return}
	newest := o.snapshots[o.count - 1]
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
				crouched = b.crouched,
			},
			true
	}
	return view_of(o.snapshots[0]), true
}

// Render_Clock: the server time to show the others at (ticks). It is not
// the newest tick heard plus the time since, minus INTERPOLATION_TICKS (the
// target): a packet that comes late carries a newer tick and would move that
// at once, and the others would skip. The clock runs at the tick rate and
// only speeds up or slows down by a little to close the distance to the
// target; it snaps only after a stall or a big gap.
Render_Clock :: struct {
	time:   f64, // ticks: what is shown
	newest: u32, // the newest tick heard
	since:  f32, // seconds since it was heard (the frames', not the wall clock)
	heard:  bool,
}

CLOCK_CATCH_UP :: 0.1 // per tick of distance: speed change
CLOCK_MAX_SKEW :: 0.1 // the most the speed differs from real time
CLOCK_SNAP_TICKS :: 10 // further off than this (a stall, a jump): snap

clock_target :: proc(c: Render_Clock) -> f64 {
	return f64(c.newest) + f64(c.since) * game.TICK_RATE - INTERPOLATION_TICKS
}

// clock_heard: a snapshot of this tick came.
clock_heard :: proc(c: ^Render_Clock, tick: u32) {
	if c.heard && !game.sequence_before(c.newest, tick) {return}
	c.newest, c.since = tick, 0
	if !c.heard {
		c.heard = true
		c.time = clock_target(c^)
	}
}

// clock_advance: a frame of dt seconds.
clock_advance :: proc(c: ^Render_Clock, dt: f32) {
	if !c.heard {return}
	c.since += dt
	err := clock_target(c^) - c.time
	if abs(err) > CLOCK_SNAP_TICKS {
		c.time += err
		return
	}
	skew := clamp(err * CLOCK_CATCH_UP, -CLOCK_MAX_SKEW, CLOCK_MAX_SKEW)
	c.time += f64(dt) * game.TICK_RATE * (1 + skew)
}

// clock_live: snapshots have come, and not stopped for STALE_SECONDS.
clock_live :: proc(c: Render_Clock) -> bool {
	return c.heard && c.since <= STALE_SECONDS
}

@(private = "file")
view_of :: proc(s: Snapshot) -> Other_View {
	return {s.position, s.yaw, s.pitch, s.flying, s.crouched}
}

// lerp_angle turns the short way round.
@(private = "file")
lerp_angle :: proc(a, b, t: f32) -> f32 {
	d := math.mod(b - a + 3 * math.PI, math.TAU) - math.PI
	return a + d * t
}
