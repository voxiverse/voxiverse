package texture

import "core:fmt"
import "core:slice"
import "core:strings"

// The atlas: every generator's layer, made at build time (tools/atlas writes
// it to build/textures/, and the client carries it: client/mesh). It is two
// files: the layers, one after another in Generator order, each LAYER_PIXELS
// RGBA8 pixels (its level, then its mips); and the index, a generator's name
// a line, in lower case, the line number its layer.

ATLAS_PIXELS :: "blocks.rgba"
ATLAS_INDEX :: "blocks.txt"

// atlas_make: the atlas's two files' contents. The same bytes on every
// machine and every run.
atlas_make :: proc(allocator := context.allocator) -> (pixels: []u8, index: string) {
	layers := make([]Rgba, len(Generator) * LAYER_PIXELS, allocator)
	level: [SIZE * SIZE]Rgba
	b := strings.builder_make(allocator)
	for g, i in Generator {
		generate(g, level[:])
		mip_chain(level[:], layers[i * LAYER_PIXELS:][:LAYER_PIXELS])
		strings.write_string(&b, generator_name(g))
		strings.write_byte(&b, '\n')
	}
	return slice.to_bytes(layers), strings.to_string(b)
}

// generator_name: g as packs name it (game.TEXTURE_GENERATOR_NAMES): Grass_Top is grass_top.
generator_name :: proc(g: Generator, allocator := context.temp_allocator) -> string {
	return strings.to_lower(fmt.tprintf("%v", g), allocator)
}
