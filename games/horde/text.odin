package horde

import "common:base"

// What Horde's HUD says, by key (docs/games.md, "What a game's HUD says"): the English
// table, its own, so a translation is a table of the same keys beside it and no shared
// file changes. tr formats one ({0}, {1}...: base.text_format).

Text :: enum u8 {
	Wave_Held, // {0}: the wave
	Wave_Boss, // {0}: the wave
	Wave_Sets_Out, // {0}: the wave, {1}: creatures
	Status_Waiting,
	Status_Countdown, // {0}: the run, {1}: seconds, {2}: coins, {3}: best
	Status_Wave, // {0}: the wave, {1}: creatures, {2}: to come, {3}: standing, {4}: of, {5}: coins, {6}: rounds, {7}: best
	Status_Break, // {0}: the wave, {1}: seconds, {2}: coins, {3}: rounds, {4}: best
	Status_Over, // {0}: the run, {1}: seconds, {2}: best
	Shop,
	Shop_Closed,
	Run_Title, // {0}: the run
	Rules,
	Down,
	Horde_Wins,
	Held, // {0}: waves held, {1}: best
	Next_Run, // {0}: seconds
	Shop_Open, // {0}: seconds
	Wares, // {0}..{2}: the keys of rounds, a medkit and a gun; {3}..{5}: their prices
	Board_Title, // {0}: the run, {1}: the wave, {2}: best
	Column_Kills,
	Column_Coins,
	Column_Downs,
	Is_Down,
	Bounty, // {0}: coins a kill paid (floating over it)
	Spent, // {0}: coins a purchase cost (floating over the counter)
}

TEXT_EN := [Text]string {
	.Wave_Held        = "WAVE {0} HELD: THE SHOP IS OPEN",
	.Wave_Boss        = "WAVE {0}: THE MATRIARCH COMES",
	.Wave_Sets_Out    = "WAVE {0}: {1} CREATURES",
	.Status_Waiting   = "HORDE  waiting for survivors",
	.Status_Countdown = "HORDE  run {0}   the first wave in {1}s   coins {2}   best {3}",
	.Status_Wave      = "HORDE  wave {0}   creatures {1} (+{2})   standing {3}/{4}   coins {5}   rounds {6}   best {7}",
	.Status_Break     = "HORDE  wave {0} held   next in {1}s   coins {2}   rounds {3}   best {4}",
	.Status_Over      = "HORDE  run {0} over   next run in {1}s   best {2}",
	.Shop             = "SHOP",
	.Shop_Closed      = "SHOP (closed)",
	.Run_Title        = "RUN {0}",
	.Rules            = "Hold out. Creatures come from the corners.",
	.Down             = "DOWN: watching until the wave ends",
	.Horde_Wins       = "THE HORDE WINS",
	.Held             = "{0} waves held   best {1}",
	.Next_Run         = "a new run in {0}   (hold P for the survivors)",
	.Shop_Open        = "THE SHOP IS OPEN: {0}s",
	.Wares            = "at the counter:  {0} rounds ({3})   {1} medkit ({4})   {2} gun ({5})",
	.Board_Title      = "Horde: run {0}, wave {1}, best {2}",
	.Column_Kills     = "Kills",
	.Column_Coins     = "Coins",
	.Column_Downs     = "Downs",
	.Is_Down          = "down",
	.Bounty           = "+{0}",
	.Spent            = "-{0}",
}

tr :: proc(key: Text, args: ..any) -> string {return base.text_format(TEXT_EN[key], ..args)}
