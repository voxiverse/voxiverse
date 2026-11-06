package planet

import "common:base"
import "core:math"

// Pressure belts, prevailing winds and ocean currents (docs/world.md, the planet model,
// steps 5 and 6). Global constants only: no place has a tuning of its own.

WIND_UNIT :: 100 // a Wind component of 100 is a unit of wind
BASIN_KM :: 4000.0 // basins narrower than this have no boundary currents
COAST_KM :: 1500.0 // a boundary current reaches this far from the shore
WARM_WEST :: 3.0 // °C, the western side of a basin (an east coast)
COLD_EAST :: -4.0 // °C, the eastern side of a basin (a west coast)
DRIFT :: 8.0 // °C, the North Atlantic Drift
COASTAL_SHARE :: 0.6 // the share of the anomaly a coast takes when the wind is onshore

Wind :: [2]i8 // east, north; WIND_UNIT is a unit

// Basin gives, for each water cell of a large ocean, which side of its basin it is on:
// +1 the western side (land to its west is nearer: an east coast), -1 the eastern side,
// 0 neither (open, or a narrow sea); `coast` is the distance to that land in km.
Basin :: struct {
	side:  []i8,
	coast: []f32,
}

basin_destroy :: proc(b: ^Basin) {
	delete(b.side)
	delete(b.coast)
	b^ = {}
}

basin_build :: proc(l: Land, allocator := context.allocator) -> Basin {
	w, h := l.width, l.height
	b := Basin {
		side  = make([]i8, w * h, allocator),
		coast = make([]f32, w * h, allocator),
	}
	cell_km := 40075.0 / f64(w)
	for j in 0 ..< h {
		east_km := max(cell_km * f64(base.cos(climate_lat(h, j) * PI / 180)), 1)
		// For each cell, the cells to the nearest land west and east along the parallel.
		west := make([]int, w, context.temp_allocator)
		east := make([]int, w, context.temp_allocator)
		NONE :: 1 << 30
		last := NONE
		for pass in 0 ..< 2 { 	// twice round, so the wrap-around is seen
			for i in 0 ..< w {
				k := j * w + i
				if l.is_land[k] {last = 0} else if last != NONE {last += 1}
				if pass == 1 {west[i] = last}
			}
		}
		last = NONE
		for pass in 0 ..< 2 {
			for i := w - 1; i >= 0; i -= 1 {
				k := j * w + i
				if l.is_land[k] {last = 0} else if last != NONE {last += 1}
				if pass == 1 {east[i] = last}
			}
		}
		for i in 0 ..< w {
			k := j * w + i
			if l.is_land[k] || !l.large_ocean[k] {continue}
			if west[i] == NONE || east[i] == NONE {continue}
			if f64(west[i] + east[i]) * east_km < BASIN_KM {continue}
			if west[i] < east[i] {
				b.side[k] = 1
				b.coast[k] = f32(f64(west[i]) * east_km)
			} else {
				b.side[k] = -1
				b.coast[k] = f32(f64(east[i]) * east_km)
			}
		}
	}
	return b
}

// itcz_lat gives, per longitude column, the latitude of the ITCZ in a month: 5° into the
// summer hemisphere over ocean, pulled to about 13° over a large land mass.
itcz_lat :: proc(l: Land, declination: f64, allocator := context.temp_allocator) -> []f64 {
	w, h := l.width, l.height
	share := make([]f64, w, context.temp_allocator)
	rows := 0
	for j in 0 ..< h {
		if abs(climate_lat(h, j)) > 20 {continue}
		rows += 1
		for i in 0 ..< w {
			if l.is_land[j * w + i] {share[i] += 1}
		}
	}
	reach := max(w / 64, 1)
	out := make([]f64, w, allocator)
	s := declination / AXIAL_TILT
	for i in 0 ..< w {
		sum := 0.0
		for d in -reach ..= reach {sum += share[(i + d + w) % w]}
		land := sum / f64(rows * (2 * reach + 1))
		out[i] = (5 + 8 * min(land * 2, 1)) * s
	}
	return out
}

// land_share is the share of land cells among the cells of column i (and its neighbours
// within `reach`) whose latitudes are between lat_a and lat_b.
@(private = "file")
land_share :: proc(l: Land, i, reach: int, lat_a, lat_b: f64) -> f64 {
	w, h := l.width, l.height
	lo, hi := min(lat_a, lat_b), max(lat_a, lat_b)
	n, land := 0, 0
	for j in 0 ..< h {
		lat := climate_lat(h, j)
		if lat < lo || lat > hi {continue}
		for d in -reach ..= reach {
			n += 1
			if l.is_land[j * w + (i + d + w) % w] {land += 1}
		}
	}
	return f64(land) / f64(max(n, 1))
}

// winds_build is the prevailing surface wind for each cell in a month: trades, westerlies
// and polar easterlies about the month's belts; the summer monsoon where land lies
// poleward of a sea; the subtropical highs' asymmetric flanks.
winds_build :: proc(l: Land, b: Basin, month: int, allocator := context.allocator) -> []Wind {
	w, h := l.width, l.height
	days := MONTH_DAYS
	decl := solar_declination(days[month])
	s := decl / AXIAL_TILT
	itcz := itcz_lat(l, decl)
	reach := max(w / 64, 1)
	out := make([]Wind, w * h, allocator)
	for j in 0 ..< h {
		lat := climate_lat(h, j)
		hs := 1.0 if lat >= 0 else -1.0
		front := 60 + 5 * s * hs // the polar front, in degrees from the equator
		summer := s * hs > 0
		for i in 0 ..< w {
			k := j * w + i
			rel := lat - itcz[i]
			sgn := 1.0 if rel >= 0 else -1.0
			d := abs(rel)
			u, v: f64
			switch {
			case d < 3:
				u, v = -0.2, 0
			case d < 27:
				u, v = -0.8, -sgn * 0.5
			case abs(lat) < front:
				u, v = 0.8, sgn * 0.3
			case:
				u, v = -0.6, -sgn * 0.3
			}
			// The subtropical highs' flanks: poleward on the west, equatorward on the east.
			if d >= 15 && d < 40 && b.side[k] != 0 {
				if b.side[k] > 0 {v += sgn * 0.6} else {v -= sgn * 0.3}
			}
			// The monsoon: onshore and westerly in the summer, where the sea is equatorward
			// and the land poleward.
			if summer && abs(lat) > 5 && abs(lat) < 30 {
				poleward := land_share(l, i, reach, lat + hs * 10, lat + hs * 25)
				equatorward := land_share(l, i, reach, lat - hs * 15, lat)
				if poleward > 0.5 && equatorward < 0.5 {u, v = 0.7, hs * 0.2}
			}
			out[k] = {i8(math.round(u * WIND_UNIT)), i8(math.round(v * WIND_UNIT))}
		}
	}
	return out
}

// Currents: the ocean's surface temperature anomalies, and where coasts are cooled by an
// upwelling.
Currents :: struct {
	anomaly: [12][]f32, // °C added to the cell
	cold:    []bool, // a cold current or its coast: rain is suppressed
}

currents_destroy :: proc(c: ^Currents) {
	for m in 0 ..< 12 {delete(c.anomaly[m])}
	delete(c.cold)
	c^ = {}
}

// currents_build finds the anomalies from the basins; coastal land takes COASTAL_SHARE of
// the sea's anomaly where the wind blows onshore.
currents_build :: proc(
	l: Land,
	b: Basin,
	winds: [12][]Wind,
	allocator := context.allocator,
) -> Currents {
	w, h := l.width, l.height
	c := Currents {
		cold = make([]bool, w * h, allocator),
	}
	sea := make([]f32, w * h, context.temp_allocator)
	for j in 0 ..< h {
		lat := abs(climate_lat(h, j))
		for i in 0 ..< w {
			k := j * w + i
			if b.side[k] == 0 {continue}
			if lat < 10 || lat > 45 {continue}
			near := f32(max(1 - f64(b.coast[k]) / COAST_KM, 0))
			sea[k] = near * f32(WARM_WEST if b.side[k] > 0 else COLD_EAST)
		}
	}
	// The North Atlantic Drift: the north-east Atlantic's large ocean, 45-70°N.
	for j in 0 ..< h {
		lat := climate_lat(h, j)
		if lat < 45 || lat > 70 {continue}
		for i in 0 ..< w {
			k := j * w + i
			lon := -180 + (f64(i) + 0.5) * 360 / f64(w)
			if l.large_ocean[k] && lon > -50 && lon < 15 {sea[k] = DRIFT}
		}
	}
	for m in 0 ..< 12 {
		c.anomaly[m] = make([]f32, w * h, allocator)
		copy(c.anomaly[m], sea)
		for j in 0 ..< h {
			for i in 0 ..< w {
				k := j * w + i
				if !l.is_land[k] {continue}
				// Coastal land: look upwind for the sea.
				wd := winds[m][k]
				if wd == {} {continue}
				mag := math.sqrt(f64(wd.x) * f64(wd.x) + f64(wd.y) * f64(wd.y))
				for step in 1 ..= 2 {
					ui := i - int(math.round(f64(wd.x) / mag * f64(step)))
					uj := j + int(math.round(f64(wd.y) / mag * f64(step)))
					if uj < 0 || uj >= h {break}
					uk := uj * w + (ui + w) % w
					if l.is_land[uk] {break}
					if sea[uk] != 0 {
						c.anomaly[m][k] = sea[uk] * COASTAL_SHARE
						break
					}
				}
			}
		}
	}
	for k in 0 ..< w * h {
		if sea[k] < 0 {c.cold[k] = true}
		for m in 0 ..< 12 {
			if l.is_land[k] && c.anomaly[m][k] < 0 {c.cold[k] = true}
		}
	}
	return c
}

// currents_apply adds the anomalies to the temperatures.
currents_apply :: proc(t: ^Temperatures, c: Currents) {
	for m in 0 ..< 12 {
		for k in 0 ..< len(t.month[m]) {
			t.month[m][k] += i16(math.round(f64(c.anomaly[m][k]) * 10))
		}
	}
}
