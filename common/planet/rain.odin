package planet

import "common:base"
import "core:math"

// Moisture and precipitation (docs/world.md, the planet model, step 7): the ocean gives
// vapour in proportion to its saturation vapour pressure, the month's wind carries it
// cell by cell, and land cells rain a fraction of what the air carries.

SWEEPS :: 50 // semi-Lagrangian sweeps of the moisture field
SWEEP_CELLS :: 2.153 // cells the air moves in one sweep
RAIN_BASE :: 0.0416 // the share of the air's vapour that rains per cell, before the belts
FRONT_GAIN :: 6.19 // frontal lifting along the polar front, relative to plain flow
OROGRAPHIC :: 0.174 // extra rain share per km of ground rising along the wind
COLD_DRY :: 0.302 // rain over a cold current's coast is this share
MM_PER_VAPOUR :: 77.0 // millimetres a month for one hPa of vapour rained out per sweep

// vapour_pressure is the saturation vapour pressure in hPa: 6.1 at 0 °C, 42.4 at 30 °C.
vapour_pressure :: proc(celsius: f64) -> f64 {
	return 6.1 * base.exp(0.0646 * celsius)
}

// belt_factor is how readily air rains, by distance from the ITCZ in degrees: convergence
// near it, subsidence (the hot deserts) at the subtropical highs, moderate in the westerlies.
belt_factor :: proc(d: f64) -> f64 {
	pts := [?][2]f64{{0, 1.0}, {8, 0.9}, {15, 0.4}, {21, 0.02}, {32, 0.01}, {40, 0.3}, {60, 0.5}}
	if d >= pts[len(pts) - 1][0] {return pts[len(pts) - 1][1]}
	for i in 1 ..< len(pts) {
		if d < pts[i][0] {
			a, b := pts[i - 1], pts[i]
			return a[1] + (b[1] - a[1]) * (d - a[0]) / (b[0] - a[0])
		}
	}
	return pts[len(pts) - 1][1]
}

// Precipitation holds each climate cell's monthly rain in mm.
Precipitation :: struct {
	month: [12][]u16,
}

precipitation_destroy :: proc(p: ^Precipitation) {
	for m in 0 ..< 12 {delete(p.month[m])}
	p^ = {}
}

@(private = "file")
sample :: proc(q: []f64, w, h: int, x, y: f64) -> f64 {
	yy := clamp(y, 0, f64(h - 1))
	j0 := int(yy)
	j1 := min(j0 + 1, h - 1)
	fy := yy - f64(j0)
	xf := x - math.floor(x)
	i0 := int(xf * f64(w)) % w
	i1 := (i0 + 1) % w
	fx := xf * f64(w) - f64(int(xf * f64(w)))
	top := q[j0 * w + i0] * (1 - fx) + q[j0 * w + i1] * fx
	bot := q[j1 * w + i0] * (1 - fx) + q[j1 * w + i1] * fx
	return top * (1 - fy) + bot * fy
}

// precipitation_build runs the moisture sweeps for each month.
precipitation_build :: proc(
	l: Land,
	t: Temperatures,
	winds: [12][]Wind,
	c: Currents,
	allocator := context.allocator,
) -> Precipitation {
	w, h := l.width, l.height
	n := w * h
	days := MONTH_DAYS
	out: Precipitation
	q := make([]f64, n, context.temp_allocator)
	nq := make([]f64, n, context.temp_allocator)
	rain := make([]f64, n, context.temp_allocator)
	belt := make([]f64, n, context.temp_allocator)
	front := make([]f64, n, context.temp_allocator)
	shares := make([]f64, n, context.temp_allocator)
	mix := make([]f64, h, context.temp_allocator)
	for j in 0 ..< h {
		mix[j] = 0.02 + 0.25 * clamp((abs(climate_lat(h, j)) - 20) / 20, 0, 1)
	}
	for m in 0 ..< 12 {
		decl := solar_declination(days[m])
		s := decl / AXIAL_TILT
		itcz := itcz_lat(l, decl)
		for j in 0 ..< h {
			lat := climate_lat(h, j)
			hs := 1.0 if lat >= 0 else -1.0
			pf := 60 + 5 * s * hs
			for i in 0 ..< w {
				k := j * w + i
				belt[k] = belt_factor(abs(lat - itcz[i]))
				front[k] = max(1 - abs(abs(lat) - pf) / 12, 0)
			}
		}
		for k in 0 ..< n {
			q[k] = vapour_pressure(f64(t.month[m][k]) / 10) if !l.is_land[k] else 0
			nq[k] = q[k]
		}
		// what a cell rains of its air does not change between sweeps
		for j in 0 ..< h {
			for i in 0 ..< w {
				k := j * w + i
				if !l.is_land[k] {continue}
				wd := winds[m][k]
				u, v := f64(wd.x) / WIND_UNIT, f64(wd.y) / WIND_UNIT
				ui := i - int(math.round(u)) // the cell upwind
				uj := j + int(math.round(v))
				rise: f64
				if uj >= 0 && uj < h {
					rise = f64(l.elevation[k] - l.elevation[uj * w + (ui + w) % w]) / 1000
				}
				damp := clamp(belt[k] * 3, 0.1, 1)
				share := RAIN_BASE * (belt[k] + FRONT_GAIN * front[k] * 0.5)
				share += OROGRAPHIC * clamp(rise, 0, 2) * damp
				if rise < 0 {share *= 0.7} 	// descending air
				if c.cold[k] {share *= COLD_DRY}
				shares[k] = min(share * SWEEP_CELLS, 0.9)
			}
		}
		for _ in 0 ..< SWEEPS {
			for j in 0 ..< h {
				for i in 0 ..< w {
					k := j * w + i
					if !l.is_land[k] {continue} 	// (the sea's vapour is in nq from the start)
					wd := winds[m][k]
					u, v := f64(wd.x) / WIND_UNIT, f64(wd.y) / WIND_UNIT
					x := (f64(i) + 0.5 - u * SWEEP_CELLS) / f64(w)
					y := f64(j) + v * SWEEP_CELLS
					nq[k] = sample(q, w, h, x - 0.5 / f64(w), y)
				}
			}
			// Mixing in every direction, stronger poleward of 20°.
			for j in 0 ..< h {
				for i in 0 ..< w {
					k := j * w + i
					if !l.is_land[k] {q[k] = nq[k]; continue}
					nb := nq[j * w + (i + 1) % w] + nq[j * w + (i + w - 1) % w]
					nb += nq[max(j - 1, 0) * w + i] + nq[min(j + 1, h - 1) * w + i]
					q[k] = nq[k] * (1 - mix[j]) + nb / 4 * mix[j]
				}
			}
			for j in 0 ..< h {
				for i in 0 ..< w {
					k := j * w + i
					if !l.is_land[k] {rain[k] = 0; continue}
					share := shares[k]
					r := q[k] * share
					wet := clamp(r / 2, 0, 1)
					q[k] -= r
					q[k] += r * (0.15 + 0.6 * wet) // evapotranspiration, more where wet
					rain[k] = r
				}
			}
		}
		out.month[m] = make([]u16, n, allocator)
		for k in 0 ..< n {
			out.month[m][k] = u16(clamp(rain[k] * MM_PER_VAPOUR, 0, 65535))
		}
	}
	return out
}
