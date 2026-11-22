package horde

import "core:fmt"

import "common:base"
import "common:game"

// Horde: co-op wave survival. The survivors stand in a walled yard the game builds from a
// seed; waves of creatures come out of the lairs in its corners and go for the nearest
// survivor: shamblers that close in, skitters in swarms, spitters that keep their
// distance and spit, hulks slow and hard-hitting, and every fifth wave a matriarch with
// them. A kill pays its killer coins; between waves the shop in the middle is open:
// rounds for the guns, a medkit, a better gun. A survivor who goes down watches until the
// wave ends, then stands again. The run ends when every survivor is down at once; the
// best wave reached is kept with the universe.
//
// This is its shared package: the rules both sides know, what the server tells the
// players (records.odin) and the game's pack (pack.odin). The server part
// (games/horde/server) builds the yard, sends the waves and runs the shop; the client
// part (games/horde/client) shows them.

INFO :: game.Game_Info {
	id          = "horde",
	name        = "Horde",
	description = "Co-op wave survival: hold out, buy between waves, last longer.",
}

// The yard: its inside is x and z 0 ..< SIZE, y 0 ..< HEIGHT (the floor at 0), walled
// with bedrock to WALL_TOP.
SIZE :: 36
HEIGHT :: 12
WALL_TOP :: 15 // (the top of chunk layer 0)
MID :: SIZE / 2

// SHOP: the shop's counter, two blocks wide, in the middle; a survivor within SHOP_REACH
// blocks of its middle may buy.
SHOP :: [3]i32{MID - 1, 1, MID - 1}
SHOP_REACH :: 3.5

// LAIRS: where the creatures come out, a corner each.
LAIRS :: [4][2]i32{{2, 2}, {SIZE - 3, 2}, {2, SIZE - 3}, {SIZE - 3, SIZE - 3}}

// Seconds.
COUNTDOWN :: 5.0 // from the yard built to the first wave
SPAWN_EVERY :: 0.5 // between two creatures of a wave
OVER :: 8.0 // the run's end shown, before the next run
BUILD_WAIT :: 5.0 // the build waits this long for the yard's chunks, then builds what is there

Phase :: enum u8 {
	Waiting, // nobody here
	Countdown, // the yard is built and counted down
	Wave, // the creatures come
	Break, // between waves: the shop is open
	Over, // everyone was down: the run's end is shown
}

// Foe: the creatures (the base pack's hostile kinds, which any game may use).
Foe :: enum u8 {
	Shambler, // closes in and strikes
	Skitter, // small and fast, in swarms
	Spitter, // keeps its distance and spits
	Hulk, // slow, tough, strikes hard
	Matriarch, // every fifth wave: strikes near, spits far
}

Foe_Info :: struct {
	kind:   string, // its kind's id
	label:  string,
	bounty: int, // coins for its killer
}

@(rodata)
FOES := [Foe]Foe_Info {
	.Shambler  = {"voxiverse:shambler", "shambler", 3},
	.Skitter   = {"voxiverse:skitter", "skitter", 1},
	.Spitter   = {"voxiverse:spitter", "spitter", 4},
	.Hulk      = {"voxiverse:hulk", "hulk", 10},
	.Matriarch = {"voxiverse:matriarch", "the matriarch", 50},
}


// Wave_Plan: how many creatures of each kind a wave sends, and how much tougher than its
// kind each is.
Wave_Plan :: struct {
	count:  [Foe]int,
	health: f32, // times the kind's health
}

// BOSS_EVERY: a matriarch comes with every wave whose number is a multiple of this.
BOSS_EVERY :: 5

// wave_plan: wave n (from 1): shamblers from the first, a swarm of skitters from the
// second, spitters from the third, hulks from the fourth, more of each as it goes, and
// the matriarch every fifth; each wave's creatures an eighth tougher than the last's.
wave_plan :: proc(n: int) -> Wave_Plan {
	return {
		count = {
			.Shambler = 3 + n,
			.Skitter = 0 if n < 2 else 2 + n,
			.Spitter = 0 if n < 3 else n / 2,
			.Hulk = 0 if n < 4 else (n - 2) / 2,
			.Matriarch = 1 if n % BOSS_EVERY == 0 else 0,
		},
		health = 1 + 0.125 * f32(n - 1),
	}
}

// wave_size: how many creatures wave n sends.
wave_size :: proc(n: int) -> (total: int) {
	for c in wave_plan(n).count {total += c}
	return
}

// What the shop sells (the game's actions, in this order: the client part names them).
Ware :: enum u8 {
	Rounds, // ROUNDS_PACK rounds
	Medkit, // health back
	Gun, // the next gun: a rifle, then a shotgun
}

ROUNDS_PACK :: 30
MEDKIT_HEAL :: 10

@(rodata)
WARE_NAMES := [Ware]string {
	.Rounds = "rounds",
	.Medkit = "medkit",
	.Gun    = "gun",
}

// ACTIONS: the names of the game's actions (its client part's Game.actions).
ACTIONS :: []string{"Buy rounds", "Buy a medkit", "Buy a gun"}

// GUNS: what the shop's Gun sells, in order (a survivor has the pistol already).
GUNS :: [2]string{"voxiverse:rifle", "voxiverse:shotgun"}

// The run's settings: what an admin may change (/horde <name> <value>), kept with the
// universe.
Settings :: struct {
	coins:     int, // each survivor's at the start of a run
	break_for: int, // seconds the shop is open between waves
	rounds:    int, // a pack of rounds' price
	medkit:    int, // a medkit's price
	gun:       int, // the first gun's price (the next costs half again)
}

@(rodata)
DEFAULT_SETTINGS := Settings {
	coins     = 10,
	break_for = 15,
	rounds    = 8,
	medkit    = 12,
	gun       = 40,
}

@(rodata)
SETTINGS_VARS := [?]base.Var {
	{field = "coins", help = "each survivor's coins at the start of a run", min = 0, max = 9999},
	{field = "break_for", help = "seconds the shop is open between waves", min = 3, max = 300},
	{field = "rounds", help = "a pack of rounds' price", min = 0, max = 999},
	{field = "medkit", help = "a medkit's price", min = 0, max = 999},
	{field = "gun", help = "the first gun's price (the next: half again)", min = 0, max = 9999},
}

settings_table :: proc() -> base.Var_Table {
	return {"", Settings, SETTINGS_VARS[:], &DEFAULT_SETTINGS}
}

// price: what a ware costs a survivor who has bought guns guns already.
price :: proc(r: Settings, w: Ware, guns: int) -> int {
	switch w {
	case .Rounds:
		return r.rounds
	case .Medkit:
		return r.medkit
	case .Gun:
		return r.gun + r.gun * guns / 2
	}
	return 0
}

coins_text :: proc(n: int) -> string {
	return "1 coin" if n == 1 else fmt.tprintf("%d coins", n)
}
