package mesh

// Frozen copies of how the Odin tables drew blocks before the registry did
// (M47a): test_base_looks_the_same compares the base pack against them.

import "../../common/game"

// block_faces: a block's side, top and bottom textures (a switch, so a new
// block does not compile until it has its look).
frozen_block_faces :: proc(b: game.Block) -> (side, top, bottom: Texture_Generator) {
	switch b {
	case .Air:
		return
	case .Stone:
		return .Stone, .Stone, .Stone
	case .Dirt:
		return .Dirt, .Dirt, .Dirt
	case .Grass:
		return .Grass_Side, .Grass_Top, .Dirt
	case .Sand:
		return .Sand, .Sand, .Sand
	case .Gravel:
		return .Gravel, .Gravel, .Gravel
	case .Bedrock:
		return .Bedrock, .Bedrock, .Bedrock
	case .Lamp:
		return .Lamp, .Lamp, .Lamp
	case .Water, .Water_1 ..= .Water_7, .Water_Falling:
		return .Water, .Water, .Water
	case .Snow:
		return .Snow, .Snow, .Snow
	case .Ice:
		return .Ice, .Ice, .Ice
	case .Clay:
		return .Clay, .Clay, .Clay
	case .Sandstone:
		return .Sandstone_Side, .Sandstone_Top, .Sandstone_Top
	case .Log:
		return .Log_Side, .Log_Top, .Log_Top
	case .Leaves:
		return .Leaves, .Leaves, .Leaves
	case .Spruce_Log:
		return .Spruce_Log_Side, .Log_Top, .Log_Top
	case .Spruce_Leaves:
		return .Spruce_Leaves, .Spruce_Leaves, .Spruce_Leaves
	case .Coal_Ore:
		return .Coal_Ore, .Coal_Ore, .Coal_Ore
	case .Iron_Ore:
		return .Iron_Ore, .Iron_Ore, .Iron_Ore
	case .Copper_Ore:
		return .Copper_Ore, .Copper_Ore, .Copper_Ore
	case .Tall_Grass:
		return .Tall_Grass, .Tall_Grass, .Tall_Grass
	case .Poppy:
		return .Poppy, .Poppy, .Poppy
	case .Dandelion:
		return .Dandelion, .Dandelion, .Dandelion
	case .Cactus:
		return .Cactus_Side, .Cactus_Top, .Cactus_Top
	case .Cobblestone:
		return .Cobblestone, .Cobblestone, .Cobblestone
	case .Stone_Bricks:
		return .Stone_Bricks, .Stone_Bricks, .Stone_Bricks
	case .Planks:
		return .Planks, .Planks, .Planks
	case .Glass:
		return .Glass, .Glass, .Glass
	case .Gate_Ring:
		return .Gate_Ring, .Gate_Ring, .Gate_Ring
	case .Gate_Chevron:
		return .Gate_Chevron, .Gate_Ring, .Gate_Ring
	case .Gate_Chevron_Lit:
		return .Gate_Chevron_Lit, .Gate_Ring, .Gate_Ring
	case .Gate_Horizon:
		return .Gate_Horizon, .Gate_Horizon, .Gate_Horizon
	case .Wool:
		return .Wool, .Wool, .Wool
	case .Farmland:
		return .Dirt, .Farmland_Top, .Dirt
	case .Farmland_Moist:
		return .Dirt, .Farmland_Moist_Top, .Dirt
	case .Wheat_0:
		return .Wheat_0, .Wheat_0, .Wheat_0
	case .Wheat_1:
		return .Wheat_1, .Wheat_1, .Wheat_1
	case .Wheat_2:
		return .Wheat_2, .Wheat_2, .Wheat_2
	case .Wheat_3:
		return .Wheat_3, .Wheat_3, .Wheat_3
	case .Wheat_4:
		return .Wheat_4, .Wheat_4, .Wheat_4
	case .Wheat_5:
		return .Wheat_5, .Wheat_5, .Wheat_5
	case .Wheat_6:
		return .Wheat_6, .Wheat_6, .Wheat_6
	case .Wheat_7:
		return .Wheat_7, .Wheat_7, .Wheat_7
	case .Wool_Black:
		return .Wool_Black, .Wool_Black, .Wool_Black
	case .Chest:
		return .Chest_Side, .Chest_Top, .Chest_Top
	}
	return
}

// block_shape: how a block is drawn (a switch, so a new block does not
// compile until it says).
frozen_block_shape :: proc(b: game.Block) -> (Shape, Layer) {
	switch b {
	case .Air:
		return .None, .Opaque
	case .Stone,
	     .Dirt,
	     .Grass,
	     .Sand,
	     .Gravel,
	     .Bedrock,
	     .Lamp,
	     .Snow,
	     .Ice,
	     .Clay,
	     .Sandstone,
	     .Log,
	     .Spruce_Log,
	     .Coal_Ore,
	     .Iron_Ore,
	     .Copper_Ore,
	     .Cactus,
	     .Cobblestone,
	     .Stone_Bricks,
	     .Planks,
	     .Chest,
	     .Wool,
	     .Wool_Black,
	     .Farmland,
	     .Farmland_Moist,
	     .Gate_Ring,
	     .Gate_Chevron,
	     .Gate_Chevron_Lit:
		return .Cube, .Opaque
	case .Leaves, .Spruce_Leaves, .Glass:
		return .Cube, .Cutout
	case .Tall_Grass, .Poppy, .Dandelion, .Wheat_0 ..= .Wheat_7:
		return .Cross, .Cutout
	case .Water, .Water_1 ..= .Water_7, .Water_Falling, .Gate_Horizon:
		return .Cube, .Translucent
	}
	return .None, .Opaque
}
