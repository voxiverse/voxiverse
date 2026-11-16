package towers

import "common:game"
import "common:protocol"

// What the game replicates besides the engine's kinds (docs/games.md): the run (a
// singleton, the same for everyone), every builder's purse and tally (keyed by player
// id, put to every player, so the scoreboard is whole on each side), a wave as it starts
// or ends, and each tower's shot as it is fired.

Run :: struct {
	phase:   Phase,
	outcome: Outcome, // Results: won or lost
	run:     u16, // runs begun since the server started
	wave:    u8, // the wave on now, or the last one (0: none yet)
	waves:   u8, // the last
	lives:   i16,
	left:    u16, // seconds left of the phase (Building: to the next wave; Results: to the next run)
	alive:   u16, // creeps on the field
	to_come: u16, // creeps of this wave still to come out of the gate
	seed:    u32, // the field's
}

// Builder: a player's purse and tally in the run (the key is its player id).
Builder :: struct {
	name:  string `net:"max=16"`,
	coins: u32,
	kills: u32,
	spent: u32, // coins put into walls and towers (less what was paid back)
}

// Wave: a wave begins (or was survived: done).
Wave :: struct {
	wave: u8,
	done: bool,
	size: u16, // its creeps
}

// Shot: a tower fired from its top at where its shot landed (a cannon's blast is
// there).
Shot :: struct {
	from, to: [3]f32,
	piece:    Piece,
}

KINDS :: protocol.Game_Kinds {
	states = {
		{name = "towers.run", value = Run},
		{name = "towers.builder", value = Builder, key = .Player, max_records = game.MAX_PLAYERS},
	},
	events = {{name = "towers.wave", value = Wave}, {name = "towers.shot", value = Shot}},
}
