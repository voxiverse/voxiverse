package planet

import "core:math"

// Planet is the home world's model: the relief and the climate grid built from it.
Planet :: struct {
	relief: Relief, // owned by the caller of planet_build, not freed here
	land:   Land,
	temp:   Temperatures,
	precip: Precipitation,
	winds:  [12][]Wind,
	koppen: []Koppen,
}

// Climate_Sample is the climate at a place and time of year.
Climate_Sample :: struct {
	temperature:   f32, // °C
	precipitation: f32, // mm in the month
	wind:          [2]f32, // east, north; 1 is a unit of wind
	elevation:     f32, // metres (the relief's, sea level where under water)
}

// planet_build computes the whole climate grid from a relief. Deterministic on every OS.
planet_build :: proc(relief: Relief, allocator := context.allocator) -> Planet {
	p: Planet
	p.relief = relief
	p.land = land_build(relief, allocator)
	b := basin_build(p.land, context.temp_allocator)
	p.temp = temperatures_build(p.land, allocator)
	for m in 0 ..< 12 {p.winds[m] = winds_build(p.land, b, m, allocator)}
	c := currents_build(p.land, b, p.winds, context.temp_allocator)
	currents_apply(&p.temp, c)
	p.precip = precipitation_build(p.land, p.temp, p.winds, c, allocator)

	w, h := p.land.width, p.land.height
	p.koppen = make([]Koppen, w * h, allocator)
	for j in 0 ..< h {
		north := climate_lat(h, j) >= 0
		for i in 0 ..< w {
			k := j * w + i
			if !p.land.is_land[k] {continue}
			t, pr: [12]f64
			for m in 0 ..< 12 {
				t[m] = f64(p.temp.month[m][k]) / 10
				pr[m] = f64(p.precip.month[m][k])
			}
			p.koppen[k] = koppen_classify(t, pr, north)
		}
	}
	return p
}

planet_destroy :: proc(p: ^Planet) {
	land_destroy(&p.land)
	temperatures_destroy(&p.temp)
	precipitation_destroy(&p.precip)
	for m in 0 ..< 12 {delete(p.winds[m])}
	delete(p.koppen)
	p^ = {}
}

// planet_hash is a hash of the climate grid, for the cross-OS determinism test.
planet_hash :: proc(p: Planet) -> u64 {
	h := u64(0xcbf29ce484222325)
	mix :: proc(h: ^u64, v: u64) {
		h^ = (h^ ~ v) * 0x100000001b3
	}
	for m in 0 ..< 12 {
		for k in 0 ..< len(p.temp.month[m]) {
			mix(&h, u64(u16(p.temp.month[m][k])))
			mix(&h, u64(p.precip.month[m][k]))
			mix(&h, u64(u8(p.winds[m][k].x)) | u64(u8(p.winds[m][k].y)) << 8)
		}
	}
	for k in p.koppen {mix(&h, u64(k))}
	return h
}

// planet_relief_at is the elevation in metres at a place, bicubic (Catmull-Rom) between
// relief cells; longitude wraps.
planet_relief_at :: proc(p: Planet, lat, lon: f64) -> f32 {
	r := p.relief
	x := (lon + 180) / 360 * f64(r.width) - 0.5
	y := clamp((90 - lat) / 180 * f64(r.height) - 0.5, 0, f64(r.height - 1))
	i0, j0 := int(math.floor(x)), int(math.floor(y))
	fx, fy := x - f64(i0), y - f64(j0)
	cubic :: proc(a, b, c, d, t: f64) -> f64 {
		return b + 0.5 * t * (c - a + t * (2 * a - 5 * b + 4 * c - d + t * (3 * (b - c) + d - a)))
	}
	rows: [4]f64
	for dj in 0 ..< 4 {
		j := clamp(j0 - 1 + dj, 0, r.height - 1)
		v: [4]f64
		for di in 0 ..< 4 {
			i := ((i0 - 1 + di) % r.width + r.width) % r.width
			v[di] = f64(relief_at(r, i, j))
		}
		rows[dj] = cubic(v[0], v[1], v[2], v[3], fx)
	}
	return f32(cubic(rows[0], rows[1], rows[2], rows[3], fy))
}

// planet_climate_at is the climate at a place. `month_fraction` counts months from the
// start of January (0..12, mid-January is 0.5), bilinear between cells and months; the
// temperature is corrected by the lapse rate from the climate cell's mean elevation to the
// place's own elevation.
planet_climate_at :: proc(p: Planet, lat, lon, month_fraction: f64) -> Climate_Sample {
	w, h := p.land.width, p.land.height
	x := (lon + 180) / 360 * f64(w) - 0.5
	y := clamp((90 - lat) / 180 * f64(h) - 0.5, 0, f64(h - 1))
	i0, j0 := int(math.floor(x)), int(math.floor(y))
	fx, fy := x - f64(i0), y - f64(j0)
	i1 := (i0 + 1) % w
	i0 = (i0 % w + w) % w
	j1 := min(j0 + 1, h - 1)
	mf := month_fraction - 0.5
	m0 := int(math.floor(mf))
	fm := mf - f64(m0)
	ma := (m0 % 12 + 12) % 12
	mb := (ma + 1) % 12

	corner :: proc(v: []f64, wts: [4]f64) -> f64 {
		return v[0] * wts[0] + v[1] * wts[1] + v[2] * wts[2] + v[3] * wts[3]
	}
	wts := [4]f64{(1 - fx) * (1 - fy), fx * (1 - fy), (1 - fx) * fy, fx * fy}
	ks := [4]int{j0 * w + i0, j0 * w + i1, j1 * w + i0, j1 * w + i1}

	s: Climate_Sample
	cell_elev := 0.0
	for c in 0 ..< 4 {
		k := ks[c]
		wt := wts[c]
		t := f64(p.temp.month[ma][k]) * (1 - fm) + f64(p.temp.month[mb][k]) * fm
		pr := f64(p.precip.month[ma][k]) * (1 - fm) + f64(p.precip.month[mb][k]) * fm
		wx := f64(p.winds[ma][k].x) * (1 - fm) + f64(p.winds[mb][k].x) * fm
		wy := f64(p.winds[ma][k].y) * (1 - fm) + f64(p.winds[mb][k].y) * fm
		s.temperature += f32(t / 10 * wt)
		s.precipitation += f32(pr * wt)
		s.wind.x += f32(wx / WIND_UNIT * wt)
		s.wind.y += f32(wy / WIND_UNIT * wt)
		if p.land.is_land[k] {cell_elev += f64(p.land.elevation[k]) * wt}
	}
	s.elevation = planet_relief_at(p, lat, lon)
	if cell_elev > 0 || s.elevation > 0 {
		s.temperature -= f32(LAPSE_PER_KM * (max(f64(s.elevation), 0) - max(cell_elev, 0)) / 1000)
	}
	return s
}

// planet_koppen_at is the class of the climate cell holding a place.
planet_koppen_at :: proc(p: Planet, lat, lon: f64) -> Koppen {
	w, h := p.land.width, p.land.height
	i := clamp(int((lon + 180) / 360 * f64(w)), 0, w - 1)
	j := clamp(int((90 - lat) / 180 * f64(h)), 0, h - 1)
	return p.koppen[j * w + i]
}
