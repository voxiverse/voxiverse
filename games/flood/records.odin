package flood

import "common:protocol"

// What the game replicates besides the engine's kinds (docs/games.md): the round, as the
// server tells each player. It changes once a second while a phase runs (seconds), and
// when something happens; the server puts it every tick and only changes are sent.

Round :: struct {
	phase:     Phase,
	rule:      Rule, // shown only in F3 until the reveal
	result:    Result,
	round:     u16, // 0: none yet
	seed:      u32, // the arena's
	seconds:   u16, // whole seconds into the phase
	countdown: u8, // seconds left to count, in Countdown and Reveal
	level:     i16, // the water's top layer (y)
	goal_x:    i16, // the goal platform's corner (it is GOAL_SIZE square, its top at GOAL_Y)
	goal_z:    i16,
	players:   u8, // in the round
	alive:     u8, // ... not out
	on_goal:   u8, // ... standing on the goal
	made_it:   u8, // at the end
	out:       bool, // this player is out (watching)
	under:     u8, // tenths of a second this player's head has been under water
}

KINDS :: protocol.Game_Kinds {
	states = {{name = "flood.round", value = Round}},
}
