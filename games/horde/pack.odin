package horde

import "common:game"

// The game's pack (games/horde/pack, docs/games.md): its tuning of the base pack's
// guns (loading its rounds), the shop's and the lairs' blocks, and the survivor's and the
// watcher's modes. Loaded only where Horde is played. Its creatures are the base pack's.
PACK :: game.Pack_Source {
	namespace = "horde",
	files     = {
		{"pack.json", #load("pack/pack.json")},
		{"data/blocks/horde.json", #load("pack/data/blocks/horde.json")},
		{"data/items/horde.json", #load("pack/data/items/horde.json")},
		{"data/models/horde.json", #load("pack/data/models/horde.json")},
		{"data/game_modes/modes.json", #load("pack/data/game_modes/modes.json")},
	},
}

SURVIVOR_MODE :: "horde:survivor"
WATCHER_MODE :: "horde:watcher"
ROUND_ITEM :: "horde:round"
SHOP_BLOCK :: "horde:shop"
LAIR_BLOCK :: "horde:lair"
