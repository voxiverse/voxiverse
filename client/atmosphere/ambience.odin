package atmosphere

import "core:math"

import "client:sfx"
import "common:game"

// The ambience: a loop for each bed (client/sfx's Bed), playing all the time on
// the Ambience bus, each at the weight the listener's place and the weather give
// it (bed_weights), eased towards it (ambience_step) so one fades into another as
// the player walks into a cave or the rain comes. The Ambience volume in Options
// is that bus's gain; this decides only the balance.

Bed :: sfx.Bed

// BED_LEVEL: each bed's loudness at weight 1, against the others.
@(rodata)
BED_LEVEL := [Bed]f32 {
	.Wind    = 0.5,
	.Rain    = 0.55,
	.Water   = 0.45,
	.Cave    = 0.35,
	.Insects = 0.18,
	.Birds   = 0.2,
	.Hum     = 0.4,
}

BED_FADE :: 1.5 // seconds: a bed's weight moves most of the way to a new one in this

// HIGH_WIND: blocks above the ground at which the wind is as loud as height makes it
// (a hill top, a tower, flying).
HIGH_WIND :: 40

// Listener: what decides the beds.
Listener :: struct {
	weather:       game.Weather,
	precipitation: game.Precipitation,
	amount:        f32, // how hard it falls (0..1)
	climate:       game.Climate,
	place:         Place,
}

// bed_weights: how loud each bed is (0..1) for a listener.
bed_weights :: proc(l: Listener) -> (w: [Bed]f32) {
	p := l.place
	open := exposure(p) // 1 under the sky, 0 deep under rock
	deep := smooth(4, 14, p.shelter) // underground (or deep in a building)
	high := smooth(2, HIGH_WIND, p.above)
	wind := l.weather.wind
	w[.Wind] = clamp((0.12 + 0.55 * wind + 0.4 * high) * (0.15 + 0.85 * open), 0, 1)
	if l.precipitation == .Rain {
		// Under a roof it still drums on it, quieter; under rock it is gone.
		w[.Rain] = l.amount * (1 - deep) * (0.45 + 0.55 * open)
	}
	w[.Water] = clamp(p.water, 0, 1) * (1 - 0.5 * deep)
	w[.Cave] = deep
	calm := (1 - l.weather.rain) * (1 - 0.7 * wind) * open * (1 - high)
	warm: f32 = 0 if l.climate == .Cold else 1
	w[.Insects] = p.night * calm * warm
	w[.Birds] =
		(1 - p.night) * calm * warm * (1 - l.weather.cover * 0.6) * (1 - l.weather.fog * 0.5)
	if l.climate == .Dry {w[.Birds] *= 0.3}
	w[.Hum] = clamp(p.hum, 0, 1)
	if p.underwater {for &x in w {x *= 0.3}}
	return
}

// Ambience: the beds' weights as heard now.
Ambience :: struct {
	weight: [Bed]f32,
}

// ambience_step eases a's weights towards target over dt seconds.
ambience_step :: proc(a: ^Ambience, target: [Bed]f32, dt: f32) {
	k := 1 - math.exp(-max(dt, 0) * 2 / BED_FADE)
	for b in Bed {a.weight[b] += (target[b] - a.weight[b]) * k}
}

// hum_of: how strongly a hum source of strength at distance d (blocks) is heard (0..1):
// whole at HUM_NEAR, nothing past HUM_FAR.
HUM_NEAR :: 4
HUM_FAR :: 40
hum_of :: proc(strength, d: f32) -> f32 {
	t := 1 - smooth(HUM_NEAR, HUM_FAR, d)
	return clamp(strength, 0, 1) * t * t
}
