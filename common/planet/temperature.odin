package planet

import "common:base"
import "core:math"

// Temperature: albedo, a zonal energy balance around Earth's observed zonal means, the
// seasonal swing, and the lapse rate (docs/world.md, the planet model, steps 2-4).

// A climate cell covers CLIMATE_BLOCK x CLIMATE_BLOCK relief cells.
CLIMATE_BLOCK :: 4

// Surface albedos, from the textbook.
ALBEDO_SNOW :: 0.8
ALBEDO_LAND :: 0.2
ALBEDO_OCEAN :: 0.07

BUDYKO_B :: 0.2 // °C per W/m²
BAND_SHARE :: 0.25 // a surface shifts a quarter of its own difference from its band
LAPSE_PER_KM :: 6.5
LARGE_OCEAN_CELLS :: 400 // an ocean body this many climate cells wide is a large one
CONTINENTAL_KM :: 4000.0

// Earth's observed annual zonal-mean sea-level temperature at 0, 15, ... 90°, °C.
ZONAL_NORTH :: [7]f64{27, 25.5, 21, 13, 3, -10, -18}
ZONAL_SOUTH :: [7]f64{27, 25, 20, 12, 2, -15, -30}

// zonal_temperature is the observed annual zonal mean at sea level for a latitude.
zonal_temperature :: proc(lat: f64) -> f64 {
	table := ZONAL_NORTH if lat >= 0 else ZONAL_SOUTH
	x := min(abs(lat), 90) / 15
	k := min(int(x), 5)
	f := x - f64(k)
	return table[k] + (table[k + 1] - table[k]) * f
}

// Land is what the relief gives each climate cell, before any weather.
Land :: struct {
	width, height:  int,
	land_fraction:  []f32, // 0..1
	elevation:      []f32, // mean elevation in metres (land cells; sea level below it)
	is_land:        []bool, // more than half land
	large_ocean:    []bool, // water in a large ocean basin
	continentality: []f32, // 0 at the coast of a large ocean, 1 at CONTINENTAL_KM inland
}

land_destroy :: proc(l: ^Land) {
	delete(l.land_fraction)
	delete(l.elevation)
	delete(l.is_land)
	delete(l.large_ocean)
	delete(l.continentality)
	l^ = {}
}

// climate_lat is a climate row's centre latitude.
climate_lat :: proc(height, j: int) -> f64 {
	return 90 - (f64(j) + 0.5) * 180 / f64(height)
}

// land_build reduces the relief to the climate grid and finds the large oceans and each
// land cell's distance from one.
land_build :: proc(r: Relief, allocator := context.allocator) -> Land {
	w, h := r.width / CLIMATE_BLOCK, r.height / CLIMATE_BLOCK
	n := w * h
	l := Land {
		width          = w,
		height         = h,
		land_fraction  = make([]f32, n, allocator),
		elevation      = make([]f32, n, allocator),
		is_land        = make([]bool, n, allocator),
		large_ocean    = make([]bool, n, allocator),
		continentality = make([]f32, n, allocator),
	}
	for j in 0 ..< h {
		for i in 0 ..< w {
			sum, land := 0.0, 0
			for dj in 0 ..< CLIMATE_BLOCK {
				for di in 0 ..< CLIMATE_BLOCK {
					e := f64(relief_at(r, i * CLIMATE_BLOCK + di, j * CLIMATE_BLOCK + dj))
					sum += e
					if e > 0 {land += 1}
				}
			}
			k := j * w + i
			l.land_fraction[k] = f32(land) / (CLIMATE_BLOCK * CLIMATE_BLOCK)
			l.elevation[k] = f32(sum / (CLIMATE_BLOCK * CLIMATE_BLOCK))
			l.is_land[k] = land * 2 > CLIMATE_BLOCK * CLIMATE_BLOCK
		}
	}
	find_large_oceans(&l)
	find_continentality(&l)
	return l
}

// find_large_oceans marks the water cells of every connected ocean body of at least
// LARGE_OCEAN_CELLS cells (longitude wraps; the rows beyond the poles do not exist).
@(private = "file")
find_large_oceans :: proc(l: ^Land) {
	w, h := l.width, l.height
	seen := make([]bool, w * h, context.temp_allocator)
	stack := make([dynamic]int, context.temp_allocator)
	body := make([dynamic]int, context.temp_allocator)
	for start in 0 ..< w * h {
		if l.is_land[start] || seen[start] {continue}
		clear(&body)
		append(&stack, start)
		seen[start] = true
		for len(stack) > 0 {
			k := pop(&stack)
			append(&body, k)
			i, j := k % w, k / w
			for d in ([4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
				nj := j + d[1]
				if nj < 0 || nj >= h {continue}
				nk := nj * w + (i + d[0] + w) % w
				if !l.is_land[nk] && !seen[nk] {
					seen[nk] = true
					append(&stack, nk)
				}
			}
		}
		if len(body) >= LARGE_OCEAN_CELLS * w / 512 * h / 256 {
			for k in body {l.large_ocean[k] = true}
		}
	}
}

// find_continentality is the distance, over the grid, from a land cell to the nearest
// large ocean, as a share of CONTINENTAL_KM. (Along the wind, once the winds exist.)
@(private = "file")
find_continentality :: proc(l: ^Land) {
	w, h := l.width, l.height
	cell_km := 40075.0 / f64(w)
	dist := make([]f32, w * h, context.temp_allocator)
	for k in 0 ..< w * h {
		dist[k] = 0 if l.large_ocean[k] else 1e9
	}
	relax :: proc(l: ^Land, dist: []f32, i, j: int, cell_km: f64) {
		w, h := l.width, l.height
		lat := climate_lat(h, j)
		east := max(cell_km * f64(base.cos(lat * PI / 180)), 1)
		k := j * w + i
		for dj in -1 ..= 1 {
			nj := j + dj
			if nj < 0 || nj >= h {continue}
			for di in -1 ..= 1 {
				if di == 0 && dj == 0 {continue}
				nk := nj * w + (i + di + w) % w
				dx := east * f64(di)
				dy := cell_km * f64(dj)
				step := f32(math.sqrt(dx * dx + dy * dy))
				if dist[nk] + step < dist[k] {dist[k] = dist[nk] + step}
			}
		}
	}
	for _ in 0 ..< 4 { 	// forward and backward sweeps until the distances settle
		for j in 0 ..< h {for i in 0 ..< w {relax(l, dist, i, j, cell_km)}}
		for j := h - 1; j >= 0; j -= 1 {
			for i := w - 1; i >= 0; i -= 1 {relax(l, dist, i, j, cell_km)}
		}
	}
	for k in 0 ..< w * h {
		l.continentality[k] = 0 if !l.is_land[k] else min(dist[k] / CONTINENTAL_KM, 1)
	}
}

// Temperatures holds each climate cell's monthly temperature in 0.1 °C.
Temperatures :: struct {
	month: [12][]i16,
}

temperatures_destroy :: proc(t: ^Temperatures) {
	for m in 0 ..< 12 {delete(t.month[m])}
	t^ = {}
}

// temperatures_build is the model's temperature: the year is run three times so each month's
// snow and sea ice come from the month before.
temperatures_build :: proc(l: Land, allocator := context.allocator) -> Temperatures {
	w, h := l.width, l.height
	n := w * h
	days := MONTH_DAYS
	temp: [12][]f64
	for m in 0 ..< 12 {temp[m] = make([]f64, n, context.temp_allocator)}
	absorbed: [12][]f64
	for m in 0 ..< 12 {absorbed[m] = make([]f64, n, context.temp_allocator)}
	band_mean := make([]f64, h, context.temp_allocator)

	// The sunlight by latitude row and month, and with the lag of the swing.
	sun: [12][]f64
	lagged: [2][12][]f64 // [0] land (1 month), [1] sea (2 months)
	for m in 0 ..< 12 {
		sun[m] = make([]f64, h, context.temp_allocator)
		lagged[0][m] = make([]f64, h, context.temp_allocator)
		lagged[1][m] = make([]f64, h, context.temp_allocator)
		for j in 0 ..< h {
			lat := climate_lat(h, j)
			sun[m][j] = insolation(lat, days[m])
			lagged[0][m][j] = insolation(lat, days[m] - 30.4)
			lagged[1][m][j] = insolation(lat, days[m] - 60.8)
		}
	}

	snow_pass := false
	for _ in 0 ..< 4 { 	// pass 0: no snow; passes 1-3: snow from the previous month
		for m in 0 ..< 12 {
			prev := temp[(m + 11) % 12]
			for j in 0 ..< h {
				for i in 0 ..< w {
					k := j * w + i
					a: f64
					if l.is_land[k] {
						a = ALBEDO_LAND
						if snow_pass && prev[k] < 0 {a = ALBEDO_SNOW}
					} else {
						a = ALBEDO_OCEAN
						if snow_pass && prev[k] < -1.8 {a = ALBEDO_SNOW}
					}
					absorbed[m][k] = sun[m][j] * (1 - a)
				}
			}
		}
		for j in 0 ..< h {
			s := 0.0
			for i in 0 ..< w {
				for m in 0 ..< 12 {s += absorbed[m][j * w + i]}
			}
			band_mean[j] = s / f64(w * 12)
		}
		for j in 0 ..< h {
			lat := climate_lat(h, j)
			for i in 0 ..< w {
				k := j * w + i
				mean := 0.0
				for m in 0 ..< 12 {mean += absorbed[m][k]}
				mean /= 12
				annual := zonal_temperature(lat) + BAND_SHARE * BUDYKO_B * (mean - band_mean[j])
				if l.is_land[k] {annual -= LAPSE_PER_KM * max(f64(l.elevation[k]), 0) / 1000}

				// The seasonal swing: local, land and sea albedo only, lagged.
				albedo, amp, which: f64
				if l.is_land[k] {
					albedo, amp, which = ALBEDO_LAND, 0.18 + 0.55 * f64(l.continentality[k]), 0
				} else {
					albedo, amp, which = ALBEDO_OCEAN, 0.08, 1
				}
				swing_mean := 0.0
				for m in 0 ..< 12 {swing_mean += lagged[int(which)][m][j]}
				swing_mean /= 12
				for m in 0 ..< 12 {
					temp[m][k] =
						annual +
						BUDYKO_B * amp * (1 - albedo) * (lagged[int(which)][m][j] - swing_mean)
				}
			}
		}
		snow_pass = true
	}

	out: Temperatures
	for m in 0 ..< 12 {
		out.month[m] = make([]i16, n, allocator)
		for k in 0 ..< n {
			out.month[m][k] = i16(clamp(math.round(temp[m][k] * 10), -3000, 3000))
		}
	}
	return out
}
