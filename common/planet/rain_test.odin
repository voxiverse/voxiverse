package planet

import "common:base"
import "core:fmt"
import "core:testing"

@(private = "file")
Built :: struct {
	l:  Land,
	b:  Basin,
	tm: Temperatures,
	w:  [12][]Wind,
	c:  Currents,
	p:  Precipitation,
}

@(private = "file")
built_make :: proc(r: Relief) -> Built {
	x: Built
	x.l = land_build(r)
	x.b = basin_build(x.l)
	x.tm = temperatures_build(x.l)
	for m in 0 ..< 12 {x.w[m] = winds_build(x.l, x.b, m)}
	x.c = currents_build(x.l, x.b, x.w)
	currents_apply(&x.tm, x.c)
	x.p = precipitation_build(x.l, x.tm, x.w, x.c)
	return x
}

@(private = "file")
built_destroy :: proc(x: ^Built) {
	land_destroy(&x.l)
	basin_destroy(&x.b)
	temperatures_destroy(&x.tm)
	for m in 0 ..< 12 {delete(x.w[m])}
	currents_destroy(&x.c)
	precipitation_destroy(&x.p)
}

@(private = "file")
annual :: proc(x: Built, i, j: int) -> int {
	s := 0
	for m in 0 ..< 12 {s += int(x.p.month[m][j * x.l.width + i])}
	return s
}

@(private = "file")
lat_row :: proc(l: Land, lat: f64) -> int {
	return int((90 - lat) * f64(l.height) / 180)
}

@(test)
test_vapour_pressure :: proc(t: ^testing.T) {
	testing.expect(t, abs(vapour_pressure(0) - 6.1) < 1e-9)
	testing.expect(t, abs(vapour_pressure(30) - 42.4) < 0.5)
}

@(test)
test_belt_factor :: proc(t: ^testing.T) {
	testing.expect(t, belt_factor(0) > belt_factor(25) * 5)
	testing.expect(t, belt_factor(25) < belt_factor(50))
}

@(test)
test_winds_belts :: proc(t: ^testing.T) {
	// An all-sea planet: trades blow from the east, westerlies from the west.
	r := relief_make(128, 64)
	defer relief_destroy(&r)
	for k in 0 ..< len(r.elevation) {r.elevation[k] = -3000}
	l := land_build(r)
	defer land_destroy(&l)
	b := basin_build(l)
	defer basin_destroy(&b)
	wd := winds_build(l, b, 0)
	defer delete(wd)
	at :: proc(l: Land, wd: []Wind, lat: f64) -> Wind {
		return wd[lat_row(l, lat) * l.width]
	}
	testing.expect(t, at(l, wd, 15).x < 0 && at(l, wd, 15).y < 0, "NE trades at 15°N")
	testing.expect(t, at(l, wd, -15).x < 0 && at(l, wd, -15).y > 0, "SE trades at 15°S")
	testing.expect(t, at(l, wd, 45).x > 0, "westerlies at 45°N")
	testing.expect(t, at(l, wd, 80).x < 0, "polar easterlies at 80°N")
}

@(test)
test_rain_shadow :: proc(t: ^testing.T) {
	// A north-south ridge at 45° in the westerlies, with sea west of it and land east.
	r := relief_make(512, 256)
	defer relief_destroy(&r)
	for j in 0 ..< 256 {
		for i in 0 ..< 512 {
			e: i16 = -3000
			if i >= 256 {e = 100}
			if i >= 256 && i < 272 {e = i16(100 + (min(i - 256, 271 - i)) * 250)}
			r.elevation[j * 512 + i] = e
		}
	}
	x := built_make(r)
	defer built_destroy(&x)
	j := lat_row(x.l, 45)
	w := x.l.width
	west := annual(x, w / 2 + 1, j) // the coast's windward slope
	crest := w / 2 + 4
	lee := annual(x, crest + 12, j)
	testing.expectf(
		t,
		west + annual(x, w / 2 + 3, j) > 2 * lee,
		"windward %v, leeward %v mm",
		west,
		lee,
	)
}

@(test)
test_cold_current_dries :: proc(t: ^testing.T) {
	// A continent from 20% to 80% of the width with open sea around it: at 25° its west
	// coast has a cold current beside it, its east coast a warm one.
	r := relief_make(512, 256)
	defer relief_destroy(&r)
	for j in 0 ..< 256 {
		for i in 0 ..< 512 {
			r.elevation[j * 512 + i] = 100 if i >= 100 && i < 300 else -3000
		}
	}
	x := built_make(r)
	defer built_destroy(&x)
	j := lat_row(x.l, 25)
	west_coast := annual(x, 100 / 4 + 1, j)
	east_coast := annual(x, 300 / 4 - 2, j)
	testing.expectf(
		t,
		west_coast < east_coast,
		"west coast %v mm, east coast %v mm",
		west_coast,
		east_coast,
	)
}

@(test)
test_rain_earth :: proc(t: ^testing.T) {
	data := #load("../../assets/planet/earth_relief.bin")
	r, ok := relief_decode(data)
	defer relief_destroy(&r)
	testing.expect(t, ok)
	x := built_make(r)
	defer built_destroy(&x)
	w, h := x.l.width, x.l.height

	// The annual land mean and the zonal bands (printed to look at).
	sum, area := 0.0, 0.0
	band_sum: [18]f64
	band_area: [18]f64
	for j in 0 ..< h {
		lat := climate_lat(h, j)
		wt := cos_deg(lat)
		for i in 0 ..< w {
			k := j * w + i
			if !x.l.is_land[k] {continue}
			a := f64(annual(x, i, j))
			sum += a * wt
			area += wt
			bi := min(int((lat + 90) / 10), 17)
			band_sum[bi] += a * wt
			band_area[bi] += wt
		}
	}
	mean := sum / area
	fmt.println("land mean precipitation (mm/year):", mean)
	driest, wettest := 0, 0
	for bi in 0 ..< 18 {
		if band_area[bi] > 0 {
			fmt.printf(
				"band %v..%v°: %v mm\n",
				bi * 10 - 90,
				bi * 10 - 80,
				band_sum[bi] / band_area[bi],
			)
		}
	}
	for bi in 0 ..< 18 {
		if band_area[bi] == 0 {continue}
		v := band_sum[bi] / band_area[bi]
		if band_area[driest] == 0 ||
		   (abs(bi * 10 - 85) < 60 && v < band_sum[driest] / band_area[driest]) {driest = bi}
		if band_area[wettest] == 0 || v > band_sum[wettest] / band_area[wettest] {wettest = bi}
	}
	for c in ([?]struct {
			name:     string,
			lat, lon: f64,
		}{{"Singapore", 1.35, 103.82}, {"Manaus", -3.12, -60.02}, {"Cairo", 30.04, 31.24}, {"London", 51.51, -0.13}, {"Phoenix", 33.45, -112.07}, {"Mumbai", 19.08, 72.88}, {"Lima", -12.05, -77.04}, {"Moscow", 55.76, 37.62}, {"Chicago", 41.88, -87.63}}) {
		i := int((c.lon + 180) * f64(w) / 360)
		j := lat_row(x.l, c.lat)
		fmt.printf("%v: %v mm\n", c.name, annual(x, i, j))
	}
	testing.expectf(t, mean > 400 && mean < 1200, "land mean %v mm/year", mean)
	testing.expect(t, wettest >= 8 && wettest <= 9, "the wettest band is the equator's")
}

@(private = "file")
cos_deg :: proc(lat: f64) -> f64 {
	return base.cos(lat * PI / 180)
}
