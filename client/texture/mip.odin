package texture

import "core:math"

// A layer of the block texture array: SIZE² RGBA8 (sRGB) pixels and its
// mips down to 1×1, averaged in linear light. The build makes the
// generators' layers (the atlas); the client makes a pack image's the same
// way, with mip_chain.

SIZE :: 16 // a block texture is this many pixels square (game.TEXTURE_SIZE)
MIPS :: 5 // 16, 8, 4, 2, 1
LAYER_PIXELS :: SIZE * SIZE + 8 * 8 + 4 * 4 + 2 * 2 + 1 // a layer with its mips

Rgba :: [4]u8

// mip_chain writes a layer: level (SIZE² pixels) then each mip below it,
// into layer (LAYER_PIXELS pixels).
mip_chain :: proc(level: []Rgba, layer: []Rgba) {
	assert(len(level) == SIZE * SIZE && len(layer) == LAYER_PIXELS)
	copy(layer, level)
	at, size := 0, SIZE
	for size > 1 {
		next := at + size * size
		generate_mip(layer[at:next], size, layer[next:][:(size / 2) * (size / 2)])
		at, size = next, size / 2
	}
}

// generate_mip halves src (size² pixels) into dst ((size/2)² pixels),
// averaging in linear light so distant surfaces keep their brightness.
generate_mip :: proc(src: []Rgba, size: int, dst: []Rgba) {
	half := size / 2
	assert(len(src) == size * size && len(dst) == half * half)
	for y in 0 ..< half {
		for x in 0 ..< half {
			sum: [4]f32
			for d in ([4][2]int{{0, 0}, {1, 0}, {0, 1}, {1, 1}}) {
				p := src[(2 * y + d[1]) * size + 2 * x + d[0]]
				sum += {
					srgb_to_linear(p.r),
					srgb_to_linear(p.g),
					srgb_to_linear(p.b),
					f32(p.a) / 255,
				}
			}
			sum /= 4
			dst[y * half + x] = {
				linear_to_srgb(sum.r),
				linear_to_srgb(sum.g),
				linear_to_srgb(sum.b),
				u8(sum.a * 255 + 0.5),
			}
		}
	}
}

@(private = "file")
to_u8 :: proc(v: f32) -> u8 {
	return u8(clamp(v, 0, 1) * 255 + 0.5)
}

@(private = "file")
srgb_to_linear :: proc(c: u8) -> f32 {
	v := f32(c) / 255
	return v / 12.92 if v <= 0.04045 else math.pow((v + 0.055) / 1.055, 2.4)
}

@(private = "file")
linear_to_srgb :: proc(v: f32) -> u8 {
	s := v * 12.92 if v <= 0.0031308 else 1.055 * math.pow(v, 1 / 2.4) - 0.055
	return to_u8(s)
}
