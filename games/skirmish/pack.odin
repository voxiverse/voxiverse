package skirmish

import "common:game"

// The game's pack (games/skirmish/pack, docs/games.md): the commander's mode (no body: a
// camera over the field), the units, the buildings' flags and the resources. Loaded only
// where Skirmish is played.
PACK :: game.Pack_Source {
	namespace = "skirmish",
	files     = {
		{"pack.json", #load("pack/pack.json")},
		{"data/entities/skirmish.json", #load("pack/data/entities/skirmish.json")},
		{"data/game_modes/modes.json", #load("pack/data/game_modes/modes.json")},
	},
}
