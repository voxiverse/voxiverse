package towers

import "core:fmt"

import "common:base"
import "common:game"

// Towers: a co-op tower defence. Creeps come out of a gate in waves and walk the
// shortest way to the core at the field's far end; every creep that gets there costs
// lives, and at nought the run is lost. Between and during the waves the players build:
// walls that lengthen the creeps' way (never one that shuts it) and towers that shoot
// the creeps in range by themselves. A kill pays its killer coins (a tower's, its
// builder); walls and towers cost coins, and a block broken again pays half back.
// Surviving the last wave wins; the results stand, and a new run begins on a new
// field.
//
// This is its shared package: the rules both sides know, what the server tells the
// players (records.odin) and the game's pack (pack.odin). The server part
// (games/towers/server) builds the field, runs the waves and the towers; the client part
// (games/towers/client) shows the run, the creeps' health and where a block would go.

// INFO: the game's id, name and description, for both of its parts (its name heads the
// loading screen and the game menu, and names a server's game in Multiplayer).
INFO :: game.Game_Info {
	id          = "towers",
	name        = "Towers",
	description = "Co-op tower defence: wall the creeps' way, let the towers shoot.",
}

// The field: x 0 ..< SIZE_X, z 0 ..< SIZE_Z, its floor the flat world's ground (y -1),
// so everything on it stands in y 0. A bedrock border WALL_HEIGHT high.
SIZE_X :: 48
SIZE_Z :: 32
WALL_HEIGHT :: 3
MID_Z :: SIZE_Z / 2

// GATE: the block a creep comes out at; GOAL: the block in front of the core where it
// arrives. CORE_X: the core's two columns (x CORE_X, CORE_X + 1; z MID_Z - 1, MID_Z).
GATE :: [3]i32{1, 0, MID_Z}
CORE_X :: SIZE_X - 3
GOAL :: [3]i32{CORE_X - 1, 0, MID_Z}

// The ground players may build on: away from the gate and the core.
BUILD_MIN_X :: 4
BUILD_MAX_X :: CORE_X - 3

// buildable: a block may be placed or broken at p (on the floor of the build ground).
buildable :: proc(p: [3]i32) -> bool {
	return p.y == 0 && p.x >= BUILD_MIN_X && p.x <= BUILD_MAX_X && p.z >= 0 && p.z < SIZE_Z
}

// The run's rules: what an admin may change (/towers <name> <value>, from the next run),
// each described once with its bounds (SETTINGS_VARS), kept with the universe.
Settings :: struct {
	coins: int, // each player's at the start of a run
	lives: int,
	waves: int, // the last one survived wins
	build: int, // seconds to build before the first wave
}

@(rodata)
DEFAULT_SETTINGS := Settings {
	coins = 60,
	lives = 20,
	waves = 10,
	build = 20,
}

@(rodata)
SETTINGS_VARS := [?]base.Var {
	{field = "coins", help = "each builder's coins at the start of a run", min = 0, max = 5000},
	{field = "lives", help = "lives the core has", min = 1, max = 500},
	{field = "waves", help = "waves to hold", min = 1, max = 50},
	{field = "build", help = "seconds to build before the first wave", min = 5, max = 600},
}

settings_table :: proc() -> base.Var_Table {
	return {"", Settings, SETTINGS_VARS[:], &DEFAULT_SETTINGS}
}

// Seconds.
BETWEEN :: 10.0 // between waves
RESULTS :: 8.0 // the run's end shown, before the next
SPAWN_EVERY :: 0.8 // between two creeps of a wave
BUILD_WAIT :: 5.0 // the build waits this long for the field's chunks, then builds what is there

Phase :: enum u8 {
	Building, // before a wave: build; the next comes when the time is up
	Wave, // creeps coming: still building
	Results, // the run is over: won or lost
}

Outcome :: enum u8 {
	None,
	Won,
	Lost,
}

// What players build.
Piece :: enum u8 {
	Wall,
	Arrow, // fast and short: one creep at a time
	Cannon, // slow and long: a blast that hurts every creep near where it lands
}

Piece_Info :: struct {
	block:  string, // the pack's block (towers:<block>)
	name:   string,
	price:  int, // coins
	range:  f64, // blocks, from the tower's centre (a wall: 0)
	every:  f64, // seconds between shots
	damage: int,
	splash: f64, // blocks round where a cannon's shot lands
}

@(rodata)
PIECES := [Piece]Piece_Info {
	.Wall = {block = "wall", name = "wall", price = 2},
	.Arrow = {
		block = "arrow_tower",
		name = "arrow tower",
		price = 12,
		range = 7.5,
		every = 0.4,
		damage = 2,
	},
	.Cannon = {
		block = "cannon_tower",
		name = "cannon tower",
		price = 25,
		range = 10,
		every = 2.0,
		damage = 6,
		splash = 2.5,
	},
}

// refund: what breaking a piece pays back (half).
refund :: proc(p: Piece) -> int {return PIECES[p].price / 2}

Creep :: enum u8 {
	Runner, // fast and frail
	Grunt,
	Brute, // slow, tough, and worth three lives at the core
}

Creep_Info :: struct {
	kind:   string, // the pack's entity kind (towers:<kind>)
	bounty: int, // coins for its killer
	lives:  int, // what it costs at the core
}

@(rodata)
CREEPS := [Creep]Creep_Info {
	.Runner = {kind = "runner", bounty = 2, lives = 1},
	.Grunt = {kind = "grunt", bounty = 4, lives = 1},
	.Brute = {kind = "brute", bounty = 10, lives = 3},
}

// Wave_Plan: how many creeps of each kind a wave sends, and how much tougher than its
// kind each is.
Wave_Plan :: struct {
	count:  [Creep]int,
	health: f64, // times the kind's health
}

// wave_plan: wave n (from 1): more runners each wave, grunts from the second, brutes
// from the fourth; each wave's creeps a seventh tougher than the last's.
wave_plan :: proc(n: int) -> Wave_Plan {
	return {
		count = {
			.Runner = 4 + n,
			.Grunt = 2 * (n / 2),
			.Brute = max(n - 3, 0) / 2 + (1 if n >= 4 else 0),
		},
		health = 1 + 0.15 * f64(n - 1),
	}
}

// wave_size: how many creeps wave n sends.
wave_size :: proc(n: int) -> int {
	p := wave_plan(n)
	total := 0
	for c in p.count {total += c}
	return total
}

// WAVE_BONUS: coins every player gets for a wave survived, and more for each wave.
WAVE_BONUS :: 8
WAVE_BONUS_STEP :: 2

coins_text :: proc(n: int) -> string {
	return "1 coin" if n == 1 else fmt.tprintf("%d coins", n)
}
