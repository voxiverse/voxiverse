package foundry

import "common:game"

// The game's pack (games/foundry/pack, docs/games.md): its ores and machines as blocks, its
// conveyor, its parts as items with their looks, the recipes its machines and its players'
// hands make, and the builder's mode. Loaded only where Foundry is played.
PACK :: game.Pack_Source {
	namespace = "foundry",
	files     = {
		{"pack.json", #load("pack/pack.json")},
		{"data/shapes/foundry.json", #load("pack/data/shapes/foundry.json")},
		{"data/blocks/foundry.json", #load("pack/data/blocks/foundry.json")},
		{"data/items/foundry.json", #load("pack/data/items/foundry.json")},
		{"data/models/foundry.json", #load("pack/data/models/foundry.json")},
		{"data/recipes/foundry.json", #load("pack/data/recipes/foundry.json")},
		{"data/game_modes/modes.json", #load("pack/data/game_modes/modes.json")},
	},
}
