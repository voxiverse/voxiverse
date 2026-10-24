package game

// Blocks are a closed enum: the id on the wire and in saves is the enum's
// u16 value, so values are append-only (never reorder or reuse). Decoders
// check ids with block_valid before converting.

Block :: enum u16 {
	Air,
	Stone,
	Dirt,
	Grass,
	Sand,
	Gravel,
	Bedrock, // the world's floor; cannot be broken
	Lamp, // gives light
	Water, // still (flowing: M11)
	Snow,
	Ice,
	Clay,
	Sandstone,
	Log,
	Leaves,
	Spruce_Log,
	Spruce_Leaves,
	Coal_Ore,
	Iron_Ore,
	Copper_Ore,
	Tall_Grass, // plants: cross-shaped, no collision
	Poppy,
	Dandelion,
	Cactus,
}

// Block_Info: everything about a block that client and server agree on
// (how it looks and sounds is the client's: client/mesh/textures.odin,
// client/mesh/mesh.odin's block_shape, client/sfx's material_of).
Block_Info :: struct {
	name:        string,
	collides:    bool, // stops players and entities
	opaque:      bool, // hides the faces of its neighbours, stops light (a column's top)
	targetable:  bool, // the aim hits it (else it aims through: air, water)
	breakable:   bool, // players (and explosions) may remove it
	placeable:   bool, // players may place it
	replaceable: bool, // placing a block there takes its place (air, water, tall grass)
	light:       u8, // light it gives, 0..15
}

@(rodata)
BLOCK_INFO := [Block]Block_Info {
	.Air = {name = "air", replaceable = true},
	.Stone = {
		name = "stone",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Dirt = {
		name = "dirt",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Grass = {
		name = "grass",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Sand = {
		name = "sand",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Gravel = {
		name = "gravel",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Bedrock = {name = "bedrock", collides = true, opaque = true, targetable = true},
	.Lamp = {
		name = "lamp",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
		light = 15,
	},
	.Water = {name = "water", placeable = true, replaceable = true},
	.Snow = {
		name = "snow",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Ice = {
		name = "ice",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Clay = {
		name = "clay",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Sandstone = {
		name = "sandstone",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Log = {
		name = "log",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Leaves = {
		name = "leaves",
		collides = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Spruce_Log = {
		name = "spruce_log",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Spruce_Leaves = {
		name = "spruce_leaves",
		collides = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Coal_Ore = {
		name = "coal_ore",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Iron_Ore = {
		name = "iron_ore",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Copper_Ore = {
		name = "copper_ore",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Tall_Grass = {
		name = "tall_grass",
		targetable = true,
		breakable = true,
		placeable = true,
		replaceable = true,
	},
	.Poppy = {name = "poppy", targetable = true, breakable = true, placeable = true},
	.Dandelion = {name = "dandelion", targetable = true, breakable = true, placeable = true},
	.Cactus = {
		name = "cactus",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
}

block_valid :: #force_inline proc(id: u16) -> bool {
	return id < len(Block)
}

block_targetable :: #force_inline proc(b: Block) -> bool {
	return BLOCK_INFO[b].targetable
}

block_collides :: #force_inline proc(b: Block) -> bool {
	return BLOCK_INFO[b].collides
}

block_opaque :: #force_inline proc(b: Block) -> bool {
	return BLOCK_INFO[b].opaque
}

// block_by_name: the block called name ("stone").
block_by_name :: proc(name: string) -> (Block, bool) {
	for b in Block {if BLOCK_INFO[b].name == name {return b, true}}
	return .Air, false
}

block_light :: #force_inline proc(b: Block) -> u8 {
	return BLOCK_INFO[b].light
}
