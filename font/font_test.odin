package font

import "core:testing"

@(private = "file")
FONT_DATA := #load("../assets/fonts/jetbrains_mono_regular.ttf")

@(private = "file")
load_test_font :: proc(t: ^testing.T) -> Font {
	f, ok := load(FONT_DATA)
	testing.expect(t, ok, "font failed to load")
	return f
}

@(test)
test_load_metrics :: proc(t: ^testing.T) {
	f := load_test_font(t)
	testing.expect_value(t, f.units_per_em, 1000)
	testing.expect(t, f.ascent > 0 && f.descent < 0)
	testing.expect(t, f.num_glyphs > 100)
}

@(test)
test_glyph_lookup :: proc(t: ^testing.T) {
	f := load_test_font(t)
	for r in ([]rune{'A', 'a', '0', '~', 'é', 'Ж', '→'}) {
		testing.expectf(t, glyph_index(&f, r) != 0, "no glyph for %q", r)
	}
	testing.expect(t, glyph_index(&f, 'A') != glyph_index(&f, 'B'))
	testing.expect_value(t, glyph_index(&f, rune(0xE000)), Glyph(0)) // private use: absent
	testing.expect_value(t, glyph_index(&f, rune(0x1F600)), Glyph(0)) // emoji: absent
}

@(test)
test_monospace_advances :: proc(t: ^testing.T) {
	f := load_test_font(t)
	expected := advance(&f, glyph_index(&f, 'M'))
	testing.expect(t, expected > 0)
	for r in ' ' ..= '~' {
		testing.expectf(t, advance(&f, glyph_index(&f, r)) == expected, "advance of %q differs", r)
	}
}

// Coverage must equal geometry: the sum of a glyph's coverage is its area in
// pixels, which the shoelace formula gives exactly from the same outline.
// Glyphs chosen without overlapping contours (overlap counts once in
// coverage but twice in the formula).
@(test)
test_coverage_matches_outline_area :: proc(t: ^testing.T) {
	f := load_test_font(t)
	for r in ([]rune{'I', 'O', 'o', 'l', '-', '.', 'L', 'H', 'v'}) {
		g := glyph_index(&f, r)
		scale := scale_for_size(&f, 200)

		outline: Outline
		outline.points.allocator = context.temp_allocator
		outline.contours.allocator = context.temp_allocator
		testing.expect(t, build_outline(&f, g, scale, &outline))
		area: f32
		start := 0
		for end in outline.contours {
			for i in start ..< end {
				a := outline.points[i]
				b := outline.points[start if i + 1 == end else i + 1]
				area += a.x * b.y - b.x * a.y
			}
			start = end
		}
		area = abs(area) / 2

		bm, ok := rasterize(&f, g, scale, context.temp_allocator)
		testing.expect(t, ok)
		coverage: f32
		for p in bm.pixels {coverage += f32(p) / 255}
		error := abs(coverage - area) / area
		testing.expectf(
			t,
			error < 0.01,
			"%q: coverage %.1f vs area %.1f (%.2f%% off)",
			r,
			coverage,
			area,
			error * 100,
		)
	}
}

@(test)
test_composite_glyph :: proc(t: ^testing.T) {
	f := load_test_font(t)
	e_acute := glyph_index(&f, 'é')
	data := glyph_data(&f, e_acute)
	testing.expect(t, len(data) >= 10 && be_i16(data, 0) < 0, "é should be a composite glyph")

	scale := scale_for_size(&f, 64)
	plain, ok1 := rasterize(&f, glyph_index(&f, 'e'), scale, context.temp_allocator)
	accented, ok2 := rasterize(&f, e_acute, scale, context.temp_allocator)
	testing.expect(t, ok1 && ok2)
	// The accent sits above the e: same bottom, taller bitmap, more ink.
	testing.expect_value(t, accented.y + accented.height, plain.y + plain.height)
	testing.expect(t, accented.height > plain.height + 5)
	ink :: proc(bm: Bitmap) -> (sum: int) {
		for p in bm.pixels {sum += int(p)}
		return
	}
	testing.expect(t, ink(accented) > ink(plain))
}

@(test)
test_space_is_empty :: proc(t: ^testing.T) {
	f := load_test_font(t)
	bm, ok := rasterize(&f, glyph_index(&f, ' '), scale_for_size(&f, 16), context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, bm.width * bm.height, 0)
}
