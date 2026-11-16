package delve

import "common:game"

// The game's pack (games/delve/pack, docs/games.md): its blocks (the floor, the walls,
// the way down), its creatures (shaped walkers it steers, their spit, the chest), its
// items (the weapons, potions and coins, with their models) and the delver's mode.
// Loaded only where Delve is played.
PACK :: game.Pack_Source {
	namespace = "delve",
	files     = {
		{"pack.json", #load("pack/pack.json")},
		{"data/blocks/delve.json", #load("pack/data/blocks/delve.json")},
		{"data/entities/foes.json", #load("pack/data/entities/foes.json")},
		{"data/items/delve.json", #load("pack/data/items/delve.json")},
		{"data/models/delve.json", #load("pack/data/models/delve.json")},
		{"data/game_modes/modes.json", #load("pack/data/game_modes/modes.json")},
	},
}
