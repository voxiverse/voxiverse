package planet

import "common:base"

// Daily-mean top-of-atmosphere sunlight (docs/world.md, the planet model, step 1).

SOLAR_CONSTANT :: 1361.0 // W/m²
AXIAL_TILT :: 23.44 // degrees
PI :: 3.14159265358979323846

// Mid-month days of the year (month 0 = January), by the 365-day calendar.
MONTH_DAYS :: [12]f64{15.5, 45, 74.5, 105, 135.5, 166, 196.5, 227.5, 258, 288.5, 319, 349.5}

// solar_declination is the latitude of the sub-solar point, in degrees, on a day of the year.
solar_declination :: proc(day: f64) -> f64 {
	return AXIAL_TILT * base.sin(2 * PI * (day - 80) / 365)
}

// acos_f64 inverts base.cos by bisection: the same answer on every OS, and the planet
// build calls it a few thousand times only. x is clamped to -1..1.
acos_f64 :: proc(x: f64) -> f64 {
	if x >= 1 {return 0}
	if x <= -1 {return PI}
	lo, hi := 0.0, PI
	v := x
	for _ in 0 ..< 60 {
		mid := 0.5 * (lo + hi)
		if base.cos(mid) > v {lo = mid} else {hi = mid}
	}
	return 0.5 * (lo + hi)
}

// day_length_angle is the half day length h0 in radians (0 polar night, π polar day).
day_length_angle :: proc(lat, declination: f64) -> f64 {
	phi, delta := lat * PI / 180, declination * PI / 180
	cp, cd := base.cos(phi), base.cos(delta)
	if abs(cp) < 1e-12 { 	// at a pole: the sun is up all day or none
		return PI if phi * delta > 0 else 0
	}
	t := -(base.sin(phi) / cp) * (base.sin(delta) / cd)
	return acos_f64(t)
}

// daylight_hours is the length of the day at a latitude, in hours.
daylight_hours :: proc(lat, declination: f64) -> f64 {
	return 24 * day_length_angle(lat, declination) / PI
}

// noon_sun_altitude is the sun's height at local noon, in degrees.
noon_sun_altitude :: proc(lat, declination: f64) -> f64 {
	return 90 - abs(lat - declination)
}

// insolation is the daily-mean top-of-atmosphere insolation in W/m² at a latitude.
insolation :: proc(lat, day: f64) -> f64 {
	delta := solar_declination(day)
	h0 := day_length_angle(lat, delta)
	phi, d := lat * PI / 180, delta * PI / 180
	return(
		SOLAR_CONSTANT /
		PI *
		(h0 * base.sin(phi) * base.sin(d) + base.cos(phi) * base.cos(d) * base.sin(h0)) \
	)
}
