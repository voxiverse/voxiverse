package delve

import "common:base"

// What Delve's HUD says, by key (docs/games.md, "What a game's HUD says"): the English
// table, its own, so a translation is a table of the same keys beside it and no shared
// file changes. tr formats one ({0}, {1}...: base.text_format).

Text :: enum u8 {
	Level_Up, // {0}: the level
	Warden_Falls,
	Deeper, // {0}: the depth
	Whirl_Ready,
	Whirl_In, // {0}: seconds
	Rising,
	Creatures, // {0}: how many
	Way_Open,
	Status, // {0}: depth, {1}: where, {2}: level, {3}: potions, {4}: the potion's key, {5}: coins, {6}: the whirl's key, {7}: the whirl
	Coins, // {0}: how many
	Potion,
	Elite, // {0}: its name, {1}: its kind
	Board_Title, // {0}: depth
	Column_Level,
	Column_Kills,
	Column_Deaths,
	Column_Deepest,
	Gained_Coins, // {0}: how many (floating up from the delver)
	Gained_Potion,
}

TEXT_EN := [Text]string {
	.Level_Up       = "LEVEL {0}",
	.Warden_Falls   = "THE WARDEN FALLS: THE WAY DOWN IS OPEN",
	.Deeper         = "DEPTH {0}",
	.Whirl_Ready    = "ready",
	.Whirl_In       = "{0}s",
	.Rising         = "the dungeon rises",
	.Creatures      = "{0} creatures",
	.Way_Open       = "the way down is open",
	.Status         = "DELVE  depth {0}   {1}   level {2}   potions {3} ({4})   coins {5}   whirl ({6}) {7}",
	.Coins          = "{0} coins",
	.Potion         = "potion",
	.Elite          = "{0}, {1}",
	.Board_Title    = "Delve: depth {0}",
	.Column_Level   = "Level",
	.Column_Kills   = "Kills",
	.Column_Deaths  = "Deaths",
	.Column_Deepest = "Deepest",
	.Gained_Coins   = "+{0} coins",
	.Gained_Potion  = "+1 potion",
}

tr :: proc(key: Text, args: ..any) -> string {return base.text_format(TEXT_EN[key], ..args)}
