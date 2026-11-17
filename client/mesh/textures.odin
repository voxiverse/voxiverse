package mesh

import "core:slice"

import "client:texture"
import "common:game"

// Block textures: one layer per texture.Generator in a texture array, then
// one per pack image. The registry says which generator each texture of each
// block face uses (game.TEXTURE_GENERATOR_NAMES is that enum, in order).

TEXTURE_SIZE :: texture.SIZE
TEXTURE_MIPS :: texture.MIPS
#assert(TEXTURE_SIZE == game.TEXTURE_SIZE)

Rgba :: texture.Rgba

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
		texture.generate(texture.Generator(layer), pixels)
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
// layer's mips, one layer after another (what render.world_init takes).
texture_array :: proc(reg: ^game.Registry, allocator := context.temp_allocator) -> []u8 {
	layers := game.registry_texture_layers(reg)
	pixels := make([]Rgba, layers * texture.LAYER_PIXELS, allocator)
	level: [TEXTURE_SIZE * TEXTURE_SIZE]Rgba
	for layer in 0 ..< layers {
		texture_layer_pixels(reg, u32(layer), level[:])
		texture.mip_chain(level[:], pixels[layer * texture.LAYER_PIXELS:][:texture.LAYER_PIXELS])
	}
	return slice.to_bytes(pixels)
}
