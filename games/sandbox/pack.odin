package sandbox

import "common:game"

// The game's pack (games/sandbox/pack, docs/games.md): its animals, the sheep, and a block
// of every material of the kit. Loaded only where the sandbox is played.
PACK :: game.Pack_Source {
	namespace = "sandbox",
	files     = {
		{"pack.json", #load("pack/pack.json")},
		{"data/entities/sheep.json", #load("pack/data/entities/sheep.json")},
		{"data/blocks/kit.json", #load("pack/data/blocks/kit.json")},
	},
}
