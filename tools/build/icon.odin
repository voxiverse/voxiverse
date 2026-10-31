package build

import "core:fmt"
import "core:os"

import "client:font"
import "client:ui"
import "common:base"

// The game's icon: drawn by client/ui/icon.odin (the game sets its window
// icon with the same code), here written at each size as an .ico of PNG
// images (Windows Vista on) for the executable's resources, and as PNGs to
// look at and for the Linux package.

ICON_SIZES :: [7]int{16, 24, 32, 48, 64, 128, 256}

ICON_FONT := #load("../../assets/fonts/jetbrains_mono_regular.ttf")

// write_icon writes build/voxiverse.ico, build/icon-<size>.png for each size and
// build/icon.png (the 256).
write_icon :: proc() -> bool {
	f, font_ok := font.load(ICON_FONT)
	if !font_ok {
		fmt.eprintln("build: icon: cannot read the font")
		return false
	}
	images: [len(ICON_SIZES)][]u8
	for size, i in ICON_SIZES {
		png, err := base.png_encode(size, size, ui.app_icon(&f, size, context.temp_allocator))
		if err != nil {
			fmt.eprintfln("build: icon: %v", err)
			return false
		}
		images[i] = png
		if os.write_entire_file(fmt.tprintf("build/icon-%d.png", size), png) != nil {
			fmt.eprintln("build: cannot write the icon")
			return false
		}
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
	fmt.println("icon   build/voxiverse.ico, build/icon-<size>.png, build/icon.png")
	return true
}
