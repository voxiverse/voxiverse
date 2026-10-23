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
}

// Block_Info: everything about a block that client and server agree on
// (how it looks and sounds is the client's: client/blocks.odin).
Block_Info :: struct {
	name:      string,
	collides:  bool, // stops players and entities, and is what the aim hits
	opaque:    bool, // hides the faces of its neighbours, stops light (a column's top)
	breakable: bool, // players (and explosions) may remove it
	placeable: bool, // players may place it
	light:     u8, // light it gives, 0..15
}

@(rodata)
BLOCK_INFO := [Block]Block_Info {
	.Air = {name = "air"},
	.Stone = {name = "stone", collides = true, opaque = true, breakable = true, placeable = true},
	.Dirt = {name = "dirt", collides = true, opaque = true, breakable = true, placeable = true},
	.Grass = {name = "grass", collides = true, opaque = true, breakable = true, placeable = true},
	.Sand = {name = "sand", collides = true, opaque = true, breakable = true, placeable = true},
	.Gravel = {
		name = "gravel",
		collides = true,
		opaque = true,
		breakable = true,
		placeable = true,
	},
	.Bedrock = {name = "bedrock", collides = true, opaque = true}, // the world's floor
	.Lamp = {
		name = "lamp",
		collides = true,
		opaque = true,
		breakable = true,
		placeable = true,
		light = 15,
	},
}

block_valid :: #force_inline proc(id: u16) -> bool {
	return id < len(Block)
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
