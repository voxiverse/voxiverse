package towers

import "common:base"

// What Towers' HUD says, by key (docs/games.md, "What a game's HUD says"): the English
// table, its own, so a translation is a table of the same keys beside it and no shared
// file changes. tr formats one ({0}, {1}...: base.text_format).

Text :: enum u8 {
	Wave_Held, // {0}: the wave
	Wave_Sets_Out, // {0}: the wave, {1}: its creeps
	Status_First, // {0}: seconds, {1}: lives, {2}: coins
	Status_Held, // {0}: the wave, {1}: of, {2}: seconds, {3}: lives, {4}: coins
	Status_Wave, // {0}: the wave, {1}: of, {2}: creeps, {3}: to come, {4}: lives, {5}: coins
	Status_Over, // {0}: the run, {1}: seconds
	Gate,
	Core,
	Core_Fallen,
	Core_Stands,
	Your_Part, // {0}: the wave, {1}: of, {2}: kills, {3}: coins spent
	Next_Run, // {0}: seconds
	Prices,
	Piece_Price, // {0}: the piece, {1}: its price
	Board_Title, // {0}: the run, {1}: the wave, {2}: of, {3}: lives
	Column_Kills,
	Column_Coins,
	Column_Spent,
}

TEXT_EN := [Text]string {
	.Wave_Held     = "WAVE {0} HELD",
	.Wave_Sets_Out = "WAVE {0}: {1} CREEPS",
	.Status_First  = "TOWERS  build!  first wave in {0}s   lives {1}   coins {2}",
	.Status_Held   = "TOWERS  wave {0} of {1} held   next in {2}s   lives {3}   coins {4}",
	.Status_Wave   = "TOWERS  wave {0} of {1}   creeps {2} (+{3} to come)   lives {4}   coins {5}",
	.Status_Over   = "TOWERS  run {0} over   next run in {1}s",
	.Gate          = "GATE",
	.Core          = "CORE",
	.Core_Fallen   = "THE CORE HAS FALLEN",
	.Core_Stands   = "THE CORE STANDS",
	.Your_Part     = "wave {0} of {1}   your kills {2}   coins spent {3}",
	.Next_Run      = "a new run in {0}   (hold P for the builders)",
	.Prices        = "walls 2, arrow towers 12, cannons 25: leave the creeps a way",
	.Piece_Price   = "{0}: {1}",
	.Board_Title   = "Towers: run {0}, wave {1} of {2}, {3} lives",
	.Column_Kills  = "Kills",
	.Column_Coins  = "Coins",
	.Column_Spent  = "Spent",
}

tr :: proc(key: Text, args: ..any) -> string {return base.text_format(TEXT_EN[key], ..args)}
