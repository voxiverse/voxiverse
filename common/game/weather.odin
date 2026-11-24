package game

import "core:math"

// Weather: a pure function of a world's weather seed and its world time
// (time.odin), so the server and every client work out the same sky from
// the clock they already share; only the seed, a forced kind (the /weather
// command) and the player's climate travel (protocol's Weather record).
//
// Time is cut into spells of SPELL_DAYS. Each spell has a kind drawn from
// the seed (SPELL_WEIGHTS) and the weather is that kind's Weather; over the
// last SPELL_BLEND of a spell it eases into the next spell's, so it never
// jumps. Beside the spells, some dawns are misty (mist_at). A world's first
// day is always clear: a player's first morning on a world is a fine one.
// Stopping the daylight cycle stops the weather with the clock.
//
//	w := game.weather_at(seed, clock, forced)
//	if game.precipitation_of(w, climate) == .Snow {...}

Weather_Kind :: enum u8 {
	Clear,
	Overcast,
	Rain, // snow in a cold climate, nothing falling in a dry one (precipitation_of)
	Storm, // rain or snow, wind, lightning
	Fog,
}

@(rodata)
WEATHER_NAMES := [Weather_Kind]string {
	.Clear    = "clear",
	.Overcast = "overcast",
	.Rain     = "rain",
	.Storm    = "storm",
	.Fog      = "fog",
}

// Weather: how the air is, every field 0..1.
Weather :: struct {
	cover: f32, // cloud: 0 the fair-weather clouds, 1 one grey sheet
	rain:  f32, // how hard it falls (as rain, snow or not at all: precipitation_of)
	storm: f32, // lightning and gusts
	fog:   f32, // mist: the view closes in
	wind:  f32,
}

// Climate: what the air does where a player stands (the server works it out
// from the world's generator: server/core/weather.odin).
Climate :: enum u8 {
	Temperate, // rain falls as rain
	Cold, // ... as snow
	Dry, // nothing falls (the clouds still come)
}

Precipitation :: enum u8 {
	None,
	Rain,
	Snow,
}

SPELL_DAYS :: 1.0 / 3 // a spell of weather: a third of a day (6 min 40 s in the default 20 min day)
SPELL_BLEND :: 0.25 // the share of a spell, at its end, spent easing into the next

// SPELL_WEIGHTS: how often each kind comes, out of 100 (fog comes only as a dawn's mist
// or when forced).
@(rodata)
SPELL_WEIGHTS := [Weather_Kind]u32 {
	.Clear    = 45,
	.Overcast = 25,
	.Rain     = 21,
	.Storm    = 9,
	.Fog      = 0,
}

// WEATHER_OF: each kind's air.
@(rodata)
WEATHER_OF := [Weather_Kind]Weather {
	.Clear = {wind = 0.25},
	.Overcast = {cover = 0.8, wind = 0.45},
	.Rain = {cover = 1, rain = 0.65, wind = 0.55},
	.Storm = {cover = 1, rain = 1, storm = 1, wind = 1},
	.Fog = {cover = 0.5, fog = 1, wind = 0.05},
}

// The mist of a misty dawn: it gathers before sunrise (0.25), is thickest just
// after and burns off by mid-morning.
MIST_CHANCE :: 0.35 // a dawn's chance of mist
MIST_CHANCE_WET :: 0.8 // ... after a night with rain
MIST_RISE :: [2]f64{0.17, 0.235} // time of day: from nothing to whole
MIST_FALL :: [2]f64{0.29, 0.37} // ... and from whole to gone

// weather_seed: a world's weather seed, from its seed and its address's hash: every world
// of a universe has weather of its own.
weather_seed :: proc(world_seed: i64, address: u64) -> u64 {
	return mix64(u64(world_seed) ~ mix64(address ~ 0x5745_4154_4845_5221))
}

// weather_at: the weather at world time t (days). forced: a kind the world was set to (it
// stands, no spells, no mist).
weather_at :: proc(seed: u64, t: f64, forced: Maybe(Weather_Kind) = nil) -> Weather {
	if k, ok := forced.?; ok {return WEATHER_OF[k]}
	at := max(t, 0)
	spell := math.floor(at / SPELL_DAYS)
	into := at / SPELL_DAYS - spell // 0..1 through it
	w := WEATHER_OF[spell_kind(seed, i64(spell))]
	if into > 1 - SPELL_BLEND {
		next := WEATHER_OF[spell_kind(seed, i64(spell) + 1)]
		w = weather_mix(w, next, f32(smooth(1 - SPELL_BLEND, 1, into)))
	}
	if mist := mist_at(seed, at); mist > w.fog {
		w.wind *= 1 - 0.7 * mist
		w.cover = max(w.cover, 0.35 * mist)
		w.fog = mist
	}
	return w
}

// spell_kind: the kind of spell number n (the spells of the first day are clear).
spell_kind :: proc(seed: u64, n: i64) -> Weather_Kind {
	if f64(n + 1) * SPELL_DAYS <= 1 {return .Clear}
	roll := u32(mix64(seed ~ u64(n) * 0x9E37_79B9_7F4A_7C15) % 100)
	for k in Weather_Kind {
		if roll < SPELL_WEIGHTS[k] {return k}
		roll -= SPELL_WEIGHTS[k]
	}
	return .Clear
}

// mist_at: how thick a dawn's mist is at world time t (0 outside the mornings that have
// one; none on the first day).
mist_at :: proc(seed: u64, t: f64) -> f32 {
	day := math.floor(t)
	if day < 1 {return 0}
	f := t - day
	if f < MIST_RISE[0] || f > MIST_FALL[1] {return 0}
	night := day / SPELL_DAYS - 1 // the spell before this day's first: the night
	chance := MIST_CHANCE
	#partial switch spell_kind(seed, i64(night)) {
	case .Rain, .Storm:
		chance = MIST_CHANCE_WET
	}
	roll := f64(mix64(seed ~ u64(i64(day)) * 0xC2B2_AE3D_27D4_EB4F ~ 0x4d15) % 10_000) / 10_000
	if roll >= chance {return 0}
	return f32(smooth(MIST_RISE[0], MIST_RISE[1], f) * (1 - smooth(MIST_FALL[0], MIST_FALL[1], f)))
}

// weather_mix: a weather between a (k 0) and b (k 1).
weather_mix :: proc(a, b: Weather, k: f32) -> Weather {
	return {
		cover = math.lerp(a.cover, b.cover, k),
		rain = math.lerp(a.rain, b.rain, k),
		storm = math.lerp(a.storm, b.storm, k),
		fog = math.lerp(a.fog, b.fog, k),
		wind = math.lerp(a.wind, b.wind, k),
	}
}

// weather_kind_of: the kind a weather is nearest to (what /weather says it is).
weather_kind_of :: proc(w: Weather) -> Weather_Kind {
	switch {
	case w.storm >= 0.5:
		return .Storm
	case w.rain >= 0.3:
		return .Rain
	case w.fog >= 0.5:
		return .Fog
	case w.cover >= 0.5:
		return .Overcast
	}
	return .Clear
}

weather_kind_by_name :: proc(name: string) -> (Weather_Kind, bool) {
	for n, k in WEATHER_NAMES {if n == name {return k, true}}
	return {}, false
}

// precipitation_of: what falls, and how hard (0..1), in a climate.
precipitation_of :: proc(w: Weather, climate: Climate) -> (Precipitation, f32) {
	if w.rain <= 0 {return .None, 0}
	switch climate {
	case .Dry:
		return .None, 0
	case .Cold:
		return .Snow, w.rain
	case .Temperate:
	}
	return .Rain, w.rain
}

// Lightning: storms throw a strike now and then. Time is cut into slots of
// STRIKE_SLOT seconds; a slot holds a strike with a chance that grows with the
// storm at its start, at a moment, a distance and a bearing drawn from the seed.
STRIKE_SLOT :: 3.0 // seconds
STRIKE_CHANCE :: 0.3 // a slot's chance of a strike in a full storm (one every 10 s)
STRIKE_FLASH :: 0.6 // seconds a flash lasts
STRIKE_NEAR :: 150 // blocks: the nearest strike
STRIKE_FAR :: 3000 // ... and the farthest
SOUND_SPEED :: 343 // blocks (metres) a second: thunder comes this much after the flash

Strike :: struct {
	slot:     i64, // its slot: an id (the same strike on every machine)
	at:       f64, // seconds of world time it flashes (days * day_length)
	distance: f32, // blocks away
	bearing:  f32, // radians, from +x towards +z (a direction, not a place)
}

// strike_in: the strike of the slot holding second `seconds` of world time, if it has one
// (forced: as weather_at's).
strike_in :: proc(
	seed: u64,
	seconds: f64,
	day_length: f64,
	forced: Maybe(Weather_Kind) = nil,
) -> (
	Strike,
	bool,
) {
	if day_length <= 0 {return {}, false}
	slot := i64(math.floor(seconds / STRIKE_SLOT))
	start := f64(slot) * STRIKE_SLOT
	storm := weather_at(seed, start / day_length, forced).storm
	h := mix64(seed ~ u64(slot) * 0xD6E8_FEB8_6659_FD93 ~ 0x1157)
	if f64(h & 0xffff) / 0x10000 >= f64(storm) * STRIKE_CHANCE {return {}, false}
	unit :: proc(h: u64, shift: uint) -> f64 {return f64((h >> shift) & 0xffff) / 0x10000}
	near := unit(h, 32)
	return {
			slot = slot,
			at = start + unit(h, 16) * (STRIKE_SLOT - STRIKE_FLASH),
			distance = f32(STRIKE_NEAR + (STRIKE_FAR - STRIKE_NEAR) * near * near),
			bearing = f32(unit(h, 48) * math.TAU),
		},
		true
}

// strike_flash: how bright a strike's flash is (0..1) at `seconds`: a bolt, a dark
// gap, a second flicker, then a fade; a far strike is dimmer.
strike_flash :: proc(s: Strike, seconds: f64) -> f32 {
	dt := seconds - s.at
	if dt < 0 || dt >= STRIKE_FLASH {return 0}
	k: f64
	switch {
	case dt < 0.07:
		k = 1
	case dt < 0.13:
		k = 0.15
	case dt < 0.2:
		k = 0.75
	case:
		k = 0.75 * (1 - smooth(0.2, STRIKE_FLASH, dt))
	}
	near := 1 - f64(s.distance - STRIKE_NEAR) / (STRIKE_FAR - STRIKE_NEAR)
	return f32(k * (0.35 + 0.65 * near))
}

@(private = "file")
smooth :: proc(lo, hi, x: f64) -> f64 {
	t := clamp((x - lo) / (hi - lo), 0, 1)
	return t * t * (3 - 2 * t)
}

// mix64: SplitMix64's finalizer, a good scramble of a 64-bit value.
@(private = "file")
mix64 :: proc(x: u64) -> u64 {
	z := x + 0x9E37_79B9_7F4A_7C15
	z = (z ~ (z >> 30)) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ (z >> 27)) * 0x94D0_49BB_1331_11EB
	return z ~ (z >> 31)
}
