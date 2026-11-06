package planet_tool

import "core:fmt"
import "core:os"
import "core:path/filepath"

import "common:base"
import "common:planet"

// The maps for the owner to look at: `build planet maps [dir]` builds the planet from the
// committed relief and writes PNGs of it (shaded relief, temperature and precipitation in
// January and July, the prevailing winds, the Köppen classes). Each climate cell is drawn
// as a SCALE x SCALE square.

MAP_SCALE :: 2
ARROW_STEP :: 8 // climate cells between wind arrows (a 64 x 32 grid)

// KOPPEN_COLORS are the standard Köppen-Geiger map colours, in the order of planet.Koppen.
KOPPEN_COLORS := [planet.Koppen][3]u8 {
	.Ocean = {178, 178, 178},
	.Af    = {0, 0, 255},
	.Am    = {0, 120, 255},
	.Aw    = {70, 170, 250},
	.BWh   = {255, 0, 0},
	.BWk   = {255, 150, 150},
	.BSh   = {245, 165, 0},
	.BSk   = {255, 220, 100},
	.Csa   = {255, 255, 0},
	.Csb   = {200, 200, 0},
	.Csc   = {150, 150, 0},
	.Cwa   = {150, 255, 150},
	.Cwb   = {100, 200, 100},
	.Cwc   = {50, 150, 50},
	.Cfa   = {200, 255, 80},
	.Cfb   = {100, 255, 80},
	.Cfc   = {50, 200, 0},
	.Dsa   = {255, 0, 255},
	.Dsb   = {200, 0, 200},
	.Dsc   = {150, 50, 150},
	.Dsd   = {150, 100, 150},
	.Dwa   = {170, 175, 255},
	.Dwb   = {90, 120, 220},
	.Dwc   = {75, 80, 180},
	.Dwd   = {50, 0, 135},
	.Dfa   = {0, 255, 255},
	.Dfb   = {55, 200, 255},
	.Dfc   = {0, 125, 125},
	.Dfd   = {0, 70, 95},
	.ET    = {178, 178, 178},
	.EF    = {102, 102, 102},
}

Image :: struct {
	w, h: int,
	rgba: []u8,
}

image_make :: proc(w, h: int) -> Image {
	return {w, h, make([]u8, w * h * 4)}
}

image_set :: proc(im: Image, x, y: int, c: [3]u8) {
	if x < 0 || y < 0 || x >= im.w || y >= im.h {return}
	o := (y * im.w + x) * 4
	im.rgba[o], im.rgba[o + 1], im.rgba[o + 2], im.rgba[o + 3] = c.r, c.g, c.b, 255
}

// image_cell fills the SCALE x SCALE square of climate cell (i, j).
image_cell :: proc(im: Image, i, j: int, c: [3]u8) {
	for dy in 0 ..< MAP_SCALE {
		for dx in 0 ..< MAP_SCALE {
			image_set(im, i * MAP_SCALE + dx, j * MAP_SCALE + dy, c)
		}
	}
}

mix_color :: proc(a, b: [3]u8, amount: f64) -> [3]u8 {
	t := clamp(amount, 0, 1)
	return {
		u8(f64(a.r) + (f64(b.r) - f64(a.r)) * t),
		u8(f64(a.g) + (f64(b.g) - f64(a.g)) * t),
		u8(f64(a.b) + (f64(b.b) - f64(a.b)) * t),
	}
}

// temperature_color runs blue (-40 °C) through white (0) to red (40).
temperature_color :: proc(t: f64) -> [3]u8 {
	if t < 0 {return mix_color({40, 60, 200}, {245, 245, 245}, (t + 40) / 40)}
	return mix_color({245, 245, 245}, {210, 40, 30}, t / 40)
}

// rain_color runs from sand (dry) to deep blue (300 mm in the month).
rain_color :: proc(mm: f64) -> [3]u8 {
	return mix_color({235, 220, 170}, {10, 40, 160}, mm / 300)
}

// draw_line draws a line from (x0, y0) to (x1, y1) by stepping along it.
draw_line :: proc(im: Image, x0, y0, x1, y1: f64, c: [3]u8) {
	n := int(max(abs(x1 - x0), abs(y1 - y0))) + 1
	for s in 0 ..= n {
		t := f64(s) / f64(n)
		image_set(im, int(x0 + (x1 - x0) * t), int(y0 + (y1 - y0) * t), c)
	}
}

maps_main :: proc(dir: string) -> bool {
	relief, ok := planet.relief_decode(#load("../../assets/planet/earth_relief.bin"))
	if !ok {
		fmt.eprintln("planet: the committed relief file does not load")
		return false
	}
	defer planet.relief_destroy(&relief)
	p := planet.planet_build(relief)
	defer planet.planet_destroy(&p)
	if os.make_directory_all(dir) != nil {
		fmt.eprintln("planet: cannot make", dir)
		return false
	}
	w, h := p.land.width, p.land.height

	write :: proc(dir, name: string, im: Image) -> bool {
		defer delete(im.rgba)
		png, err := base.png_encode(im.w, im.h, im.rgba)
		if err != nil {return false}
		defer delete(png)
		path, _ := filepath.join({dir, name}, context.temp_allocator)
		if os.write_entire_file(path, png) != nil {
			fmt.eprintln("planet: cannot write", path)
			return false
		}
		fmt.println("wrote", path)
		return true
	}

	// Shaded relief: hypsometric tints, lit from the north-west.
	{
		im := image_make(w * MAP_SCALE, h * MAP_SCALE)
		for y in 0 ..< im.h {
			lat := 90 - (f64(y) + 0.5) * 180 / f64(im.h)
			for x in 0 ..< im.w {
				lon := -180 + (f64(x) + 0.5) * 360 / f64(im.w)
				e := f64(planet.planet_relief_at(p, lat, lon))
				east := f64(planet.planet_relief_at(p, lat, lon + 0.35))
				south := f64(planet.planet_relief_at(p, lat - 0.35, lon))
				shade := clamp(1 + ((e - east) + (south - e)) / 3000, 0.6, 1.4)
				c: [3]u8
				if e < 0 {
					c = mix_color({10, 30, 100}, {110, 170, 220}, (e + 7000) / 7000)
				} else {
					c = mix_color({70, 140, 60}, {150, 120, 80}, e / 2500)
					c = mix_color(c, {250, 250, 250}, (e - 2500) / 3500)
				}
				image_set(
					im,
					x,
					y,
					{
						u8(clamp(f64(c.r) * shade, 0, 255)),
						u8(clamp(f64(c.g) * shade, 0, 255)),
						u8(clamp(f64(c.b) * shade, 0, 255)),
					},
				)
			}
		}
		if !write(dir, "relief.png", im) {return false}
	}

	months := [2]struct {
		month: int,
		name:  string,
	}{{0, "january"}, {6, "july"}}
	for mo in months {
		temp := image_make(w * MAP_SCALE, h * MAP_SCALE)
		rain := image_make(w * MAP_SCALE, h * MAP_SCALE)
		wind := image_make(w * MAP_SCALE, h * MAP_SCALE)
		for j in 0 ..< h {
			for i in 0 ..< w {
				k := j * w + i
				image_cell(temp, i, j, temperature_color(f64(p.temp.month[mo.month][k]) / 10))
				image_cell(rain, i, j, rain_color(f64(p.precip.month[mo.month][k])))
				image_cell(wind, i, j, {90, 120, 90} if p.land.is_land[k] else {60, 90, 140})
			}
		}
		for j := ARROW_STEP / 2; j < h; j += ARROW_STEP {
			for i := ARROW_STEP / 2; i < w; i += ARROW_STEP {
				v := p.winds[mo.month][j * w + i]
				dx := f64(v.x) / planet.WIND_UNIT * f64(ARROW_STEP * MAP_SCALE) * 0.45
				dy := -f64(v.y) / planet.WIND_UNIT * f64(ARROW_STEP * MAP_SCALE) * 0.45
				x := f64(i * MAP_SCALE)
				y := f64(j * MAP_SCALE)
				white := [3]u8{255, 255, 255}
				draw_line(wind, x - dx, y - dy, x + dx, y + dy, white)
				// the head: two short strokes back from the tip
				draw_line(
					wind,
					x + dx,
					y + dy,
					x + dx * 0.4 - dy * 0.4,
					y + dy * 0.4 + dx * 0.4,
					white,
				)
				draw_line(
					wind,
					x + dx,
					y + dy,
					x + dx * 0.4 + dy * 0.4,
					y + dy * 0.4 - dx * 0.4,
					white,
				)
			}
		}
		if !write(dir, fmt.tprintf("temperature_%s.png", mo.name), temp) {return false}
		if !write(dir, fmt.tprintf("precipitation_%s.png", mo.name), rain) {return false}
		if !write(dir, fmt.tprintf("wind_%s.png", mo.name), wind) {return false}
	}

	{
		im := image_make(w * MAP_SCALE, h * MAP_SCALE)
		for j in 0 ..< h {
			for i in 0 ..< w {
				image_cell(im, i, j, KOPPEN_COLORS[p.koppen[j * w + i]])
			}
		}
		if !write(dir, "koppen.png", im) {return false}
	}
	return true
}
