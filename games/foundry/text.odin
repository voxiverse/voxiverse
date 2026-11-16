package foundry

import "common:base"

// What Foundry's HUD and panels say, by key (docs/games.md, "What a game's HUD says"): the
// English table, its own. tr formats one ({0}, {1}...: base.text_format).

Text :: enum u8 {
	Status, // {0}: made, {1}: the goal, {2}: the clock, {3}: supply, {4}: demand, {5}: research
	Status_Done, // {0}: the goal, {1}: the time, {2}: supply, {3}: demand
	Research_Line, // {0}: its name, {1}: done, {2}: of
	Research_All,
	Power_Short, // {0}: percent
	Keys, // {0}: craft's key, {1}: turn's key
	Goal_Banner, // {0}: the time
	State_Idle,
	State_Working,
	State_No_Input,
	State_Output_Full,
	State_No_Power,
	State_No_Ore,
	Label, // {0}: the machine, {1}: what it makes, {2}: its state, {3}: progress
	Label_Plain, // {0}: the machine, {1}: its state
	Label_Count, // {0}: the machine, {1}: count
	Panel_Title, // {0}: the machine
	Panel_Making, // {0}: the recipe, {1}: progress, {2}: power
	Panel_Nothing,
	Panel_Holds,
	Panel_Empty,
	Panel_Take,
	Panel_Put,
	Panel_Close,
	Panel_Choose,
	Panel_Study,
	Craft_Title,
	Craft_Needs, // {0}: what it needs
	Craft_Locked, // {0}: the research
	Kind_Miner,
	Kind_Furnace,
	Kind_Assembler,
	Kind_Crate,
	Kind_Arm,
	Kind_Splitter,
	Kind_Generator,
	Kind_Lab,
	Preview, // {0}: the machine, {1}: the way it faces
	Score_Title,
	Score_Crafted,
	Score_Placed,
	Joined, // {0}, {1}: two parts of a list
}

TEXT_EN := [Text]string {
	.Status            = "FOUNDRY  lodestar {0}/{1}  {2}  power {3}/{4} kW  {5}",
	.Status_Done       = "FOUNDRY  {0} lodestar made in {1}  power {2}/{3} kW",
	.Research_Line     = "studying {0} {1}/{2}",
	.Research_All      = "all researched",
	.Power_Short       = "POWER SHORT: machines at {0}%",
	.Keys              = "{0}: craft by hand   {1}: turn what you aim at   use a machine: its panel",
	.Goal_Banner       = "LODESTAR MADE IN {0}",
	.State_Idle        = "idle",
	.State_Working     = "working",
	.State_No_Input    = "waiting for input",
	.State_Output_Full = "output full",
	.State_No_Power    = "no power",
	.State_No_Ore      = "no ore under it",
	.Label             = "{0}: {1} {3}% ({2})",
	.Label_Plain       = "{0} ({1})",
	.Label_Count       = "{0}: {1}",
	.Panel_Title       = "{0}",
	.Panel_Making      = "making {0}: {1}%   power {2}%",
	.Panel_Nothing     = "making nothing",
	.Panel_Holds       = "Holds",
	.Panel_Empty       = "empty",
	.Panel_Take        = "Take output",
	.Panel_Put         = "Put in",
	.Panel_Close       = "Close",
	.Panel_Choose      = "Recipe",
	.Panel_Study       = "Research",
	.Craft_Title       = "Craft by hand",
	.Craft_Needs       = "needs {0}",
	.Craft_Locked      = "after {0}",
	.Kind_Miner        = "Miner",
	.Kind_Furnace      = "Furnace",
	.Kind_Assembler    = "Assembler",
	.Kind_Crate        = "Crate",
	.Kind_Arm          = "Arm",
	.Kind_Splitter     = "Splitter",
	.Kind_Generator    = "Generator",
	.Kind_Lab          = "Lab",
	.Preview           = "{0} facing {1}",
	.Score_Title       = "Foundry",
	.Score_Crafted     = "Crafted",
	.Score_Placed      = "Placed",
	.Joined            = "{0}, {1}",
}

tr :: proc(key: Text, args: ..any) -> string {return base.text_format(TEXT_EN[key], ..args)}

// kind_name: what a machine is called.
kind_name :: proc(k: Kind) -> string {
	switch k {
	case .None:
	case .Miner:
		return tr(.Kind_Miner)
	case .Furnace:
		return tr(.Kind_Furnace)
	case .Assembler:
		return tr(.Kind_Assembler)
	case .Crate:
		return tr(.Kind_Crate)
	case .Arm:
		return tr(.Kind_Arm)
	case .Splitter:
		return tr(.Kind_Splitter)
	case .Generator:
		return tr(.Kind_Generator)
	case .Lab:
		return tr(.Kind_Lab)
	}
	return ""
}

// state_name: what a machine's state is called.
state_name :: proc(s: State) -> string {
	switch s {
	case .Idle:
		return tr(.State_Idle)
	case .Working:
		return tr(.State_Working)
	case .No_Input:
		return tr(.State_No_Input)
	case .Output_Full:
		return tr(.State_Output_Full)
	case .No_Power:
		return tr(.State_No_Power)
	case .No_Ore:
		return tr(.State_No_Ore)
	}
	return ""
}
