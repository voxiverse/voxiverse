package atmosphere

import "core:testing"

import "common:game"

// The beds for a set of places: each situation's loudest beds are the ones it should be.
@(test)
test_bed_weights :: proc(t: ^testing.T) {
	clear_day := Listener {
		weather = game.WEATHER_OF[.Clear],
		climate = .Temperate,
		place = {eye = {0, 70, 0}, above = 1.6},
	}
	w := bed_weights(clear_day)
	testing.expect(t, w[.Birds] > 0.5, "birds on a fair day")
	testing.expect_value(t, w[.Insects], 0)
	testing.expect_value(t, w[.Rain], 0)
	testing.expect_value(t, w[.Cave], 0)
	testing.expect(t, w[.Wind] > 0.1 && w[.Wind] < 0.4, "a breeze")

	night := clear_day
	night.place.night = 1
	w = bed_weights(night)
	testing.expect(t, w[.Insects] > 0.5 && w[.Birds] == 0, "crickets at night, not birds")

	cold_night := night
	cold_night.climate = .Cold
	testing.expect_value(t, bed_weights(cold_night)[.Insects], 0)

	storm := clear_day
	storm.weather = game.WEATHER_OF[.Storm]
	storm.precipitation, storm.amount = .Rain, 1
	w = bed_weights(storm)
	testing.expect(t, w[.Rain] > 0.9 && w[.Wind] > 0.6, "a storm: rain and wind")
	testing.expect(t, w[.Birds] == 0 && w[.Insects] == 0, "nothing sings in a storm")

	indoors := storm
	indoors.place.shelter = 2
	wi := bed_weights(indoors)
	testing.expect(t, wi[.Rain] > 0.3 && wi[.Rain] < w[.Rain], "rain on the roof, quieter")
	testing.expect(t, wi[.Wind] < w[.Wind], "the wind muffled inside")

	snow := storm
	snow.precipitation = .Snow
	testing.expect_value(t, bed_weights(snow)[.Rain], 0) // snow falls silently

	cave := storm
	cave.place.shelter = 30
	w = bed_weights(cave)
	testing.expect(t, w[.Cave] > 0.99, "the cave's drone deep down")
	testing.expect(t, w[.Rain] == 0, "no rain heard under rock")
	testing.expect(t, w[.Wind] < 0.25, "hardly any wind under rock")

	summit := clear_day
	summit.place.above = 60
	testing.expect(t, bed_weights(summit)[.Wind] > 0.5, "wind high up")

	shore := clear_day
	shore.place.water = 0.8
	testing.expect(t, bed_weights(shore)[.Water] > 0.7, "water at the shore")

	ruin := clear_day
	ruin.place.hum = hum_of(1, 6)
	testing.expect(t, bed_weights(ruin)[.Hum] > 0.8, "a hum near the remains")
	testing.expect_value(t, hum_of(1, HUM_FAR + 1), 0)
	testing.expect(t, hum_of(1, 10) > hum_of(1, 20) && hum_of(0.5, 10) < hum_of(1, 10))

	for l in ([]Listener{clear_day, night, storm, indoors, cave, summit, shore, ruin}) {
		for x in bed_weights(l) {testing.expect(t, x >= 0 && x <= 1)}
	}
}

// The weights ease to a new place: no jump in a frame, there within a few fades.
@(test)
test_ambience_crossfades :: proc(t: ^testing.T) {
	a: Ambience
	target: [Bed]f32
	target[.Cave] = 1
	ambience_step(&a, target, 1.0 / 60)
	testing.expect(t, a.weight[.Cave] > 0 && a.weight[.Cave] < 0.05, "no jump in a frame")
	for _ in 0 ..< 60 * 5 {ambience_step(&a, target, 1.0 / 60)}
	testing.expect(t, a.weight[.Cave] > 0.99, "there after a few seconds")
	ambience_step(&a, {}, 0)
	testing.expect(t, a.weight[.Cave] > 0.99, "no time, no change")
}
