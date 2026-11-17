package arena

import "common:base"

// What Arena's HUD says, by key (docs/games.md, "What a game's HUD says"): the English
// table, its own, so a translation is a table of the same keys beside it and no shared
// file changes. tr formats one ({0}, {1}...: base.text_format).

Text :: enum u8 {
	Feed_Self, // {0}: how, {1}: the victim
	Feed_Kill, // {0}: the killer, {1}: how, {2}: the victim
	Status_Waiting, // {0}: players, {1}: needed
	Status_Warmup,
	Status_Starting, // {0}: the match
	Leader, // {0}: the leader, {1}: frags
	Status_Playing, // {0}: the match, {1}: the clock, {2}: your frags, {3}: the leader, {4}: the limit
	Status_Over, // {0}: the match
	Match_Title, // {0}: the match
	Rules, // {0}: the limit
	Draw,
	Wins, // {0}: the winner
	Next_Match, // {0}: seconds
	Board_Warmup,
	Board_Playing, // {0}: the match, {1}: the limit, {2}: the clock
	Board_Over, // {0}: the match
	Column_Frags,
	Column_Deaths,
	Frag, // a frag of yours, under the crosshair
}

TEXT_EN := [Text]string {
	.Feed_Self       = "[{0}] {1}",
	.Feed_Kill       = "{0} [{1}] {2}",
	.Status_Waiting  = "ARENA  warm-up: waiting for players ({0} of {1})",
	.Status_Warmup   = "ARENA  warm-up",
	.Status_Starting = "ARENA  match {0}  starting",
	.Leader          = "{0} {1}",
	.Status_Playing  = "ARENA  match {0}   {1} left   you {2}   leader {3}   first to {4}",
	.Status_Over     = "ARENA  match {0} over",
	.Match_Title     = "MATCH {0}",
	.Rules           = "First to {0} frags. Every kill counts; your own death costs one.",
	.Draw            = "DRAW",
	.Wins            = "{0} WINS",
	.Next_Match      = "next match in {0}   (hold P for the scores)",
	.Board_Warmup    = "Arena: warm-up (nothing counts)",
	.Board_Playing   = "Arena: match {0}, first to {1}, {2} left",
	.Board_Over      = "Arena: match {0} is over",
	.Column_Frags    = "Frags",
	.Column_Deaths   = "Deaths",
	.Frag            = "+1 FRAG",
}

tr :: proc(key: Text, args: ..any) -> string {return base.text_format(TEXT_EN[key], ..args)}
