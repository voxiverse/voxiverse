package build

import "core:fmt"
import "core:os"

import "../../base"

// The game's icon, drawn by code like every other asset: a grass block seen
// from above a corner, 16 x 16 texels, scaled up texel for texel (crunchy,
// never smoothed) to each size Windows asks for. Written as an .ico of PNG
// images (Windows Vista on), for the executable's resources (M20), and as a
// PNG to look at.

ICON_TEXELS :: 16
ICON_SIZES :: [4]int{16, 32, 48, 256}

// icon_texels: the 16 x 16 picture, RGBA. The faces are told apart by
// shade alone (the top lightest, the right darkest); only the silhouette is
// outlined.
icon_texels :: proc() -> (out: [ICON_TEXELS * ICON_TEXELS][4]u8) {
	GRASS := [3][3]u8{{106, 170, 64}, {84, 142, 50}, {128, 190, 80}}
	DIRT := [3][3]u8{{134, 96, 67}, {110, 78, 54}, {150, 110, 78}}
	OUTLINE :: [4]u8{24, 20, 18, 255}
	// face: 0 outside, 1 top, 2 left, 3 right. The top is a rhombus about
	// (8, 4); the sides hang 8 texels below its lower edges.
	face :: proc(x, y: int) -> int {
		if x < 0 || y < 0 || x >= ICON_TEXELS || y >= ICON_TEXELS {return 0}
		fx, fy := f32(x) + 0.5, f32(y) + 0.5
		if abs(fx - 8) / 8 + abs(fy - 4) / 4 <= 1 {return 1}
		edge := 4 + (8 - abs(fx - 8)) / 2
		if fy > edge && fy <= edge + 8 {return 2 if fx < 8 else 3}
		return 0
	}
	for y in 0 ..< ICON_TEXELS {
		for x in 0 ..< ICON_TEXELS {
			f := face(x, y)
			if f == 0 {continue}
			if face(x - 1, y) == 0 ||
			   face(x + 1, y) == 0 ||
			   face(x, y - 1) == 0 ||
			   face(x, y + 1) == 0 {
				out[x + y * ICON_TEXELS] = OUTLINE
				continue
			}
			// Quantized speckle, the same at every size (texels, not pixels).
			h := u32(x * 73856093 ~ y * 19349663) * 0x9e37_79b1
			n := int(h >> 29) % 3
			c := GRASS[n]
			if f != 1 {
				// Grass hangs 2 or 3 texels over the sides' tops.
				fx, fy := f32(x) + 0.5, f32(y) + 0.5
				edge := 4 + (8 - abs(fx - 8)) / 2
				if fy - edge >= 2 + f32(h >> 31) {c = DIRT[n]}
			}
			shade: f32 = 1 if f == 1 else 0.78 if f == 2 else 0.58
			out[x + y * ICON_TEXELS] = {
				u8(f32(c.r) * shade),
				u8(f32(c.g) * shade),
				u8(f32(c.b) * shade),
				255,
			}
		}
	}
	return
}

// icon_scaled: the picture at size x size pixels, texel for texel.
icon_scaled :: proc(texels: ^[ICON_TEXELS * ICON_TEXELS][4]u8, size: int) -> []u8 {
	pixels := make([]u8, size * size * 4)
	for y in 0 ..< size {
		for x in 0 ..< size {
			t := texels[x * ICON_TEXELS / size + y * ICON_TEXELS / size * ICON_TEXELS]
			copy(pixels[(x + y * size) * 4:][:4], t[:])
		}
	}
	return pixels
}

// write_icon writes build/voxiverse.ico and build/icon.png (256 x 256).
write_icon :: proc() -> bool {
	texels := icon_texels()
	images: [len(ICON_SIZES)][]u8
	for size, i in ICON_SIZES {
		png, err := base.png_encode(size, size, icon_scaled(&texels, size))
		if err != nil {
			fmt.eprintfln("build: icon: %v", err)
			return false
		}
		images[i] = png
	}
	// ICONDIR, one ICONDIRENTRY per image, then the images (little endian).
	ico := make([dynamic]u8)
	u16le :: proc(b: ^[dynamic]u8, v: int) {append(b, u8(v), u8(v >> 8))}
	u32le :: proc(b: ^[dynamic]u8, v: int) {append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))}
	u16le(&ico, 0) // reserved
	u16le(&ico, 1) // icon
	u16le(&ico, len(images))
	offset := 6 + 16 * len(images)
	for size, i in ICON_SIZES {
		append(&ico, u8(size % 256), u8(size % 256)) // 0 means 256
		append(&ico, 0, 0) // no palette; reserved
		u16le(&ico, 1) // planes
		u16le(&ico, 32) // bits per pixel
		u32le(&ico, len(images[i]))
		u32le(&ico, offset)
		offset += len(images[i])
	}
	for image in images {append(&ico, ..image)}
	if os.write_entire_file("build/voxiverse.ico", ico[:]) != nil ||
	   os.write_entire_file("build/icon.png", images[len(images) - 1]) != nil {
		fmt.eprintln("build: cannot write the icon")
		return false
	}
	fmt.println("icon   build/voxiverse.ico, build/icon.png")
	return true
}
