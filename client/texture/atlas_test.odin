package texture

import "core:slice"
import "core:testing"

// The same generators make the same atlas, byte for byte, every time; its
// index names every generator once, in order.
@(test)
test_atlas_is_deterministic :: proc(t: ^testing.T) {
	a, a_index := atlas_make(context.temp_allocator)
	b, b_index := atlas_make(context.temp_allocator)
	testing.expect(t, slice.equal(a, b))
	testing.expect_value(t, a_index, b_index)
	testing.expect_value(t, len(a), len(Generator) * LAYER_PIXELS * size_of(Rgba))
	testing.expect_value(t, generator_name(.Farmland_Moist_Top), "farmland_moist_top")
}
