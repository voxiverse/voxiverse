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
	Metal,
	Built,
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
	.Metal         = "metal",
	.Built         = "built",
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
	case .Iron_Plate, .Riveted_Iron, .Iron_Grating, .Rusted_Iron, .Dark_Steel:
		return .Metal
	case .Copper, .Verdigris_Copper, .Brass, .Hazard_Stripes, .Pipes:
		return .Metal
	case .Concrete, .Stained_Concrete, .Concrete_Tiles, .Asphalt, .Red_Bricks:
		return .Built
	case .Painted_Red, .Painted_Blue, .Painted_Yellow, .Painted_White:
		return .Built
	case .Tinted_Glass, .Screen, .Vent, .Conveyor_Top, .Conveyor_Side, .Carpet, .Bookshelf:
		return .Fixture
	case .Thatch, .White_Plaster, .Cream_Plaster, .Ochre_Plaster, .Clay_Roof, .Slate_Roof:
		return .Built
	case .Red_Wool, .Blue_Wool, .Green_Wool, .Yellow_Wool:
		return .Cloth
	case .Mud, .Dry_Earth, .Dry_Grass_Top, .Dry_Grass_Side, .Snowy_Grass_Side:
		return .Soil
	case .Red_Sand:
		return .Sand
	case .Moss, .Birch_Leaves, .Autumn_Leaves:
		return .Plant
	case .Packed_Ice:
		return .Water_And_Ice
	case .Dark_Bricks, .Mossy_Bricks, .Rune_Stone:
		return .Masonry
	case .Bone, .Crystal, .Magma, .Obsidian:
		return .Rock
	case .Red_Rock, .Regolith:
		return .Rock
	case .Ash:
		return .Sand
	case .Mycelium_Top, .Mycelium_Side:
		return .Soil
	case .Fungus_Stem, .Fungus_Cap, .Glow_Cap, .Spore_Sprout:
		return .Plant
	case .Amber_Ore, .Opal_Ore, .Cryolite_Ore, .Sulfur_Ore, .Ilmenite_Ore, .Jade_Ore:
		return .Ore
	case .Nacre:
		return .Rock
	case .Lamp, .Glass, .Chest_Side, .Chest_Top, .Ladder, .Door_Lower, .Door_Upper:
		return .Fixture
	case .Gate_Ring, .Gate_Chevron, .Gate_Chevron_Lit, .Gate_Horizon:
		return .Gate
	}
	return .Rock
}
