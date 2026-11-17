package texture

// Family: what a texture is made of, the way a person sorts them: the sheet
// (tools/sheet) groups textures by it, so look-alikes of a family sit side
// by side and can be told apart, or not.
Family :: enum u8 {
	Rock,
	Soil,
	Sand,
	Ore,
	Water_And_Ice,
	Plant,
	Crop,
	Wood,
	Masonry,
	Cloth,
	Fixture,
	Gate,
}

FAMILY_NAMES := [Family]string {
	.Rock          = "rock",
	.Soil          = "soil",
	.Sand          = "sand",
	.Ore           = "ore",
	.Water_And_Ice = "water and ice",
	.Plant         = "plants",
	.Crop          = "crops",
	.Wood          = "wood",
	.Masonry       = "masonry",
	.Cloth         = "cloth",
	.Fixture       = "fixtures",
	.Gate          = "the gate",
}

// family: g's family.
family :: proc(g: Generator) -> Family {
	switch g {
	case .Stone, .Bedrock, .Gravel, .Clay, .Basalt, .Limestone, .Slate:
		return .Rock
	case .Dirt, .Grass_Top, .Grass_Side, .Farmland_Top, .Farmland_Moist_Top:
		return .Soil
	case .Sand, .Sandstone_Side, .Sandstone_Top:
		return .Sand
	case .Coal_Ore, .Iron_Ore, .Copper_Ore:
		return .Ore
	case .Water, .Snow, .Ice:
		return .Water_And_Ice
	case .Leaves, .Spruce_Leaves, .Tall_Grass, .Poppy, .Dandelion, .Cactus_Side, .Cactus_Top:
		return .Plant
	case .Wheat_0, .Wheat_1, .Wheat_2, .Wheat_3, .Wheat_4, .Wheat_5, .Wheat_6, .Wheat_7:
		return .Crop
	case .Log_Side, .Log_Top, .Spruce_Log_Side, .Planks, .Oak_Panel:
		return .Wood
	case .Birch_Log, .Birch_Log_End, .Birch_Planks, .Birch_Panel:
		return .Wood
	case .Spruce_Log_End, .Spruce_Planks, .Spruce_Panel:
		return .Wood
	case .Redwood_Log, .Redwood_Log_End, .Redwood_Planks, .Redwood_Panel:
		return .Wood
	case .Weathered_Log, .Weathered_Log_End, .Weathered_Planks, .Weathered_Panel:
		return .Wood
	case .Cobblestone, .Stone_Bricks, .Stone_Tiles, .Polished_Stone:
		return .Masonry
	case .Basalt_Cobble, .Basalt_Bricks, .Basalt_Tiles, .Polished_Basalt:
		return .Masonry
	case .Sandstone_Cobble, .Sandstone_Bricks, .Sandstone_Tiles, .Polished_Sandstone:
		return .Masonry
	case .Limestone_Cobble, .Limestone_Bricks, .Limestone_Tiles, .Polished_Limestone:
		return .Masonry
	case .Slate_Cobble, .Slate_Bricks, .Slate_Tiles, .Polished_Slate:
		return .Masonry
	case .Wool, .Wool_Black:
		return .Cloth
	case .Lamp, .Glass, .Chest_Side, .Chest_Top, .Ladder, .Door_Lower, .Door_Upper:
		return .Fixture
	case .Gate_Ring, .Gate_Chevron, .Gate_Chevron_Lit, .Gate_Horizon:
		return .Gate
	}
	return .Rock
}
