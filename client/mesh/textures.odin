package mesh

import "core:slice"

import "client:texture"
import "common:game"

// Block textures: one layer per texture.Generator in a texture array, then
// one per pack image. The registry says which generator each texture of each
// block face uses (game.TEXTURE_GENERATOR_NAMES is that enum, in order).
//
// The generators' layers are not drawn here: the build made them (the atlas,
// client/texture: atlas_make; tools/build/atlas.odin) and the executable
// carries them. A pack's image, which can come from a server at run time,
// gets its mips here, the way the atlas's were made (texture.mip_chain).

TEXTURE_SIZE :: texture.SIZE
TEXTURE_MIPS :: texture.MIPS
#assert(TEXTURE_SIZE == game.TEXTURE_SIZE)

Rgba :: texture.Rgba

// ATLAS: the generators' layers, each texture.LAYER_PIXELS pixels;
// ATLAS_INDEX: their names, a line each (a test holds it to the registry's).
ATLAS :: #load("../../build/textures/" + texture.ATLAS_PIXELS)
ATLAS_INDEX :: #load("../../build/textures/" + texture.ATLAS_INDEX, string)

// atlas_layer: generator layer's pixels (its level, then its mips).
atlas_layer :: proc(layer: u32) -> []Rgba {
	all := slice.reinterpret([]Rgba, ATLAS)
	return all[int(layer) * texture.LAYER_PIXELS:][:texture.LAYER_PIXELS]
}

// block_texture: the layer of the client's texture array that b's face f
// uses: its texture's generator (a pack's texture of the same generator is the
// same picture).
block_texture :: proc(reg: ^game.Registry, b: game.Block, f: Face) -> u32 {
	faces := reg.blocks.defs[b].faces // side, top, bottom: texture numbers
	k := 0
	#partial switch f {
	case .Pos_Y:
		k = 1
	case .Neg_Y:
		k = 2
	}
	return reg.textures[faces[k]].layer
}

// texture_layer_pixels fills pixels (TEXTURE_SIZE²) with a layer of the
// texture array: a generator's, or a pack's image (level 0, as the pack made
// it; it is not palette-quantized).
texture_layer_pixels :: proc(reg: ^game.Registry, layer: u32, pixels: []Rgba) {
	if int(layer) < len(game.TEXTURE_GENERATOR_NAMES) {
		copy(pixels, atlas_layer(layer)[:TEXTURE_SIZE * TEXTURE_SIZE])
		return
	}
	image := reg.images[int(layer) - len(game.TEXTURE_GENERATOR_NAMES)]
	for p, i in image {pixels[i] = p}
}

// block_average_colour: the average of the opaque pixels of b's face f, one
// colour (grey where there are none).
block_average_colour :: proc(reg: ^game.Registry, b: game.Block, f: Face) -> Rgba {
	pixels: [TEXTURE_SIZE * TEXTURE_SIZE]Rgba
	texture_layer_pixels(reg, block_texture(reg, b, f), pixels[:])
	sum: [3]u32
	n: u32
	for c in pixels {
		if c.a == 0 {continue}
		sum += {u32(c.r), u32(c.g), u32(c.b)}
		n += 1
	}
	if n == 0 {return {128, 128, 128, 255}}
	return {u8(sum.r / n), u8(sum.g / n), u8(sum.b / n), 255}
}

// texture_array makes the bytes of the whole texture array for reg: every
// layer's mips, one layer after another (what render.world_init takes): the
// atlas, then each pack image's.
texture_array :: proc(reg: ^game.Registry, allocator := context.temp_allocator) -> []u8 {
	pixels := make([]Rgba, game.registry_texture_layers(reg) * texture.LAYER_PIXELS, allocator)
	copy(slice.to_bytes(pixels), ATLAS)
	for &image, i in reg.images {
		layer := len(game.TEXTURE_GENERATOR_NAMES) + i
		texture.mip_chain(image[:], pixels[layer * texture.LAYER_PIXELS:][:texture.LAYER_PIXELS])
	}
	return slice.to_bytes(pixels)
}
