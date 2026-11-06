package planet

import "common:base"
import "core:fmt"
import "core:testing"

@(private = "file")
cls :: proc(t, p: [12]f64, north := true) -> Koppen {
	return koppen_classify(t, p, north)
}

@(test)
test_koppen_classes :: proc(t: ^testing.T) {
	flat :: proc(v: f64) -> [12]f64 {
		a: [12]f64
		for i in 0 ..< 12 {a[i] = v}
		return a
	}
	testing.expect_value(t, cls(flat(26), flat(200)), Koppen.Af)
	// Monsoon: a dry winter month of 30 mm, 2 400 mm a year.
	mon := flat(220)
	mon[0] = 30
	testing.expect_value(t, cls(flat(27), mon), Koppen.Am)
	// Savanna: a winter dry season with a modest year.
	sav := flat(120)
	sav[0], sav[1], sav[11] = 5, 5, 5
	testing.expect_value(t, cls(flat(26), sav), Koppen.Aw)
	testing.expect_value(t, cls(flat(25), flat(3)), Koppen.BWh)
	testing.expect_value(t, cls(flat(12), flat(8)), Koppen.BWk)
	testing.expect_value(t, cls(flat(22), flat(40)), Koppen.BSh)
	// Marine west coast: mild, wet all year.
	marine := [12]f64{5, 5, 7, 9, 12, 15, 17, 17, 14, 11, 7, 5}
	testing.expect_value(t, cls(marine, flat(60)), Koppen.Cfb)
	// Mediterranean: a dry hot summer, wet winter.
	med := [12]f64{9, 10, 12, 15, 19, 23, 26, 26, 23, 18, 13, 10}
	dry := [12]f64{80, 70, 60, 50, 30, 10, 3, 5, 30, 70, 90, 90}
	testing.expect_value(t, cls(med, dry), Koppen.Csa)
	// Cold continental: Fairbanks-like Dfc; Yakutsk-like Dfd.
	dfc := [12]f64{-23, -19, -10, 0, 9, 15, 17, 13, 6, -4, -16, -22}
	testing.expect_value(t, cls(dfc, flat(40)), Koppen.Dfc)
	dfd := [12]f64{-40, -34, -22, -7, 6, 15, 19, 14, 5, -9, -29, -38}
	testing.expect_value(t, cls(dfd, flat(30)), Koppen.Dfd)
	testing.expect_value(t, cls(flat(-30), flat(10)), Koppen.EF)
	tundra := [12]f64{-25, -25, -22, -15, -5, 2, 5, 4, -1, -10, -18, -23}
	testing.expect_value(t, cls(tundra, flat(10)), Koppen.ET)
	// The seasons swap in the south: the same year is a different class.
	testing.expect(t, cls(med, dry, false) != Koppen.Csa)
}

@(test)
test_koppen_names :: proc(t: ^testing.T) {
	testing.expect_value(t, koppen_code(.Cfb), "Cfb")
	testing.expect_value(t, koppen_name(.Cfb), "Marine west coast")
	testing.expect_value(t, koppen_code(.Dwd), "Dwd")
	testing.expect_value(t, koppen_group(.BSk), u8('B'))
	for k in Koppen {
		if k == .Ocean {continue}
		g := koppen_group(k)
		testing.expectf(t, g >= 'A' && g <= 'E' && len(koppen_name(k)) > 0, "class %v", k)
	}
	testing.expect_value(t, len(Koppen) - 1, 30)
}

@(test)
test_planet_earth :: proc(t: ^testing.T) {
	data := #load("../../assets/planet/earth_relief.bin")
	r, ok := relief_decode(data)
	defer relief_destroy(&r)
	testing.expect(t, ok)
	p := planet_build(r)
	defer planet_destroy(&p)

	// Where the model puts each station (printed to look at; the fitting is a later part).
	for c in ([?]struct {
			name:     string,
			lat, lon: f64,
			want:     Koppen,
		}{{"Singapore", 1.35, 103.82, .Af}, {"Cairo", 30.04, 31.24, .BWh}, {"London", 51.51, -0.13, .Cfb}, {"Moscow", 55.76, 37.62, .Dfb}, {"Vostok", -78.46, 106.84, .EF}}) {
		got := planet_koppen_at(p, c.lat, c.lon)
		fmt.printf("%v: model %v, observed %v\n", c.name, koppen_code(got), koppen_code(c.want))
	}
	// Land by group (cells weighted by the cosine of their latitude), printed.
	share: [6]f64
	total := 0.0
	for j in 0 ..< p.land.height {
		wt := base.cos(climate_lat(p.land.height, j) * PI / 180)
		for i in 0 ..< p.land.width {
			k := p.koppen[j * p.land.width + i]
			if k == .Ocean {continue}
			share[int(koppen_group(k) - 'A')] += wt
			total += wt
		}
	}
	for g in 0 ..< 5 {fmt.printf("group %c: %.1f %%\n", 'A' + g, share[g] / total * 100)}

	// The pole is ice and the open Pacific is ocean.
	testing.expect_value(t, koppen_group(planet_koppen_at(p, -78.46, 106.84)), u8('E'))
	testing.expect_value(t, planet_koppen_at(p, 0, -140), Koppen.Ocean)

	// Sampling: Everest's own elevation is cold, and a place is warmer in its summer.
	jan := planet_climate_at(p, 51.51, -0.13, 0.5)
	jul := planet_climate_at(p, 51.51, -0.13, 6.5)
	testing.expect(t, jul.temperature > jan.temperature + 5)
	hi := planet_climate_at(p, 28, 86.9, 6.5)
	testing.expect(t, hi.elevation > 4000 && hi.temperature < 10)
	testing.expect(t, planet_relief_at(p, 31.5, 35.5) < 0)
	// A year wraps: the end of December meets the start of January.
	a := planet_climate_at(p, 40, 10, 11.99).temperature
	b := planet_climate_at(p, 40, 10, 0.01).temperature
	testing.expect(t, abs(a - b) < 0.5)

	// A second build hashes the same (the cross-OS value is pinned in a later part).
	q := planet_build(r)
	defer planet_destroy(&q)
	testing.expect_value(t, planet_hash(q), planet_hash(p))
	fmt.printf("planet hash: %#x\n", planet_hash(p))
}
