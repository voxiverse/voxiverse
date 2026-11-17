package sheet

import "core:image"
import "core:image/png"
import "core:testing"

// A compressed sheet decodes to its pixels: runs, repeated rows, short runs
// and noise alike.
@(test)
test_png_round_trip :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	W, H :: 37, 23
	rgba := make([]u8, W * H * 4, context.temp_allocator)
	for y in 0 ..< H {
		for x in 0 ..< W {
			p := rgba[(y * W + x) * 4:][:4]
			switch {
			case y < 5:
				p[0], p[1], p[2], p[3] = 20, 30, 40, 255 // flat: runs and repeated rows
			case y < 10:
				p[0], p[1], p[2], p[3] = u8(x / 3 * 40), 0, 0, 255 // short runs
			case:
				h := u32(x * 7919 + y * 104729) * 2654435761
				p[0], p[1], p[2], p[3] = u8(h >> 24), u8(h >> 16), u8(h >> 8), u8(h)
			}
		}
	}
	data := png_compressed(W, H, rgba)
	img, err := png.load_from_bytes(data, {}, context.temp_allocator)
	if !testing.expect(t, err == nil && img != nil) {return}
	defer image.destroy(img, context.temp_allocator)
	testing.expect_value(t, img.width, W)
	testing.expect_value(t, img.height, H)
	testing.expect(t, string(img.pixels[:]) == string(rgba), "the pixels differ")
}
