package ui

import "core:testing"

import "../font"

@(private = "file")
ICON_FONT := #load("../../assets/fonts/jetbrains_mono_regular.ttf")

// Every size of the icon: clear corners, the three faces' colours where they
// are, a white question mark on the front, and the same bytes every time.
@(test)
test_app_icon :: proc(t: ^testing.T) {
	f, ok := font.load(ICON_FONT)
	testing.expect(t, ok)
	for size in ([]int{16, 24, 32, 48, 64, 128, 256}) {
		pixels := app_icon(&f, size, context.temp_allocator)
		testing.expect_value(t, len(pixels), size * size * 4)
		at :: proc(pixels: []u8, size: int, p: [2]f32) -> [4]u8 {
			x, y := int(p.x * f32(size)), int(p.y * f32(size))
			return ([^][4]u8)(raw_data(pixels))[x + y * size]
		}
		for corner in ([]([2]f32){{0, 0}, {0.99, 0}, {0, 0.99}, {0.99, 0.99}}) {
			testing.expectf(t, at(pixels, size, corner).a == 0, "size %d: corner %v", size, corner)
		}
		// The top's and the right's centres; the front's low left, clear of the mark.
		top, front, right := ICON_TOP, ICON_FRONT, ICON_RIGHT
		for c in ([]struct {
				at:   [2]f32,
				want: [3]u8,
			}{{{0.50, 0.19}, top}, {{0.14, 0.86}, front}, {{0.81, 0.50}, right}}) {
			got := at(pixels, size, c.at)
			testing.expectf(
				t,
				got.rgb == c.want && got.a == 255,
				"size %d at %v: %v, want %v",
				size,
				c.at,
				got,
				c.want,
			)
		}
		white := 0
		lo, hi := ICON_FRONT_MIN, ICON_FRONT_MAX
		for y in int(lo.y * f32(size)) ..< int(hi.y * f32(size)) {
			for x in int(lo.x * f32(size)) ..< int(hi.x * f32(size)) {
				p := ([^][4]u8)(raw_data(pixels))[x + y * size]
				if p.r > 160 && p.g > 160 && p.b > 160 {white += 1}
			}
		}
		testing.expectf(t, white >= size * size / 200, "size %d: %d white pixels", size, white)
		again := app_icon(&f, size, context.temp_allocator)
		testing.expectf(t, string(again) == string(pixels), "size %d: not deterministic", size)
	}
}
