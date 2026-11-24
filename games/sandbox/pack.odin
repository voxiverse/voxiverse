package sandbox

import "common:game"

// The game's pack (games/sandbox/pack, docs/games.md): its animals, the sheep and the home
// world's other creatures (its wildlife, predators and the remains' machines, with the
// grounds they come on and what they leave), the gate worlds' own creatures, the hours the base pack's hostile creatures
// come out, a block of every material of the kit, the ruined site's altar, ward, rounds
// and the mode its fighters are in, the delves' machines, blocks, finds and recipes, the
// first hour's quests, a survivor's levels and skills, and the camps' people with their
// dialogues and the quests they give. Loaded only where the sandbox is played.
PACK :: game.Pack_Source {
	namespace = "sandbox",
	files     = {
		{"pack.json", #load("pack/pack.json")},
		{"data/entities/sheep.json", #load("pack/data/entities/sheep.json")},
		{"data/entities/hostile.json", #load("pack/data/entities/hostile.json")},
		{"data/entities/wildlife.json", #load("pack/data/entities/wildlife.json")},
		{"data/entities/predators.json", #load("pack/data/entities/predators.json")},
		{"data/entities/machines.json", #load("pack/data/entities/machines.json")},
		{"data/entities/natives.json", #load("pack/data/entities/natives.json")},
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
		{"data/entities/delve.json", #load("pack/data/entities/delve.json")},
		{"data/blocks/delve.json", #load("pack/data/blocks/delve.json")},
		{"data/items/delve.json", #load("pack/data/items/delve.json")},
		{"data/models/delve.json", #load("pack/data/models/delve.json")},
		{"data/recipes/delve.json", #load("pack/data/recipes/delve.json")},
		{"data/quests/first_hour.json", #load("pack/data/quests/first_hour.json")},
		{"data/levels/survivor.json", #load("pack/data/levels/survivor.json")},
		{"data/skills/survivor.json", #load("pack/data/skills/survivor.json")},
		{"data/quests/folk.json", #load("pack/data/quests/folk.json")},
		{"data/quests/gate_worlds.json", #load("pack/data/quests/gate_worlds.json")},
		{"data/item_tags/beyond.json", #load("pack/data/item_tags/beyond.json")},
		{"data/entities/folk.json", #load("pack/data/entities/folk.json")},
		{"data/dialogues/trader.json", #load("pack/data/dialogues/trader.json")},
		{"data/dialogues/mechanic.json", #load("pack/data/dialogues/mechanic.json")},
		{"data/dialogues/medic.json", #load("pack/data/dialogues/medic.json")},
		{"data/dialogues/scout.json", #load("pack/data/dialogues/scout.json")},
		{"data/dialogues/elder.json", #load("pack/data/dialogues/elder.json")},
		{"data/dialogues/guard.json", #load("pack/data/dialogues/guard.json")},
	},
}

ALTAR_BLOCK :: "sandbox:ruin_altar"
WARD_BLOCK :: "sandbox:ruin_ward"
ROUND_ITEM :: "sandbox:round"
ENCOUNTER_MODE :: "sandbox:encounter"
