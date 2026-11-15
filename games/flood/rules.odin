package flood

import "core:math"

import "common:base"
import "common:game"

// Flood: water rises in a walled arena, and the players climb to the glowing platform at
// its top before it reaches them. A head under water for two seconds (or a player outside
// the walls) is out, and watches the rest of the round flying. The round is won when
// everyone still in stands on the platform. Each round runs under one hidden rule, said
// only when it is over: the water rises steadily (Baseline), surges and falls back (Tide),
// crumbles what it wets (Rot), or explosions are huge (Heavy).
//
// This is its shared package: the rules both sides know, the record the server tells
// each player (records.odin) and the game's pack (pack.odin). The server part
// (games/flood/server) runs the rounds; the client part (games/flood/client) shows them.

// INFO: the game's id, name and description, for both of its parts (the launcher
// lists it by them).
INFO :: game.Game_Info {
	id          = "flood",
	name        = "Flood",
	description = "Water rises in a walled arena: climb to the glowing platform before it reaches you.",
}

// The arena: its inside is x and z 0 ..< SIZE, y 0 ..< HEIGHT (the floor at 0), walled
// with bedrock to WALL_TOP.
SIZE :: 32
HEIGHT :: 96
WALL_TOP :: 111 // (the top of chunk layer 6, which the arena keeps loaded)
GOAL_Y :: 88 // the goal platform's top block
GOAL_SIZE :: 7 // its side
WATER_MAX :: GOAL_Y // the water stops here: those on the goal stay dry

SPAWN :: [3]f64{16.5, 1, 16.5}
SPECTATE :: [3]f64{16.5, HEIGHT + 4, 16.5} // where an out player watches from, looking down

// Seconds.
COUNTDOWN :: 4.0 // from the arena built to playing
REVEAL :: 5.0 // the result and the rule shown, before the next round
GRACE :: 8.0 // from playing to the first water
DROWN :: 2.0 // with the head under water (or outside the walls), and a player is out
ROUND_MAX :: 420.0 // the round ends anyway
BUILD_WAIT :: 5.0 // the build waits this long for the arena's chunks, then builds what is there

// Seconds per layer of water, by rule; the tide's surge and the rot's pace.
RISE_BASELINE :: 2.4
RISE_TIDE :: 2.6 // the net rise; the surge goes on top
TIDE_AMPLITUDE :: 7.0 // layers
TIDE_PERIOD :: 30.0
RISE_ROT :: 2.6
ROT_SPLASH :: 2 // layers above the water that count as wet
ROT_DELAY :: 2.5 // from wet to the first block crumbling
ROT_SPREAD :: 5.0 // ... and over how long a layer's blocks go
RISE_HEAVY :: 2.0
HEAVY_SIZE :: 1.75 // the world's explosion_size under Heavy (a rocket's 4 blocks: 7)
HEAVY_THROW :: 2.0 // ... and its explosion_throw

Phase :: enum u8 {
	Waiting, // nobody here
	Countdown, // the arena is being built, then counted down
	Playing,
	Reveal, // over: the result and the rule are shown
}

Rule :: enum u8 {
	Baseline, // the water rises steadily
	Tide, // it surges and falls back, rising overall
	Rot, // what it wets crumbles
	Heavy, // explosions are huge and throw hard
}

RULE_NAMES := [Rule]string {
	.Baseline = "baseline",
	.Tide     = "tide",
	.Rot      = "rot",
	.Heavy    = "heavy",
}

RULE_TITLES := [Rule]string {
	.Baseline = "BASELINE: the water just rose",
	.Tide     = "TIDE: the water surged and fell back",
	.Rot      = "ROT: wet blocks crumbled",
	.Heavy    = "HEAVY BLAST: explosions were huge",
}

Result :: enum u8 {
	None,
	Won, // everyone still in stood on the goal
	Lost, // everyone was out
	Time_Up,
}

// rule_parse: a rule by its name.
rule_parse :: proc(name: string) -> (rule: Rule, ok: bool) {
	for n, r in RULE_NAMES {if n == name {return r, true}}
	return
}

// water_level: the top layer of water the rule wants seconds into play (0: none yet).
water_level :: proc(rule: Rule, seconds: f32) -> i32 {
	if seconds < GRACE {return 0}
	t := seconds - GRACE
	level: f32
	switch rule {
	case .Baseline:
		level = t / RISE_BASELINE
	case .Tide:
		// From the trough, so the first surge comes as a surprise; the second sine
		// makes the surges uneven.
		phase := 2 * math.PI * t / TIDE_PERIOD
		level = t / RISE_TIDE + TIDE_AMPLITUDE * (1 - base.cos(phase)) * 0.5
		level += TIDE_AMPLITUDE * 0.5 * base.sin(phase * 0.5)
	case .Rot:
		level = t / RISE_ROT
	case .Heavy:
		level = t / RISE_HEAVY
	}
	return clamp(i32(level), 0, WATER_MAX)
}
