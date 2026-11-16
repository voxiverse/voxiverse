package foundry

import "common:base"
import "common:game"

// Foundry: a factory built together, first by hand, then by machines: miners on ore patches,
// conveyors, arms between them and the furnaces and assemblers, generators and poles to power
// them, labs that learn new recipes; the goal is a lodestar, made at the end of a chain four
// steps deep. Both parts read these rules; the server decides.

INFO :: game.Game_Info {
	id          = "foundry",
	name        = "Foundry",
	description = "Build a factory together, make a lodestar.",
}

MODE :: "foundry:builder"

// The map: a square of flat ground, its ores, rocks, trees and a pond from the seed.
MAP :: 96 // blocks a side, from 0
GROUND :: -1 // the flat world's top
SPAWN :: [3]f64{48.5, 0, 48.5}

// Kind: what a machine is (its block, "foundry:<name>").
Kind :: enum u8 {
	None,
	Miner,
	Furnace,
	Assembler,
	Crate,
	Arm,
	Splitter,
	Generator,
	Lab,
}

KIND_BLOCKS := [Kind]string {
	.None      = "",
	.Miner     = "foundry:miner",
	.Furnace   = "foundry:furnace",
	.Assembler = "foundry:assembler",
	.Crate     = "foundry:crate",
	.Arm       = "foundry:arm",
	.Splitter  = "foundry:splitter",
	.Generator = "foundry:generator",
	.Lab       = "foundry:lab",
}

BELT_BLOCK :: "foundry:belt"
POLE_BLOCK :: "foundry:pole"
ORES := [3]string{"foundry:ember_ore", "foundry:tide_ore", "foundry:peat"}
FUEL :: "foundry:peat"
GOAL_ITEM :: "foundry:lodestar"
INSIGHT :: "foundry:insight"
THEORY :: "foundry:theory"

// The recipes' machines (game.Recipe_Def.machine).
BY_FURNACE :: "foundry:furnace"
BY_ASSEMBLER :: "foundry:assembler"
BY_HAND :: "foundry:hand"

// Power, in kilowatts: what a burning generator gives, what each machine draws while it
// works. A part of the grid short of power runs its machines slower, in proportion; one with
// none stops them.
GENERATOR_KW :: 900
DRAW_KW := [Kind]u32 {
	.None      = 0,
	.Miner     = 90,
	.Furnace   = 90,
	.Assembler = 150,
	.Crate     = 0,
	.Arm       = 15,
	.Splitter  = 0,
	.Generator = 0,
	.Lab       = 60,
}
POLE_REACH :: 5 // blocks a pole reaches each way (machines, other poles)
FUEL_SECONDS :: 12 // a peat burns this long in a generator at full load

THINK :: 10 // ticks between a machine's thinks
MINE_SECONDS :: 2.0 // a miner's time for an ore at full power
LAB_SECONDS :: 3.0 // a lab's time for a unit of research
STACK :: 50 // a machine slot holds at most this many
INPUT_ROOM :: 2 // an assembler takes up to this many rounds of a recipe's inputs

// State: what a machine is doing, as its label says.
State :: enum u8 {
	Idle, // nothing to do (no recipe, nothing in)
	Working,
	No_Input,
	Output_Full,
	No_Power,
	No_Ore, // a miner off any ore
}

// Research: what the labs learn, in order of the tree; each unlocks recipes.
Research :: enum u8 {
	Assembly,
	Circuits,
	Frames,
	Splitting,
	Optics,
	Theory,
	Rotors,
	Lodestar,
}

Research_Info :: struct {
	name:    string,
	insight: u16, // units of insight it takes
	theory:  u16, // ... and of theory
	needs:   bit_set[Research],
	unlocks: []string, // recipe ids
}

RESEARCH := [Research]Research_Info {
	.Assembly  = {"Assembly", 10, 0, {}, {"foundry:assembler"}},
	.Circuits  = {"Circuits", 15, 0, {.Assembly}, {"foundry:circuit"}},
	.Frames    = {"Frames", 20, 0, {.Assembly}, {"foundry:frame"}},
	.Splitting = {"Splitting", 15, 0, {.Circuits}, {"foundry:splitter"}},
	.Optics    = {"Optics", 25, 0, {.Circuits}, {"foundry:melt_lens"}},
	.Theory    = {"Theory", 30, 0, {.Optics}, {"foundry:theory"}},
	.Rotors    = {"Rotors", 20, 20, {.Frames, .Theory}, {"foundry:rotor"}},
	.Lodestar  = {"Lodestar", 40, 40, {.Rotors}, {"foundry:lodestar"}},
}

// recipe_locked: the research that unlocks a recipe, if one does (false: always open).
recipe_locked :: proc(id: string) -> (Research, bool) {
	for info, r in RESEARCH {
		for u in info.unlocks {if u == id {return r, true}}
	}
	return {}, false
}

// recipe_open: a recipe may be made, given what is researched.
recipe_open :: proc(id: string, done: bit_set[Research]) -> bool {
	r, locked := recipe_locked(id)
	return !locked || r in done
}

// facing_turn: a facing (an index into game.ROTATE_VALUES) a quarter turn clockwise.
facing_turn :: proc(facing: int) -> int {return (facing + 1) % 4}

// side_of: the way a quarter turn clockwise from dir (north to east).
side_of :: proc(dir: game.Block_Pos) -> game.Block_Pos {return {-dir.z, 0, dir.x}}

// Settings: the admin's (`/foundry set <name> <value>`), each described once with its
// bounds, kept with the universe.
Settings :: struct {
	goal: int, // lodestars to make
}

@(rodata)
DEFAULT_SETTINGS := Settings {
	goal = 1,
}

@(rodata)
SETTINGS_VARS := [?]base.Var {
	{field = "goal", help = "lodestars the factory makes to reach its goal", min = 1, max = 20},
}

settings_table :: proc() -> base.Var_Table {
	return {"", Settings, SETTINGS_VARS[:], &DEFAULT_SETTINGS}
}
