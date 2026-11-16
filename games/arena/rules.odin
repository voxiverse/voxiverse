package arena

import "core:fmt"

import "common:game"

// Arena: a free-for-all deathmatch. Everyone spawns with the same kit in a walled
// courtyard of towers, bridges and cover that the game builds from a seed; a frag is
// a kill, and a death by one's own hand or a fall takes one back. The first to the
// frag limit, or the most frags when time runs out, wins the match; the results
// stand a few seconds, and the next match begins in a new courtyard. Before the
// first, a warm-up waits for enough players (one, hosted alone).
//
// This is its shared package: the rules both sides know, what the server tells the
// players (records.odin) and the game's pack (pack.odin). The server part
// (games/arena/server) runs the matches and builds the courtyard; the client part
// (games/arena/client) shows the match, the kill feed and the scoreboard.

// INFO: the game's id, name and description, for both of its parts (the launcher
// lists it by them).
INFO :: game.Game_Info {
	id          = "arena",
	name        = "Arena",
	description = "Free-for-all: the first to the frag limit wins the match.",
}

// The courtyard: its inside is x and z 0 ..< SIZE, y 0 ..< HEIGHT (the floor at 0),
// walled with bedrock to WALL_TOP.
SIZE :: 40
HEIGHT :: 24
WALL_TOP :: 31 // (the top of chunk layer 1, which the game keeps loaded)
SPAWNS :: 8 // spawn points, along the walls

// The match's rules: what an admin may change (/arena), and their bounds.
Settings :: struct {
	frag_limit:    int, // the first to this many wins
	time_limit:    int, // seconds a match lasts at most
	respawn_delay: f32, // seconds from a death to coming back
}

DEFAULT_SETTINGS :: Settings {
	frag_limit    = 15,
	time_limit    = 300,
	respawn_delay = 2,
}

FRAG_LIMIT_MAX :: 200
TIME_LIMIT_MIN :: 30
TIME_LIMIT_MAX :: 3600
RESPAWN_DELAY_MAX :: 30

// Seconds.
COUNTDOWN :: 5.0 // from the courtyard built to the match
RESULTS :: 8.0 // the winner shown, before the next countdown
BUILD_WAIT :: 5.0 // the build waits this long for the courtyard's chunks, then builds what is there
SPAWN_PROTECTION :: 1.5 // a fighter who came back cannot be hurt for this long
FEED_SECONDS :: 6 // a kill stays in the feed this long

Phase :: enum u8 {
	Warmup, // fighting, nothing counted, until enough players are here
	Countdown, // the courtyard is built, everyone watches it, then the match begins
	Playing,
	Results, // over: the winner is shown
}

// players_needed: how many players a match needs: one in a world hosted alone, two
// where others can join (listening).
players_needed :: proc(listening: bool) -> int {return 2 if listening else 1}

// farthest: of points, the one whose nearest of others is farthest (the first such,
// counting from start, so equal choices take turns); with no others, start's.
farthest :: proc(points: [][3]f64, others: [][3]f64, start: int) -> int {
	best, best_d := start % len(points), -1.0
	for k in 0 ..< len(points) {
		i := (start + k) % len(points)
		nearest := max(f64)
		for o in others {
			d := points[i] - o
			nearest = min(nearest, d.x * d.x + d.y * d.y + d.z * d.z)
		}
		if nearest > best_d {best, best_d = i, nearest}
	}
	return best
}

// frags_text: "1 frag", "3 frags", "-1 frags".
frags_text :: proc(n: int) -> string {
	return "1 frag" if n == 1 else fmt.tprintf("%d frags", n)
}
