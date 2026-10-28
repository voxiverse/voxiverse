package sfx

// The Odin table of what blocks sounded like before the registry said so (M47a).

import "../../common/game"

// material_of: what a block sounds like; false for air.
frozen_material_of :: proc(b: game.Block) -> (Material, bool) {
	switch b {
	case .Air, .Water, .Water_1 ..= .Water_7, .Water_Falling, .Gate_Horizon:
		return {}, false
	case .Stone,
	     .Bedrock,
	     .Sandstone,
	     .Coal_Ore,
	     .Iron_Ore,
	     .Copper_Ore,
	     .Cobblestone,
	     .Stone_Bricks,
	     .Gate_Ring,
	     .Gate_Chevron,
	     .Gate_Chevron_Lit:
		return .Stone, true
	case .Dirt, .Clay, .Farmland, .Farmland_Moist:
		return .Dirt, true
	case .Grass, .Leaves, .Spruce_Leaves, .Tall_Grass, .Poppy, .Dandelion, .Wheat_0 ..= .Wheat_7:
		return .Grass, true
	case .Sand:
		return .Sand, true
	case .Gravel:
		return .Gravel, true
	case .Lamp, .Ice, .Glass:
		return .Glass, true
	case .Log, .Spruce_Log, .Cactus, .Planks, .Chest:
		return .Wood, true
	case .Snow, .Wool, .Wool_Black:
		return .Snow, true
	}
	return {}, false
}
