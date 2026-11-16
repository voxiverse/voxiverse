package flood

import "common:base"

// What Flood's HUD says, by key (docs/games.md, "What a game's HUD says"): the English
// table, its own, so a translation is a table of the same keys beside it and no shared
// file changes. tr formats one ({0}, {1}...: base.text_format).

Text :: enum u8 {
	Status_Waiting,
	Status_Starting, // {0}: the round
	Status_Playing, // {0}: the round, {1}: the clock, {2}: the water's y, {3}: yours, {4}: the goal's, {5}: alive, {6}: in the round, {7}: on the goal
	Status_Over, // {0}: the round
	Round_Title, // {0}: the round
	Round_Goal,
	Watching,
	Drowning, // {0}: seconds under, tenths
	Water_In, // {0}: seconds
	Result_Over,
	Result_Won,
	Result_Lost,
	Result_Time_Up,
	Made_It, // {0}: how many, {1}: of how many
	Rule_Was,
	Next_Round, // {0}: seconds
	Rule_Baseline, // the rules' titles, in Rule's order
	Rule_Tide,
	Rule_Rot,
	Rule_Heavy,
}

@(rodata)
TEXT_EN := [Text]string {
	.Status_Waiting  = "FLOOD  waiting for players",
	.Status_Starting = "FLOOD  round {0}  starting",
	.Status_Playing  = "FLOOD  round {0}   {1}   water y={2}   you y={3}   goal y={4}   alive {5}/{6}   on goal {7}",
	.Status_Over     = "FLOOD  round {0} over",
	.Round_Title     = "ROUND {0}",
	.Round_Goal      = "Reach the glowing platform. Something is different.",
	.Watching        = "WATCHING: out of this round (fly)",
	.Drowning        = "DROWNING {0}",
	.Water_In        = "Water in {0}",
	.Result_Over     = "ROUND OVER",
	.Result_Won      = "ROUND WON",
	.Result_Lost     = "EVERYONE DROWNED",
	.Result_Time_Up  = "TIME UP",
	.Made_It         = "{0} of {1} made it",
	.Rule_Was        = "The rule was",
	.Next_Round      = "next round in {0}",
	.Rule_Baseline   = "BASELINE: THE WATER JUST ROSE",
	.Rule_Tide       = "TIDE: THE WATER SURGED AND FELL BACK",
	.Rule_Rot        = "ROT: WET BLOCKS CRUMBLED",
	.Rule_Heavy      = "HEAVY BLAST: EXPLOSIONS WERE HUGE",
}

// tr: the text of key, its arguments in place (temp memory).
tr :: proc(key: Text, args: ..any) -> string {return base.text_format(TEXT_EN[key], ..args)}

// rule_title: what the reveal calls a rule.
rule_title :: proc(r: Rule) -> string {return tr(Text(int(Text.Rule_Baseline) + int(r)))}
