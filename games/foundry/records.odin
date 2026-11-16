package foundry

import "common:game"
import "common:protocol"

// What Foundry tells its players besides the engine's kinds (docs/games.md), and what they
// ask of it. Items on belts are the engine's (its belts); what a machine shows is the
// machine's record (Shown, core.machine_show), sent to whoever has its chunk.

// Status: the factory as everyone sees it.
Status :: struct {
	goal:     u16, // lodestars to make
	made:     u16, // ... made so far
	seconds:  u32, // since the factory began (stopped when the goal was reached)
	done:     bool, // the goal was reached
	studying: Research,
	studied:  u8, // bit r: research r is done
	progress: u16, // units of the research under study done
	supply:   u32, // kW the generators give, over every part of the grid
	demand:   u32, // kW the machines ask
	parts:    u16, // parts of the grid with a generator or a machine on them
}

// Shown: what a machine shows (Game.machine_shown: at most 16 bytes).
Shown :: struct {
	kind:     Kind,
	state:    State,
	recipe:   u16, // its recipe's index in the registry, plus one (0: none)
	progress: u8, // percent of what it is making
	power:    u8, // percent of what it asks that it gets
	count:    u16, // what it holds that its label says (a crate's items, a generator's fuel)
}

// Panel: the machine a player has open (key: none; only that player is told).
Panel :: struct {
	at:       [3]i32,
	kind:     Kind,
	state:    State,
	recipe:   u16, // registry index plus one (0: none)
	progress: u8,
	power:    u8,
	slots:    [12]game.Stack,
	count:    u8, // slots used
	open:     bool, // false: no panel
}

// Builder (key: the player): what each player built and made, for the scoreboard.
Builder :: struct {
	name:    string `net:"max=16"`,
	crafted: u32, // items made by hand
	placed:  u32, // machines and belts placed
}

// Panel_Open: the player's use of a machine opened its panel (its client part shows it).
Panel_Open :: struct {
	at: [3]i32,
}

// Goal_Reached: the factory made its goal, in this time.
Goal_Reached :: struct {
	seconds: u32,
}

// ---- the requests (the client part's game_request; the server judges each) ----

// Choose: the recipe an assembler makes (registry index plus one; 0: none), or the
// research a lab studies (recipe: its Research plus one).
Choose :: struct {
	at:     [3]i32,
	recipe: u16,
}

// Take: everything a machine made (its output) into the player's pockets.
Take :: struct {
	at: [3]i32,
}

// Put: what the player carries that the machine takes, into it.
Put :: struct {
	at: [3]i32,
}

// Craft: one of a hand recipe (registry index), from what the player carries.
Craft :: struct {
	recipe: u16,
}

// Turn: the machine or belt at `at` a quarter turn clockwise.
Turn :: struct {
	at: [3]i32,
}

// Close: the player closed its panel.
Close :: struct {
	at: [3]i32, // the machine it had open
}

KINDS :: protocol.Game_Kinds {
	states   = {
		{name = "foundry.status", value = Status},
		{name = "foundry.panel", value = Panel},
		{name = "foundry.builder", value = Builder, key = .Player, max_records = 64},
	},
	events   = {
		{name = "foundry.panel_open", value = Panel_Open},
		{name = "foundry.goal_reached", value = Goal_Reached},
	},
	requests = {
		{name = "foundry.choose", value = Choose},
		{name = "foundry.take", value = Take},
		{name = "foundry.put", value = Put},
		{name = "foundry.craft", value = Craft},
		{name = "foundry.turn", value = Turn},
		{name = "foundry.close", value = Close},
	},
}
