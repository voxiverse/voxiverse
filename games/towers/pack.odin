package towers

import "common:game"

// The game's pack (games/towers/pack, docs/games.md): its blocks (the wall, the two
// towers, the core, the gate, the coin), its three creeps (walkers it steers) and the
// builder's mode. Loaded only where Towers is played.
PACK :: game.Pack_Source {
	namespace = "towers",
	files     = {
		{"pack.json", #load("pack/pack.json")},
		{"data/blocks/towers.json", #load("pack/data/blocks/towers.json")},
		{"data/entities/creeps.json", #load("pack/data/entities/creeps.json")},
		{"data/game_modes/modes.json", #load("pack/data/game_modes/modes.json")},
	},
}

BUILDER_MODE :: "towers:builder"
COIN :: "towers:coin"
CORE_BLOCK :: "towers:core"
GATE_BLOCK :: "towers:gate"
