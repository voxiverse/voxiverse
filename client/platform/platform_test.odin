package platform

import "core:testing"

@(test)
test_clipboard_capped :: proc(t: ^testing.T) {
	testing.expect_value(t, clipboard_capped("hi"), "hi")
	testing.expect_value(t, clipboard_capped(""), "")
	big := CLIPBOARD_CAP + 10
	buf := make([]u8, big, context.temp_allocator)
	for &b in buf {b = 'a'}
	s := string(buf)
	capped := clipboard_capped(s)
	testing.expect_value(t, len(capped), CLIPBOARD_CAP)
	testing.expect(t, capped == s[:CLIPBOARD_CAP])
}

@(test)
test_randr_mode_refresh_hz :: proc(t: ^testing.T) {
	// 148500 kHz, 2200 x 1125 totals → 60 Hz (a common 1080p mode).
	hz := randr_mode_refresh_hz(148_500, 2200, 1125)
	testing.expect(t, hz > 59.9 && hz < 60.1)
	testing.expect_value(t, randr_mode_refresh_hz(148_500, 0, 1125), 0)
	testing.expect_value(t, randr_mode_refresh_hz(148_500, 2200, 0), 0)
	// The inverted /1000 formula Inkling shipped would yield ~0.06 Hz here.
	testing.expect(t, hz > 1)
}

@(test)
test_cocoa_position_y_roundtrip :: proc(t: ^testing.T) {
	main_h: i32 = 1080
	window_h: i32 = 720
	top_y: i32 = 100
	cocoa_y := cocoa_from_top_left_y(top_y, window_h, main_h)
	testing.expect_value(t, cocoa_y, main_h - top_y - window_h)
	testing.expect_value(t, cocoa_top_left_y(cocoa_y, window_h, main_h), top_y)
}

@(test)
test_icon_pick :: proc(t: ^testing.T) {
	px :: proc(n: int) -> []u8 {
		return make([]u8, n * n * 4, context.temp_allocator)
	}
	images := []Icon_Image{{16, px(16)}, {32, px(32)}, {48, px(48)}, {64, px(64)}}
	testing.expect_value(t, icon_pick(images, 16), 0)
	testing.expect_value(t, icon_pick(images, 32), 1)
	testing.expect_value(t, icon_pick(images, 40), 1) // largest at or below 40 is 32
	testing.expect_value(t, icon_pick(images, 8), 0) // none <= 8 → smallest above = 16
	testing.expect_value(t, icon_pick([]Icon_Image{}, 16), -1)
	bad := []Icon_Image{{16, px(8)}} // wrong byte count
	testing.expect_value(t, icon_pick(bad, 16), -1)
}
