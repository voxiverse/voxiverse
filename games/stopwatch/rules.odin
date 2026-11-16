package stopwatch

import "common:game"

// Stopwatch: the smallest game, and the model for the next (docs/games.md). It is
// played in survival: every player's time in the world runs from when they join,
// the longest stay of anyone who left is the record to beat (kept with the
// universe), and /stopwatch tells a player their time and the record.
//
// This is its shared package: what both of its sides use, its records among them
// (records.odin). The server part (games/stopwatch/server) runs the game; the client
// part (games/stopwatch/client) shows a player their time.

// INFO: the game's id, name and description, for both of its parts (the launcher
// lists it by them).
INFO :: game.Game_Info {
	id          = "stopwatch",
	name        = "Stopwatch",
	description = "Stay as long as you can: the longest stay is the record.",
}

// seconds: ticks as seconds of play.
seconds :: proc(ticks: u64) -> f64 {return f64(ticks) / game.TICK_RATE}
