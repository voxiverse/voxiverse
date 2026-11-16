package sandbox

import "common:game"

// The game's pack (games/sandbox/pack, docs/games.md): its animals, the sheep. Loaded only
// where the sandbox is played.
PACK :: game.Pack_Source {
	namespace = "sandbox",
	files     = {
		{"pack.json", #load("pack/pack.json")},
		{"data/entities/sheep.json", #load("pack/data/entities/sheep.json")},
	},
}
