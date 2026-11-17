package mesh

import "core:slice"
import "core:strings"
import "core:testing"

import "client:texture"
import "common:game"

// The atlas the executable carries is the generators' (made again here, the
// same bytes: the build's atlas is deterministic and current), its index is
// the registry's generator names in order, and the texture array starts with it.
@(test)
test_the_atlas_is_the_generators :: proc(t: ^testing.T) {
	pixels, index := texture.atlas_make(context.temp_allocator)
	testing.expect(t, slice.equal(ATLAS, pixels), "the atlas is not what the generators make")
	testing.expect_value(t, ATLAS_INDEX, index)
	names := strings.split_lines(strings.trim_right(ATLAS_INDEX, "\n"), context.temp_allocator)
	testing.expect(t, slice.equal(names, game.TEXTURE_GENERATOR_NAMES[:]))
	testing.expect_value(t, len(ATLAS), len(names) * texture.LAYER_PIXELS * size_of(Rgba))

	reg := game.registry_base()
	defer game.registry_destroy(reg)
	testing.expect(t, slice.equal(texture_array(reg), ATLAS))
	stone: [TEXTURE_SIZE * TEXTURE_SIZE]Rgba
	texture_layer_pixels(reg, u32(texture.Generator.Stone), stone[:])
	want: [TEXTURE_SIZE * TEXTURE_SIZE]Rgba
	texture.generate(.Stone, want[:])
	testing.expect(t, stone == want)
}
