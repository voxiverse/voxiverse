package rally

import "common:game"
import "common:protocol"

// What the game replicates besides the engine's kinds (docs/games.md): the race (a
// singleton), every racer's progress (keyed by player id, put to every player: the
// scoreboard), a racer's split as it passes a gate (to it alone), and a finish (to all).

Race :: struct {
	phase:       Phase,
	race:        u16,
	seed:        u32, // the course's
	left:        u16, // seconds of the countdown or the results left
	ticks:       u32, // the race's clock
	record:      u32, // the course record's time (0: none yet)
	record_name: string `net:"max=16"`,
	racers:      u8,
	finished:    u8,
}

Racer :: struct {
	name:   string `net:"max=16"`,
	next:   u8, // the checkpoint it makes for (CHECKPOINTS + 1: finished)
	time:   u32, // its finish's ticks (0: not finished)
	best:   u32, // its personal best (0: none)
	racing: bool, // in this race (else watching)
	resets: u16, // times sent back this race
}

// Split: the racer passed gate `checkpoint` at `ticks`; `delta` against its best run's
// split there (`compared` false: no best to compare).
Split :: struct {
	checkpoint: u8,
	ticks:      u32,
	delta:      i32,
	compared:   bool,
}

// Finish: a racer finished.
Finish :: struct {
	name:     string `net:"max=16"`,
	ticks:    u32,
	personal: bool, // a personal best
	record:   bool, // a course record
}

KINDS :: protocol.Game_Kinds {
	states = {
		{name = "rally.race", value = Race},
		{name = "rally.racer", value = Racer, key = .Player, max_records = game.MAX_PLAYERS},
	},
	events = {{name = "rally.split", value = Split}, {name = "rally.finish", value = Finish}},
}
