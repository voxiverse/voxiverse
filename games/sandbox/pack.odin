package sandbox

import "common:game"

// The game's pack (games/sandbox/pack, docs/games.md): its animals, the sheep and the home
// world's other creatures (its wildlife, predators and the remains' machines, with the
// grounds they come on and what they leave), the hours the base pack's hostile creatures
// come out, a block of every material of the kit, and the ruined site's altar, ward, rounds
// and the mode its fighters are in. Loaded only where the sandbox is played.
PACK :: game.Pack_Source {
	namespace = "sandbox",
	files     = {
		{"pack.json", #load("pack/pack.json")},
		{"data/entities/sheep.json", #load("pack/data/entities/sheep.json")},
		{"data/entities/hostile.json", #load("pack/data/entities/hostile.json")},
		{"data/entities/wildlife.json", #load("pack/data/entities/wildlife.json")},
		{"data/entities/predators.json", #load("pack/data/entities/predators.json")},
		{"data/entities/machines.json", #load("pack/data/entities/machines.json")},
		{"data/block_tags/creatures.json", #load("pack/data/block_tags/creatures.json")},
		{"data/items/creature_drops.json", #load("pack/data/items/creature_drops.json")},
		{"data/models/creature_drops.json", #load("pack/data/models/creature_drops.json")},
		{"data/blocks/kit.json", #load("pack/data/blocks/kit.json")},
		{"data/blocks/ruin.json", #load("pack/data/blocks/ruin.json")},
		{"data/items/ruin.json", #load("pack/data/items/ruin.json")},
		{"data/models/ruin.json", #load("pack/data/models/ruin.json")},
		{"data/game_modes/encounter.json", #load("pack/data/game_modes/encounter.json")},
		{"data/game_modes/survival.json", #load("pack/data/game_modes/survival.json")},
		{"data/items/survival.json", #load("pack/data/items/survival.json")},
		{"data/models/survival.json", #load("pack/data/models/survival.json")},
		{"data/blocks/survival.json", #load("pack/data/blocks/survival.json")},
		{"data/recipes/survival.json", #load("pack/data/recipes/survival.json")},
	},
}

ALTAR_BLOCK :: "sandbox:ruin_altar"
WARD_BLOCK :: "sandbox:ruin_ward"
ROUND_ITEM :: "sandbox:round"
ENCOUNTER_MODE :: "sandbox:encounter"
