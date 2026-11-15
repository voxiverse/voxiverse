package stopwatch

import "common:game"

// Stopwatch: the smallest game, and the model for the next (docs/games.md). It is
// played in survival: every player's time in the world runs from when they join,
// the longest stay of anyone who left is the record to beat, and /stopwatch tells a
// player their time and the record.
//
// This is its shared package: what both of its sides use. The server part
// (games/stopwatch/server) runs the game.

// seconds: ticks as seconds of play.
seconds :: proc(ticks: u64) -> f64 {return f64(ticks) / game.TICK_RATE}
