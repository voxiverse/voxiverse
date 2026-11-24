package atmosphere

import "core:testing"

import "client:render"
import "common:game"

// A flat ground at y 63 (top 63) with a roof over x 0..9, z 0..9 at y 70.
@(private = "file")
roofed :: proc(data: rawptr, x, z: i32) -> (i32, bool) {
	if x >= 0 && x < 10 && z >= 0 && z < 10 {return 70, true}
	return 63, true
}

@(private = "file")
unloaded_west :: proc(data: rawptr, x, z: i32) -> (i32, bool) {
	if x < 0 {return 0, false}
	return 63, true
}

// Rain stops under cover: no drop is ever below its column's top (none under the
// roof below it, none in the ground), at any moment of its fall; and it falls round
// the eye beside the roof.
@(test)
test_rain_stops_under_cover :: proc(t: ^testing.T) {
	d: render.Weather_Draw
	render.weather_draw_init(&d)
	defer render.weather_draw_destroy(&d)
	eye := [3]f64{5.5, 65.6, 5.5} // standing under the roof
	for frame in 0 ..< 60 {
		clear(&d.drops)
		n := drops_make(&d, .Rain, 1, {2, 0}, eye, f64(frame) / 30, roofed, nil)
		testing.expect(t, n > 100, "rain falls round the roof")
		testing.expect_value(t, n, len(d.drops))
		for drop in d.drops {
			top, _ := roofed(nil, i32(drop.at.x), i32(drop.at.z))
			if drop.at.x < 0 || drop.at.z < 0 {top, _ = roofed(nil, -1, -1)}
			testing.expectf(
				t,
				drop.at.y >= f64(top) + 1,
				"a drop at %v under its top %d",
				drop.at,
				top,
			)
			under_roof := drop.at.x >= 0 && drop.at.x < 10 && drop.at.z >= 0 && drop.at.z < 10
			testing.expectf(
				t,
				!under_roof || drop.at.y >= 71,
				"a drop under the roof at %v",
				drop.at,
			)
		}
	}
	// Snow, too; and nothing falls where the land is not loaded.
	clear(&d.drops)
	drops_make(&d, .Snow, 1, {}, {0.5, 65, 0.5}, 3, unloaded_west, nil)
	testing.expect(t, len(d.drops) > 50)
	for drop in d.drops {
		testing.expect(t, drop.at.x > -1, "snow where nothing is loaded")
		testing.expect_value(t, drop.shape, render.Drop_Shape.Flake)
	}
}

// Ash falls as flakes, as snow does, in greys (with an ember now and then), and stops
// under cover as rain does.
@(test)
test_ash_falls_as_grey_flakes :: proc(t: ^testing.T) {
	d: render.Weather_Draw
	render.weather_draw_init(&d)
	defer render.weather_draw_destroy(&d)
	eye := [3]f64{5.5, 65.6, 5.5}
	drops_make(&d, .Ash, 1, {}, eye, 3, roofed, nil)
	testing.expect(t, len(d.drops) > 50, "ash falls round the roof")
	greys, embers := 0, 0
	for drop in d.drops {
		testing.expect_value(t, drop.shape, render.Drop_Shape.Flake)
		// (a flake sways up to 0.3 of a block off its column)
		under_roof := drop.at.x >= 0.5 && drop.at.x < 9.5 && drop.at.z >= 0.5 && drop.at.z < 9.5
		testing.expectf(t, !under_roof || drop.at.y >= 71, "ash under the roof at %v", drop.at)
		c := drop.color
		if c.r <= 210 && c.r >= c.g && c.g >= c.b {greys += 1} else {embers += 1}
	}
	testing.expectf(t, greys > embers * 10, "%d grey flakes, %d embers", greys, embers)
}

// Drops are the same from frame to frame but for their fall; none when nothing falls;
// the heaviest storm stays inside the budget.
@(test)
test_drops_are_steady_and_budgeted :: proc(t: ^testing.T) {
	d: render.Weather_Draw
	render.weather_draw_init(&d)
	defer render.weather_draw_destroy(&d)
	flat :: proc(data: rawptr, x, z: i32) -> (i32, bool) {return 0, true}
	testing.expect_value(t, drops_make(&d, .None, 1, {}, {0, 10, 0}, 0, flat, nil), 0)
	testing.expect_value(t, drops_make(&d, .Rain, 0, {}, {0, 10, 0}, 0, flat, nil), 0)
	a := drops_make(&d, .Rain, 1, {}, {0.5, 10, 0.5}, 1.25, flat, nil)
	first := make([]render.Drop, len(d.drops))
	defer delete(first)
	copy(first, d.drops[:])
	clear(&d.drops)
	b := drops_make(&d, .Rain, 1, {}, {0.5, 10, 0.5}, 1.25, flat, nil)
	testing.expect_value(t, a, b)
	for drop, i in d.drops {testing.expect_value(t, drop, first[i])}
	testing.expectf(t, a <= render.MAX_DROPS, "%d drops", a)
	light := drops_make(&d, .Rain, 0.2, {}, {0.5, 10, 0.5}, 1.25, flat, nil)
	testing.expectf(t, light < a / 2, "a drizzle (%d) is lighter than a downpour (%d)", light, a)
}

// A drop is sheltered below a top's upper face.
@(test)
test_sheltered :: proc(t: ^testing.T) {
	testing.expect(t, sheltered(63, 63.9))
	testing.expect(t, !sheltered(63, 64))
	testing.expect(t, !sheltered(63, 80))
	_ = game.Precipitation.Rain
}
