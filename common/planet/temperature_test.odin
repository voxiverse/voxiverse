package planet

import "core:testing"

// A synthetic planet: land where `is_land(i, j)`, sea elsewhere.
@(private = "file")
synthetic :: proc(w, h: int, is_land: proc(i, j, w, h: int) -> bool) -> Relief {
	r := relief_make(w, h)
	for j in 0 ..< h {
		for i in 0 ..< w {
			r.elevation[j * w + i] = 100 if is_land(i, j, w, h) else -3000
		}
	}
	return r
}

@(test)
test_zonal_table :: proc(t: ^testing.T) {
	testing.expect_value(t, zonal_temperature(0), 27)
	testing.expect_value(t, zonal_temperature(30), 21)
	testing.expect_value(t, zonal_temperature(-30), 20)
	testing.expect_value(t, zonal_temperature(90), -18)
	testing.expect_value(t, zonal_temperature(-90), -30)
	testing.expect(t, abs(zonal_temperature(7.5) - 26.25) < 1e-9)
}

@(test)
test_temperature_earth :: proc(t: ^testing.T) {
	data := #load("../../assets/planet/earth_relief.bin")
	r, ok := relief_decode(data)
	defer relief_destroy(&r)
	testing.expect(t, ok)
	l := land_build(r)
	defer land_destroy(&l)
	tm := temperatures_build(l)
	defer temperatures_destroy(&tm)

	// Zonal annual means over all cells near the observed 27 / 20 / 5 °C at 0 / 30 / 60°N.
	zonal :: proc(l: Land, tm: Temperatures, lat: f64) -> f64 {
		sum, n := 0.0, 0
		for j in 0 ..< l.height {
			if abs(climate_lat(l.height, j) - lat) > 2.5 {continue}
			for i in 0 ..< l.width {
				for m in 0 ..< 12 {sum += f64(tm.month[m][j * l.width + i]) / 10}
				n += 12
			}
		}
		return sum / f64(n)
	}
	for c in ([3][2]f64{{0, 27}, {30, 20}, {60, 5}}) {
		got := zonal(l, tm, c[0])
		testing.expectf(
			t,
			abs(got - c[1]) < 4,
			"zonal mean at %v°N: %v, want %v ± 4",
			c[0],
			got,
			c[1],
		)
	}

	// Snow and ice albedo keep the ice caps cold, and the lapse rate makes the ice sheets EF.
	at :: proc(l: Land, tm: Temperatures, m: int, lat, lon: f64) -> f64 {
		i := int((lon + 180) * f64(l.width) / 360)
		j := int((90 - lat) * f64(l.height) / 180)
		return f64(tm.month[m][j * l.width + i]) / 10
	}
	testing.expect(t, at(l, tm, 11, -78.46, 106.84) < 0, "Vostok in December")
	testing.expect(t, at(l, tm, 6, 72, -40) < 0, "Greenland's ice sheet in July")
	testing.expect(t, at(l, tm, 6, 62.03, 129.73) > 10, "Yakutsk in July")
	testing.expectf(
		t,
		at(l, tm, 0, 62.03, 129.73) < -8,
		"Yakutsk in January (the winds, in a later part, deepen it): %v",
		at(l, tm, 0, 62.03, 129.73),
	)
}

@(test)
test_range_grows_inland :: proc(t: ^testing.T) {
	// A wide continent between two oceans, at 40°N.
	continent :: proc(i, j, w, h: int) -> bool {
		return i >= w / 8 && i < w * 7 / 8 && j > 0 && j < h
	}
	r := synthetic(128, 64, continent)
	defer relief_destroy(&r)
	l := land_build(r)
	defer land_destroy(&l)
	tm := temperatures_build(l)
	defer temperatures_destroy(&tm)
	w := l.width
	j := int((90 - 40.0) * f64(l.height) / 180)
	range_at :: proc(tm: Temperatures, k: int) -> i16 {
		lo, hi := tm.month[0][k], tm.month[0][k]
		for m in 1 ..< 12 {
			lo = min(lo, tm.month[m][k])
			hi = max(hi, tm.month[m][k])
		}
		return hi - lo
	}
	coast := range_at(tm, j * w + w / 8)
	inland := range_at(tm, j * w + w / 2)
	testing.expectf(t, inland > coast, "range at the coast %v, inland %v (0.1 °C)", coast, inland)
	testing.expect(t, l.continentality[j * w + w / 8] < l.continentality[j * w + w / 2])
	// The sea's range is the smallest.
	testing.expect(t, range_at(tm, j * w + 2) < coast)
}

@(test)
test_snow_albedo_cools :: proc(t: ^testing.T) {
	// An all-land planet: the polar winter is below freezing and the equator is warm.
	r := synthetic(64, 32, proc(i, j, w, h: int) -> bool {return true})
	defer relief_destroy(&r)
	l := land_build(r)
	defer land_destroy(&l)
	tm := temperatures_build(l)
	defer temperatures_destroy(&tm)
	k := 0 // the northernmost row
	testing.expect(t, tm.month[0][k] < 0)
	mid := (l.height / 2) * l.width
	testing.expect(t, tm.month[0][mid] > 150)
}
