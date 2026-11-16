package stopwatch

import "common:protocol"

// What the game replicates besides the engine's kinds (docs/games.md): its own state
// and event kinds, as data. Both sides name them through KINDS (core.Game.kinds, and
// the client part's), so their schemas, and the hash a client checks, agree.

// Times: a player's own time in the world and the record to beat, in whole seconds;
// the server puts it for each player once a second.
Times :: struct {
	time:   u32, // since the player joined (or reset it)
	record: u32, // the longest stay of a player who left
}

// Record_Broken: a player's stay beat the record as they left; everyone still playing
// is told.
Record_Broken :: struct {
	name:    string `net:"max=16"`,
	seconds: u32,
}

KINDS :: protocol.Game_Kinds {
	states = {{name = "stopwatch.times", value = Times}},
	events = {{name = "stopwatch.record_broken", value = Record_Broken}},
}
