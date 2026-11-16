package skirmish

import "common:base"

// What Skirmish's HUD says, by key (docs/games.md, "What a game's HUD says"): the English
// table, its own, so a translation is a table of the same keys beside it and no shared
// file changes. tr formats one ({0}, {1}...: base.text_format).

Text :: enum u8 {
	Unit_Worker,
	Unit_Soldier,
	Unit_Archer,
	Unit_Ram,
	Building_Headquarters,
	Building_Barracks,
	Building_Workshop,
	Building_Tower,
	Building_Depot,
	Resource_Ore,
	Resource_Wood,
	Status_Waiting,
	Status_Playing, // {0}: ore, {1}: wood, {2}: supply, {3}: its cap, {4}: the clock
	Status_Watching, // {0}: the clock
	Status_Results, // {0}: seconds
	Won,
	Lost,
	Side_Wins, // {0}: the side
	Draw,
	Next_Match, // {0}: seconds
	Side_Name, // {0}: the team
	Command_Move,
	Command_Attack_Move,
	Command_Stop,
	Command_Gather,
	Cost_Ore, // {0}: ore
	Cost_Wood, // {0}: wood
	Cost_Both, // {0}: ore, {1}: wood
	Short_Ore, // {0}: ore lacking
	Short_Wood, // {0}: wood lacking
	Short_Both, // {0}: ore, {1}: wood lacking
	Unbuilt,
	Selected_Units, // {0}: how many
	Selected_One, // {0}: what, {1}: health, {2}: most
	Building_Progress, // {0}: what, {1}: percent
	Training, // {0}: the unit, {1}: percent, {2}: queued
	Carrying, // {0}: how much, {1}: of what
	Node_Left, // {0}: what, {1}: how much
	Hint_Commands,
	Hint_Place, // {0}: the building
	Hint_Attack_Move,
	Board_Title, // {0}: the match, {1}: the clock
	Column_Side,
	Column_Units,
	Column_Buildings,
	Column_Killed,
	Column_Wins,
	Computer, // {0}: the side
}

TEXT_EN := [Text]string {
	.Unit_Worker           = "Worker",
	.Unit_Soldier          = "Soldier",
	.Unit_Archer           = "Archer",
	.Unit_Ram              = "Ram",
	.Building_Headquarters = "Headquarters",
	.Building_Barracks     = "Barracks",
	.Building_Workshop     = "Workshop",
	.Building_Tower        = "Tower",
	.Building_Depot        = "Depot",
	.Resource_Ore          = "ore",
	.Resource_Wood         = "wood",
	.Status_Waiting        = "SKIRMISH  the field is being laid out",
	.Status_Playing        = "SKIRMISH   ore {0}   wood {1}   supply {2}/{3}   {4}",
	.Status_Watching       = "SKIRMISH   watching   {0}",
	.Status_Results        = "SKIRMISH   a new match in {0}s",
	.Won                   = "VICTORY",
	.Lost                  = "DEFEAT",
	.Side_Wins             = "{0} WINS",
	.Draw                  = "NOBODY WINS",
	.Next_Match            = "a new match in {0}   (hold P for the sides)",
	.Side_Name             = "Side {0}",
	.Command_Move          = "Move",
	.Command_Attack_Move   = "Attack",
	.Command_Stop          = "Stop",
	.Command_Gather        = "Gather",
	.Cost_Ore              = "({0})",
	.Cost_Wood             = "({0}w)",
	.Cost_Both             = "({0}/{1}w)",
	.Short_Ore             = "short {0}",
	.Short_Wood            = "short {0}w",
	.Short_Both            = "short {0}/{1}w",
	.Unbuilt               = "unbuilt",
	.Selected_Units        = "{0} units",
	.Selected_One          = "{0}  {1}/{2}",
	.Building_Progress     = "{0}: building {1}%",
	.Training              = "training {0} {1}%  (+{2})",
	.Carrying              = "carrying {0} {1}",
	.Node_Left             = "{0}: {1} left",
	.Hint_Commands         = "Left: pick (drag: a box, double: all of a kind)   Right: move, attack, gather   Ctrl+digit: keep a group",
	.Hint_Place            = "Place the {0}: left to build, right to cancel",
	.Hint_Attack_Move      = "Attack: left on the ground or a foe, right to cancel",
	.Board_Title           = "Skirmish: match {0}, {1}",
	.Column_Side           = "Side",
	.Column_Units          = "Units",
	.Column_Buildings      = "Buildings",
	.Column_Killed         = "Killed",
	.Column_Wins           = "Wins",
	.Computer              = "computer ({0})",
}

tr :: proc(key: Text, args: ..any) -> string {return base.text_format(TEXT_EN[key], ..args)}
