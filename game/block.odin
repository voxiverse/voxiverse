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
}

Block_Info :: struct {
	name:  string,
	solid: bool, // collides, hides the faces of its neighbours
}

@(rodata)
BLOCK_INFO := [Block]Block_Info {
	.Air    = {"air", false},
	.Stone  = {"stone", true},
	.Dirt   = {"dirt", true},
	.Grass  = {"grass", true},
	.Sand   = {"sand", true},
	.Gravel = {"gravel", true},
}

block_valid :: #force_inline proc(id: u16) -> bool {
	return id < len(Block)
}

block_solid :: #force_inline proc(b: Block) -> bool {
	return BLOCK_INFO[b].solid
}
