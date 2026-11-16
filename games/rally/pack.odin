package rally

import "common:game"

// The game's pack (games/rally/pack, docs/games.md): the course's blocks and the
// racer's and the watcher's modes. Loaded only where Rally is played.
PACK :: game.Pack_Source {
	namespace = "rally",
	files     = {
		{"pack.json", #load("pack/pack.json")},
		{"data/blocks/rally.json", #load("pack/data/blocks/rally.json")},
		{"data/game_modes/modes.json", #load("pack/data/game_modes/modes.json")},
	},
}

RACER_MODE :: "rally:racer"
WATCHER_MODE :: "rally:watcher"
PAD_BLOCK :: "rally:pad"
GATE_BLOCK :: "rally:gate"
HAZARD_BLOCK :: "rally:hazard"
