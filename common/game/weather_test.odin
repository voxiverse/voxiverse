package game

import "core:math"
import "core:testing"

// The same seed and time give the same weather, every time and in any order (the server
// and the clients each work it out), and different worlds have different weather.
@(test)
test_weather_is_a_function_of_seed_and_time :: proc(t: ^testing.T) {
	a, b := weather_seed(42, 7), weather_seed(43, 7)
	testing.expect(t, a != b && a != weather_seed(42, 8))
	kinds_a, kinds_b: [Weather_Kind]int
	same := 0
	for i in 0 ..< 3000 {
		at := 1 + f64(i) * 0.0137
		w := weather_at(a, at)
		testing.expect_value(t, weather_at(a, at), w)
		testing.expect_value(t, weather_at(weather_seed(42, 7), at), w)
		kinds_a[weather_kind_of(w)] += 1
		kinds_b[weather_kind_of(weather_at(b, at))] += 1
		if weather_at(b, at) == w {same += 1}
	}
	testing.expectf(t, same < 2000, "two worlds' weather is mostly the same (%d of 3000)", same)
	// Over forty days every kind of spell comes.
	for k in ([]Weather_Kind{.Clear, .Overcast, .Rain, .Storm, .Fog}) {
		testing.expectf(t, kinds_a[k] > 0, "%v never came: %v", k, kinds_a)
	}
	// The values travel exactly: a pinned day of one seed.
	pinned := weather_at(weather_seed(1, 1), 12.5)
	testing.expect_value(t, pinned, weather_at(weather_seed(1, 1), 12.5))
}

// The weather never jumps: across spells and mists, a step of a tick moves no value far,
// and every value stays 0..1.
@(test)
test_weather_is_continuous :: proc(t: ^testing.T) {
	seed := weather_seed(99, 3)
	TICK :: 1.0 / (1200.0 * 30) // a tick of the default day, in days
	prev := weather_at(seed, 1)
	worst: f32
	for i in 1 ..= 400_000 {
		at := 1 + f64(i) * TICK * 3 // three ticks a step, over 33 days
		w := weather_at(seed, at)
		d := max(
			abs(w.cover - prev.cover),
			abs(w.rain - prev.rain),
			abs(w.storm - prev.storm),
			abs(w.fog - prev.fog),
			abs(w.wind - prev.wind),
		)
		worst = max(worst, d)
		for v in ([]f32{w.cover, w.rain, w.storm, w.fog, w.wind}) {
			testing.expectf(t, v >= 0 && v <= 1, "a value out of 0..1 at %v: %v", at, w)
		}
		prev = w
	}
	testing.expectf(t, worst < 0.01, "the weather jumped by %v in three ticks", worst)
}

// A world's first day is clear and has no mist; a forced kind stands whatever the time.
@(test)
test_weather_first_day_and_forced :: proc(t: ^testing.T) {
	for seed in ([]u64{1, 2, 3, 0xdead_beef}) {
		for i in 0 ..< 100 {
			at := f64(i) / 100 * (1 - SPELL_DAYS * SPELL_BLEND)
			testing.expect_value(t, weather_at(seed, at), WEATHER_OF[.Clear])
		}
	}
	for k in Weather_Kind {
		for at in ([]f64{0.3, 5.25, 77.9}) {
			testing.expect_value(t, weather_at(5, at, k), WEATHER_OF[k])
			testing.expect_value(t, weather_kind_of(weather_at(5, at, k)), k)
		}
		name := WEATHER_NAMES[k]
		back, ok := weather_kind_by_name(name)
		testing.expect(t, ok && back == k)
	}
	_, ok := weather_kind_by_name("hail")
	testing.expect(t, !ok)
}

// Mist comes only at dawn, rises and burns off smoothly, and on some mornings, not all.
@(test)
test_weather_mist_at_dawn :: proc(t: ^testing.T) {
	seed := weather_seed(7, 11)
	misty := 0
	for day in 1 ..< 200 {
		d := f64(day)
		testing.expect_value(t, mist_at(seed, d + 0.5), 0) // noon
		testing.expect_value(t, mist_at(seed, d + 0.05), 0) // the small hours
		testing.expect_value(t, mist_at(seed, d + 0.9), 0) // night
		if mist_at(seed, d + 0.26) > 0.99 {
			misty += 1
			testing.expect(t, weather_at(seed, d + 0.26).fog > 0.99)
		}
	}
	testing.expectf(t, misty > 30 && misty < 170, "%d misty mornings of 199", misty)
}

// Rain falls as snow in the cold and not at all where it is dry.
@(test)
test_precipitation_by_climate :: proc(t: ^testing.T) {
	rain := WEATHER_OF[.Rain]
	p, k := precipitation_of(rain, .Temperate)
	testing.expect(t, p == .Rain && k == rain.rain)
	p, k = precipitation_of(rain, .Cold)
	testing.expect(t, p == .Snow && k == rain.rain)
	p, k = precipitation_of(rain, .Dry)
	testing.expect(t, p == .None && k == 0)
	p, _ = precipitation_of(WEATHER_OF[.Overcast], .Temperate)
	testing.expect_value(t, p, Precipitation.None)
	// Where there is no air there is no weather at all.
	storm := WEATHER_OF[.Storm]
	testing.expect_value(t, weather_in(storm, .Airless), Weather{})
	testing.expect_value(t, weather_in(storm, .Dry), storm)
	p, k = precipitation_of(storm, .Airless)
	testing.expect(t, p == .None && k == 0)
}

// Lightning comes only in storms, about as often as STRIKE_CHANCE says, and the same
// strike is found from any second of its slot; its flash rises and is gone.
@(test)
test_lightning :: proc(t: ^testing.T) {
	DAY :: 1200.0
	strikes := 0
	for i in 0 ..< 2000 {
		s := f64(i) * STRIKE_SLOT + 1
		if _, ok := strike_in(9, s, DAY, Weather_Kind.Clear); ok {
			testing.fail_now(t, "lightning in clear weather")
		}
		if st, ok := strike_in(9, s, DAY, Weather_Kind.Storm); ok {
			strikes += 1
			again, _ := strike_in(9, f64(st.slot) * STRIKE_SLOT + 2.9, DAY, Weather_Kind.Storm)
			testing.expect_value(t, again, st)
			testing.expect(t, st.distance >= STRIKE_NEAR && st.distance <= STRIKE_FAR)
			testing.expect_value(t, strike_flash(st, st.at - 0.01), 0)
			testing.expect(t, strike_flash(st, st.at + 0.01) > 0.3)
			testing.expect_value(t, strike_flash(st, st.at + STRIKE_FLASH), 0)
		}
	}
	share := f64(strikes) / 2000
	testing.expectf(t, math.abs(share - STRIKE_CHANCE) < 0.05, "strikes in %v of the slots", share)
}
