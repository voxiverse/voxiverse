package planet

import "core:fmt"
import "core:testing"

Station :: struct {
	name:     string,
	lat, lon: f64,
	want:     Koppen,
}

STATIONS :: [?]Station {
	{"Singapore", 1.35, 103.82, .Af},
	{"Manaus", -3.12, -60.02, .Af},
	{"Kinshasa", -4.32, 15.31, .Aw},
	{"Mumbai", 19.08, 72.88, .Am},
	{"Miami", 25.76, -80.19, .Am},
	{"Darwin", -12.46, 130.84, .Aw},
	{"Cairo", 30.04, 31.24, .BWh},
	{"Riyadh", 24.71, 46.68, .BWh},
	{"Phoenix", 33.45, -112.07, .BWh},
	{"Alice Springs", -23.70, 133.88, .BWh},
	{"Lima", -12.05, -77.04, .BWh},
	{"Kashgar", 39.47, 75.99, .BWk},
	{"Denver", 39.74, -104.99, .BSk},
	{"Niamey", 13.51, 2.11, .BSh},
	{"Rome", 41.90, 12.50, .Csa},
	{"Perth", -31.95, 115.86, .Csa},
	{"San Francisco", 37.77, -122.42, .Csb},
	{"Cape Town", -33.92, 18.42, .Csb},
	{"Santiago", -33.45, -70.67, .Csb},
	{"London", 51.51, -0.13, .Cfb},
	{"Paris", 48.86, 2.35, .Cfb},
	{"Wellington", -41.29, 174.78, .Cfb},
	{"Buenos Aires", -34.60, -58.38, .Cfa},
	{"Shanghai", 31.23, 121.47, .Cfa},
	{"Atlanta", 33.75, -84.39, .Cfa},
	{"Sydney", -33.87, 151.21, .Cfa},
	{"Chicago", 41.88, -87.63, .Dfa},
	{"Moscow", 55.76, 37.62, .Dfb},
	{"Montreal", 45.50, -73.57, .Dfb},
	{"Beijing", 39.90, 116.40, .Dwa},
	{"Fairbanks", 64.84, -147.72, .Dfc},
	{"Yakutsk", 62.03, 129.73, .Dfd},
	{"Utqiagvik", 71.29, -156.79, .ET},
	{"Vostok", -78.46, 106.84, .EF},
}

// station_class is the class of the station's cell, or of the nearest land cell within
// two cells when the cell is mostly sea (a coastal city's cell can be).
station_class :: proc(p: Planet, s: Station) -> Koppen {
	w, h := p.land.width, p.land.height
	i0 := clamp(int((s.lon + 180) / 360 * f64(w)), 0, w - 1)
	j0 := clamp(int((90 - s.lat) / 180 * f64(h)), 0, h - 1)
	best, bd := Koppen.Ocean, 99
	for dj in -2 ..= 2 {
		for di in -2 ..= 2 {
			j := j0 + dj
			if j < 0 || j >= h {continue}
			k := Koppen.Ocean
			k = p.koppen[j * w + (i0 + di + w) % w]
			d := dj * dj + di * di
			if k != .Ocean && d < bd {best, bd = k, d}
		}
	}
	return best
}

// station_score counts the stations whose class matches in the first letter and in the
// first two letters, printing the table when `show`.
station_score :: proc(p: Planet, show: bool) -> (first, two: int) {
	for s in STATIONS {
		got := station_class(p, s)
		g, w := koppen_code(got), koppen_code(s.want)
		a := len(g) > 0 && g[0] == w[0]
		b := a && len(g) > 1 && len(w) > 1 && g[1] == w[1]
		if a {first += 1}
		if b {two += 1}
		if show {fmt.printfln("%-14s model %-5s observed %-5s %s", s.name, g, w, "ok" if a else "")}
	}
	return
}

@(test)
test_stations :: proc(t: ^testing.T) {
	r, ok := relief_decode(#load("../../assets/planet/earth_relief.bin"))
	defer relief_destroy(&r)
	testing.expect(t, ok)
	p := planet_build(r)
	defer planet_destroy(&p)
	first, two := station_score(p, true)
	fmt.printfln("stations: %d/34 first letter, %d/34 two letters", first, two)
	// The design's bar is 26 and 20 (docs/world.md); until the model reaches it this holds
	// the ground the fit has won, so a change that loses stations is seen.
	testing.expectf(t, first >= 22 && two >= 12, "stations %d and %d, hold 22 and 12", first, two)
}
