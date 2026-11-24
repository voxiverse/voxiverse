package atmosphere

import "core:math"

import "client:render"
import "common:game"

// The air around the player, from the weather (common/game/weather.odin, worked
// out from the server's Weather record and the clock) and the place: how it
// changes the sky (sky_weather), what falls and where (precipitation.odin),
// what is heard (ambience.odin). Pure: the client's engine gives it the place
// and carries out what it says.

// Place: where the camera (and the listener) is, as the client knows it.
Place :: struct {
	eye:        [3]f64, // world position
	sea_level:  f32, // the world's (its generator's), for mist in low ground
	shelter:    f32, // blocks of solid world above the head (0: open sky)
	above:      f32, // blocks above the ground under the feet (or the column's top)
	water:      f32, // 0..1: how much water is around (a shore, a river)
	hum:        f32, // 0..1: how near and strong the nearest hum source is
	underwater: bool,
	night:      f32, // 0 day .. 1 night (from the sun's height)
}

// MIST_LOW: blocks above sea level up to which a dawn's mist lies whole, and up to which
// it thins to nothing.
MIST_LOW :: [2]f32{16, 56}

// REDUCED_FLASH: a lightning flash's share with reduced motion (a soft glow, never a
// strobe).
REDUCED_FLASH :: 0.2

// exposure: how much of the sky reaches the place (1 open, 0 deep under rock or a roof).
exposure :: proc(p: Place) -> f32 {
	return 1 - smooth(1, 10, p.shelter)
}

// sky_weather: what the weather does to the sky seen from the place, with a flash of
// lightning (0..1) in it.
sky_weather :: proc(
	w: game.Weather,
	climate: game.Climate,
	p: Place,
	flash: f32,
	reduce_motion: bool,
) -> render.Sky_Weather {
	precipitation, amount := game.precipitation_of(w, climate)
	height := f32(p.eye.y) - p.sea_level
	low := 1 - smooth(MIST_LOW[0], MIST_LOW[1], height)
	f := flash * (REDUCED_FLASH if reduce_motion else 1) * exposure(p)
	return {
		cover = w.cover,
		rain = amount if precipitation != .None else 0,
		storm = w.storm,
		fog = w.fog * low,
		flash = f,
	}
}

// wind_direction: which way the wind blows in a world (x, z, unit), from its weather
// seed: it turns slowly, a full turn every few days.
wind_direction :: proc(seed: u64, clock: f64) -> [2]f32 {
	angle := f64(seed & 0xffff) / 0x10000 * math.TAU + math.sin(clock * 1.7) * 0.8
	return {f32(math.cos(angle)), f32(math.sin(angle))}
}

// smooth: smoothstep, from 0 at lo to 1 at hi.
smooth :: proc(lo, hi, x: f32) -> f32 {
	t := clamp((x - lo) / (hi - lo), 0, 1)
	return t * t * (3 - 2 * t)
}
