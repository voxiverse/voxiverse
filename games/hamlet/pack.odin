package hamlet

import "common:game"

// The game's pack (games/hamlet/pack, docs/games.md): the planner's mode (no body: a
// camera over the village) and the citizen. Loaded only where Hamlet is played.
PACK :: game.Pack_Source {
	namespace = "hamlet",
	files     = {
		{"pack.json", #load("pack/pack.json")},
		{"data/entities/citizens.json", #load("pack/data/entities/citizens.json")},
		{"data/game_modes/modes.json", #load("pack/data/game_modes/modes.json")},
	},
}
