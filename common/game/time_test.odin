package game

import "core:testing"

@(test)
test_time_of_day :: proc(t: ^testing.T) {
	rules := RULES_DEFAULTS
	day := advance_time(0.5, f64(rules.day_length), &rules)
	testing.expect(t, abs(day - 1.5) < 1e-12, "a day_length later is a day later")
	testing.expect(t, abs(time_of_day(day) - 0.5) < 1e-12)
	rules.daylight_cycle = false
	testing.expect_value(t, advance_time(3.25, 1000, &rules), 3.25)

	// Setting the time of day keeps the day, even going back.
	testing.expect_value(t, set_time_of_day(7.8, 0.25), 7.25)
	Case :: struct {
		text: string,
		want: f64,
	}
	for c in ([]Case{{"midnight", 0}, {"sunrise", 0.25}, {"noon", 0.5}, {"sunset", 0.75}, {"0.125", 0.125}, {"1", 1}}) {
		f, ok := parse_time_of_day(c.text)
		testing.expectf(t, ok && f == c.want, "%s: %v %v", c.text, f, ok)
	}
	for bad in ([]string{"", "dusk", "-0.1", "1.5", "nan", "inf"}) {
		_, ok := parse_time_of_day(bad)
		testing.expectf(t, !ok, "%q parsed", bad)
	}
	testing.expect(t, !time_valid(-1) && !time_valid(2 * MAX_WORLD_TIME) && time_valid(0))
}
