package planet

import "core:testing"

@(test)
test_insolation_textbook :: proc(t: ^testing.T) {
	june := solar_declination(172)
	testing.expect(t, abs(june - 23.44) < 0.05)
	testing.expect(t, abs(noon_sun_altitude(40, june) - 73.5) < 0.1)
	// 24 h of daylight north of 66.5°N at the June solstice, darkness south of 66.5°S.
	testing.expect_value(t, daylight_hours(67, june), 24)
	testing.expect_value(t, daylight_hours(80, june), 24)
	testing.expect_value(t, daylight_hours(-67, june), 0)
	testing.expect_value(t, daylight_hours(-90, june), 0)
	testing.expect_value(t, daylight_hours(90, june), 24)
	testing.expect(t, abs(daylight_hours(0, june) - 12) < 0.01)
	testing.expect(t, daylight_hours(65, june) < 24)
	// The December solstice mirrors it.
	dec := solar_declination(355)
	testing.expect_value(t, daylight_hours(-80, dec), 24)
	testing.expect_value(t, daylight_hours(80, dec), 0)
}

@(test)
test_insolation_values :: proc(t: ^testing.T) {
	// Equinox at the equator: S0/π; the polar summer beats the equator's day.
	q := insolation(0, 80)
	testing.expect(t, abs(q - SOLAR_CONSTANT / PI) < 1)
	testing.expect(t, abs(insolation(-90, 355) - 550) < 40)
	testing.expect_value(t, insolation(-90, 172), 0)
	// A year's mean falls from the equator to the poles.
	annual :: proc(lat: f64) -> f64 {
		sum := 0.0
		for d in MONTH_DAYS {sum += insolation(lat, d)}
		return sum / 12
	}
	testing.expect(t, annual(0) > annual(30))
	testing.expect(t, annual(30) > annual(60))
	testing.expect(t, annual(60) > annual(90))
	testing.expect(t, abs(annual(40) - annual(-40)) < 15)
}
