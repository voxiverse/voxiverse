package sandbox_server

import "common:game"
import "games:sandbox"
import "server:core"
import "server:play"

// The music's mood (sandbox.Mood_Record, the client part's engine.music_mood): what is
// happening to each player, looked at MOOD_EVERY ticks and put when it changes. In the
// order it is judged:
//
// - Victory: it won the ruin's fight or a custodian's in the last MOOD_VICTORY seconds;
// - Boss: it fights a custodian in its hall;
// - Danger: it fights at the ruin, a creature hurt it in the last MOOD_HURT seconds, a
//   creature of the night that fights is within its notice of it (play.hunt_tick goes for
//   the nearest player there), or one of the roster's creatures (the predators, the delves'
//   machines) is fighting within MOOD_NEAR blocks;
// - Underground: it stands in a delve;
// - Calm: none of these.
//
// The director keeps a mood a while after it is no longer stated (client/music), so the
// mood here may come and go with each look.

MOOD_EVERY :: 10 // ticks between looks
MOOD_VICTORY :: 6 // seconds a win is a victory
MOOD_HURT :: 8 // seconds a creature's blow keeps it in danger
MOOD_NEAR :: 20 // blocks: a roster creature fighting this near is a danger

// mood_tick: every player's mood, looked at every MOOD_EVERY ticks and put when it changed.
mood_tick :: proc(s: ^core.Server) {
	if s.tick % MOOD_EVERY != 0 {return}
	danger := make(map[^core.Client]bool, context.temp_allocator)
	for w in s.worlds {mood_dangers(s, w, &danger)}
	for &c in s.clients {
		if c.state != .Playing {continue}
		seat := ruin_seat(s, &c)
		mood := mood_of(s, &c, danger[&c])
		if mood == seat.mood && seat.mood_put {continue}
		seat.mood, seat.mood_put = mood, true
		shown := sandbox.Mood_Record{mood}
		core.game_put(s, &c, &shown)
	}
}

// mood_of: what is happening to c (danger: a creature near goes for it).
mood_of :: proc(s: ^core.Server, c: ^core.Client, danger: bool) -> sandbox.Mood {
	seat := ruin_seat(s, c)
	since :: proc(s: ^core.Server, tick: u64, seconds: u64) -> bool {
		return tick != 0 && s.tick < tick + seconds * game.TICK_RATE
	}
	switch {
	case c.dead:
		return .Calm
	case since(s, seat.won_tick, MOOD_VICTORY):
		return .Victory
	case boss_fighting_any(s, c):
		return .Boss
	case ruin_fighting(s, c) || danger || since(s, seat.hurt_tick, MOOD_HURT):
		return .Danger
	case delve_under(s, c):
		return .Underground
	}
	return .Calm
}

// mood_dangers: the players of w a creature that fights goes for, or might at once.
@(private = "file")
mood_dangers :: proc(s: ^core.Server, w: ^core.World, danger: ^map[^core.Client]bool) {
	any_here := false
	for &c in s.clients {any_here ||= c.state == .Playing && c.world == w}
	if !any_here {return}
	it := core.entities_each(w)
	for h in core.entities_next(&it) {
		kind := core.entity_kind(w, h)
		info := game.kind_info(s.registry, kind)
		a, fights := info.attack.?
		if !fights {continue}
		reach := f64(a.notice)
		if _, wild := wild_of(s, kind); wild {
			cr := creature(s, w, h)
			if cr == nil || cr.mind.state != .Fight {continue}
			reach = MOOD_NEAR
		} else if info.brain != .Steered || ruin_hunted(s, w, h) {continue}
		at := core.entity_pos(w, h)
		for &c in s.clients {
			if c.state != .Playing || c.world != w || !play.prey_fair(s, &c) {continue}
			d := c.player.position - at
			if d.x * d.x + d.y * d.y + d.z * d.z <= reach * reach {danger[&c] = true}
		}
	}
}

// delve_under: c stands in a built delve's box (under its stair head's ground).
@(private = "file")
delve_under :: proc(s: ^core.Server, c: ^core.Client) -> bool {
	if c.world != s.home {return false}
	dv := delves_of(s)
	at := play.block_of(c.player.position)
	for &d in dv.all[:dv.count] {
		if d.built && delve_within(&d, at) && delve_depth_at(&d, at) >= 0 {return true}
	}
	return false
}

// mood_hurt: a creature's blow keeps c in danger a while (the hurt hook).
mood_hurt :: proc(s: ^core.Server, c: ^core.Client, harm: core.Harm) {
	if harm.creature != 0 {ruin_seat(s, c).hurt_tick = max(s.tick, 1)}
}

// mood_won: c won a fight (the ruin's, a custodian's): a victory a while.
mood_won :: proc(s: ^core.Server, c: ^core.Client) {ruin_seat(s, c).won_tick = max(s.tick, 1)}
