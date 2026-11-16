package arena

import "common:game"

// What the game replicates besides the engine's kinds (docs/games.md): the match (a
// singleton, the same for everyone), every fighter's score (keyed by player id, put to
// every player, so the scoreboard is whole on each side) and a kill as it happens.

Match :: struct {
	phase:      Phase,
	match:      u16, // 0: none yet (warm-up)
	seed:       u32, // the courtyard's
	seconds:    u16, // whole seconds into the phase
	left:       u16, // seconds left of it: the match's time, the countdown's, the results'
	frag_limit: u16,
	time_limit: u16, // seconds
	players:    u8, // fighting here
	needed:     u8, // to start a match
	winner:     string `net:"max=16"`, // Results: who won ("": a draw)
	top_frags:  i16, // Results: the winner's frags
}

// Score: a fighter's frags and deaths in this match (the key is its player id).
Score :: struct {
	name:   string `net:"max=16"`,
	frags:  i16,
	deaths: u16,
}

// Kill: a line of the kill feed: who killed whom and how (by: "" for nobody: a fall,
// or the victim's own blast).
Kill :: struct {
	by:     string `net:"max=16"`,
	victim: string `net:"max=16"`,
	kind:   game.Source_Kind,
	weapon: string `net:"max=24"`, // a shot's weapon ("": none)
}

KINDS :: game.Game_Kinds {
	states = {
		{name = "arena.match", value = Match},
		{name = "arena.score", value = Score, key = .Player, max_records = game.MAX_PLAYERS},
	},
	events = {{name = "arena.kill", value = Kill}},
}

// how: a kill's means, as the feed shows it.
how :: proc(k: Kill) -> string {
	if k.weapon != "" {return k.weapon}
	#partial switch k.kind {
	case .Explosion:
		return "rocket"
	case .Fall:
		return "fall"
	case .Void:
		return "void"
	}
	return "?"
}
