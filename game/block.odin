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

Block_Info :: struct {
	name:  string,
	solid: bool, // collides, hides the faces of its neighbours, stops light
	light: u8, // light it gives, 0..15
}

@(rodata)
BLOCK_INFO := [Block]Block_Info {
	.Air     = {"air", false, 0},
	.Stone   = {"stone", true, 0},
	.Dirt    = {"dirt", true, 0},
	.Grass   = {"grass", true, 0},
	.Sand    = {"sand", true, 0},
	.Gravel  = {"gravel", true, 0},
	.Bedrock = {"bedrock", true, 0},
	.Lamp    = {"lamp", true, 15},
}

block_valid :: #force_inline proc(id: u16) -> bool {
	return id < len(Block)
}

block_solid :: #force_inline proc(b: Block) -> bool {
	return BLOCK_INFO[b].solid
}

block_light :: #force_inline proc(b: Block) -> u8 {
	return BLOCK_INFO[b].light
}
