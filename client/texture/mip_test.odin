package texture

import "core:testing"

// Mips average in linear light: black and white average to mid grey in
// light (188 in sRGB), not 128.
@(test)
test_mips_average_in_linear_light :: proc(t: ^testing.T) {
	src := [4]Rgba{{0, 0, 0, 255}, {255, 255, 255, 255}, {0, 0, 0, 255}, {255, 255, 255, 255}}
	dst: [1]Rgba
	generate_mip(src[:], 2, dst[:])
	testing.expect_value(t, dst[0], Rgba{188, 188, 188, 255})
}

// A layer is its level then each mip, down to one pixel.
@(test)
test_mip_chain :: proc(t: ^testing.T) {
	level: [SIZE * SIZE]Rgba
	for &p in level {p = {200, 100, 50, 255}}
	layer: [LAYER_PIXELS]Rgba
	mip_chain(level[:], layer[:])
	for p in layer {testing.expect_value(t, p, Rgba{200, 100, 50, 255})}
}
