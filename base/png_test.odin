package base

import "core:bytes"
import "core:image"
import "core:image/png"
import "core:testing"

@(test)
test_png_round_trip :: proc(t: ^testing.T) {
	// Big enough to need several stored blocks.
	W, H :: 300, 70
	pixels := make([]u8, W * H * 4)
	defer delete(pixels)
	for &p, i in pixels {p = u8(i * 7 + i / 13)}
	encoded, err := png_encode(W, H, pixels)
	testing.expect(t, err == nil)
	defer delete(encoded)

	img, load_err := png.load_from_bytes(encoded)
	testing.expectf(t, load_err == nil, "decode failed: %v", load_err)
	if load_err != nil {return}
	defer image.destroy(img)
	testing.expect(t, img.width == W && img.height == H && img.channels == 4 && img.depth == 8)
	testing.expect(t, bytes.equal(img.pixels.buf[:], pixels), "pixels differ")
}
