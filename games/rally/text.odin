package rally

import "common:base"

// What Rally's HUD says, by key (docs/games.md, "What a game's HUD says"): the English
// table, its own, so a translation is a table of the same keys beside it and no shared
// file changes. tr formats one ({0}, {1}...: base.text_format).

Text :: enum u8 {
	Finish,
	Gate, // {0}: the gate
	Split_Compared, // {0}: the gate, {1}: the time, {2}: against the best
	Split, // {0}: the gate, {1}: the time
	Course_Record, // {0}: who, {1}: the time
	Personal_Best, // {0}: the time
	Finished, // {0}: the time
	None,
	Record, // {0}: the time, {1}: who
	Status_Waiting,
	Status_Starting, // {0}: the race, {1}: your best, {2}: the record
	At_Gate, // {0}: the next gate, {1}: of
	Watching,
	Finished_At, // {0}: the time
	Status_Racing, // {0}: the race, {1}: where, {2}: the clock, {3}: your best, {4}: the record
	Status_Over, // {0}: the race, {1}: seconds, {2}: the record
	Race_Title, // {0}: the race
	Rules,
	Race_Over,
	Placing, // {0}: the place, {1}: who, {2}: the time
	No_Finish,
	Next_Race, // {0}: seconds
	Board_Title, // {0}: the race, {1}: the record
	Column_Gate,
	Column_Time,
	Column_Best,
	Column_Resets,
	Done,
	Gate_Of, // {0}: the next gate, {1}: of
}

TEXT_EN := [Text]string {
	.Finish          = "FINISH",
	.Gate            = "GATE {0}",
	.Split_Compared  = "{0}  {1}  {2}",
	.Split           = "{0}  {1}",
	.Course_Record   = "COURSE RECORD: {0} {1}",
	.Personal_Best   = "PERSONAL BEST: {0}",
	.Finished        = "FINISHED: {0}",
	.None            = "-",
	.Record          = "{0} ({1})",
	.Status_Waiting  = "RALLY  waiting for racers",
	.Status_Starting = "RALLY  race {0}   starting   best {1}   record {2}",
	.At_Gate         = "gate {0}/{1}",
	.Watching        = "watching",
	.Finished_At     = "finished {0}",
	.Status_Racing   = "RALLY  race {0}   {1}   {2}   best {3}   record {4}",
	.Status_Over     = "RALLY  race {0} over   next in {1}s   record {2}",
	.Race_Title      = "RACE {0}",
	.Rules           = "Every gate in order. Hook and rockets allowed.",
	.Race_Over       = "RACE OVER",
	.Placing         = "{0}. {1}  {2}",
	.No_Finish       = "did not finish",
	.Next_Race       = "next race in {0}",
	.Board_Title     = "Rally: race {0}, record {1}",
	.Column_Gate     = "Gate",
	.Column_Time     = "Time",
	.Column_Best     = "Best",
	.Column_Resets   = "Resets",
	.Done            = "done",
	.Gate_Of         = "{0}/{1}",
}

tr :: proc(key: Text, args: ..any) -> string {return base.text_format(TEXT_EN[key], ..args)}
