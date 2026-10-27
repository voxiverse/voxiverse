package client

import "audio"

// The mixer's snapshots, composed (M44): one wanted snapshot a frame from the
// conditions that hold (paused, loading, just died), each a set of bus gains
// and cutoffs. Gains multiply, cutoffs take the lowest; the mixer is told only
// when the result changes, over the time of the condition that came or went.

Snapshot_Condition :: enum u8 {
	Paused,
	Loading,
	Death,
}

Snapshot_Conditions :: bit_set[Snapshot_Condition]

DEATH_HOLD :: 4.0 // seconds the death snapshot is held after a death

// The snapshots (gain, cutoff in Hz, 0 open per bus) and the seconds each
// takes to come in and to go out.
SNAP_PAUSED :: audio.Snapshot {
	gain = {
		.Music = 0.5,
		.World = 0.3,
		.Player = 0.3,
		.Ambience = 0.4,
		.Effects = 1,
		.UI = 1,
		.Master = 1,
	},
	cutoff = #partial{.Music = 2000, .World = 1200, .Ambience = 1500},
}
SNAP_LOADING :: audio.Snapshot {
	gain = {
		.Music = 1,
		.World = 0,
		.Player = 0,
		.Ambience = 0,
		.Effects = 1,
		.UI = 1,
		.Master = 1,
	},
}
SNAP_DEATH :: audio.Snapshot {
	gain = {
		.Music = 1,
		.World = 0.3,
		.Player = 0.3,
		.Ambience = 0.3,
		.Effects = 1,
		.UI = 1,
		.Master = 1,
	},
	cutoff = #partial{.World = 800},
}

@(rodata)
SNAPSHOT_IN := [Snapshot_Condition]f32 {
	.Paused  = 0.3,
	.Loading = 0.5,
	.Death   = 0.1,
}

@(rodata)
SNAPSHOT_OUT := [Snapshot_Condition]f32 {
	.Paused  = 0.3,
	.Loading = 0.5,
	.Death   = 2,
}

Snapshots :: struct {
	holds:      Snapshot_Conditions, // as last told to the mixer
	death_left: f32, // seconds of the death snapshot still to hold
	died_seen:  int, // Session.died as last seen
	session:    ^Session, // (died_seen belongs to this session)
}

// snapshot_compose: the snapshot of the conditions that hold.
snapshot_compose :: proc(c: Snapshot_Conditions) -> (s: audio.Snapshot) {
	s = audio.snapshot_neutral()
	for cond in c {
		one: audio.Snapshot
		switch cond {
		case .Paused:
			one = SNAP_PAUSED
		case .Loading:
			one = SNAP_LOADING
		case .Death:
			one = SNAP_DEATH
		}
		for b in audio.Bus {
			s.gain[b] *= one.gain[b]
			if one.cutoff[b] > 0 && (s.cutoff[b] == 0 || one.cutoff[b] < s.cutoff[b]) {
				s.cutoff[b] = one.cutoff[b]
			}
		}
	}
	return
}

// snapshot_time: seconds to move from the conditions `was` to `now`: the
// slowest of those that came (their time in) and, when only some went, of
// those (their time out).
snapshot_time :: proc(was, now: Snapshot_Conditions) -> (seconds: f32) {
	for cond in now - was {seconds = max(seconds, SNAPSHOT_IN[cond])}
	if seconds == 0 {
		for cond in was - now {seconds = max(seconds, SNAPSHOT_OUT[cond])}
	}
	return
}

// snapshots_update tells the mixer the snapshot the conditions want, if it
// changed. died: the session's count of deaths.
snapshots_update :: proc(app: ^App, dt: f32) {
	sn := &app.snapshots
	s := app.session
	if s != sn.session {sn.session, sn.died_seen, sn.death_left = s, s.died if s != nil else 0, 0}
	if s != nil && s.died != sn.died_seen {
		sn.died_seen = s.died
		sn.death_left = DEATH_HOLD
	}
	sn.death_left = max(sn.death_left - dt, 0)
	now: Snapshot_Conditions
	if s != nil && world_paused(app) {now += {.Paused}}
	if s != nil && (s.loading != nil || s.state != .Playing) {now += {.Loading}}
	if sn.death_left > 0 {now += {.Death}}
	if now == sn.holds {return}
	audio.set_snapshot(app.mixer, snapshot_compose(now), snapshot_time(sn.holds, now))
	sn.holds = now
}
