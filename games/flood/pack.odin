package flood

import "common:game"

// The game's pack (games/flood/pack, docs/games.md): its two game modes, flood:runner
// (in the round: the kit, no health) and flood:out (watching: flying, unharmed, changing
// nothing). Loaded only where Flood is played.
PACK :: game.Pack_Source {
	namespace = "flood",
	files     = {
		{"pack.json", #load("pack/pack.json")},
		{"data/game_modes/modes.json", #load("pack/data/game_modes/modes.json")},
	},
}

RUNNER_MODE :: "flood:runner"
OUT_MODE :: "flood:out"
