package main

import "core:math"

import "client:atmosphere"
import "client:audio"
import "client:engine"
import "client:render"
import "client:sfx"
import "common:game"
import "common:protocol"

// The air round the player, once a frame in a world: the weather where they are
// (engine.session_weather), what it does to the sky, the rain or snow drawn round
// them, lightning's flash and its thunder after it, and the ambience's beds
// (client/atmosphere decides; this carries it out on the App's renderer and mixer).

WATER_EVERY :: 0.5 // seconds between looks for water near the player
WATER_REACH :: 9 // blocks round the player looked at for water (every WATER_STEP)
WATER_STEP :: 3
WATER_FULL :: 8 // columns with water near that make the water bed whole
WIND_SPEED :: 6 // blocks a second the rain is blown at in a full wind

// atmosphere_frame: the sky under the weather for this frame's scene, with the drops
// for the weather pass, the thunder and the beds seen to.
atmosphere_frame :: proc(app: ^engine.App, s: ^engine.Session, sky: render.Sky) -> render.Sky {
	a := &app.atmosphere
	w, climate := engine.session_weather(s)
	a.weather, a.climate = w, climate
	place := atmosphere_place(app, s, sky)
	effects := app.settings.weather_effects
	flash := lightning(app, s, place)
	sw := atmosphere.sky_weather(
		w,
		climate,
		place,
		flash if effects else 0,
		app.settings.reduce_motion,
	)
	a.flash = sw.flash
	if effects && !place.underwater {
		kind, amount := game.precipitation_of(w, climate)
		wind := atmosphere.wind_direction(s.weather.seed, s.clock) * w.wind * WIND_SPEED
		top :: proc(data: rawptr, x, z: i32) -> (i32, bool) {
			return engine.world_column_top((^engine.World)(data), x, z)
		}
		atmosphere.drops_make(
			&app.weather_draw,
			kind,
			amount,
			wind,
			s.view.position,
			f64(app.seconds),
			top,
			&s.world,
		)
	}
	ambience_frame(app, w, climate, place)
	return render.sky_weathered(sky, sw)
}

// atmosphere_place: where the camera is, as the weather and the ambience need it.
@(private = "file")
atmosphere_place :: proc(
	app: ^engine.App,
	s: ^engine.Session,
	sky: render.Sky,
) -> (
	p: atmosphere.Place,
) {
	a := &app.atmosphere
	eye := s.view.position
	p.eye = eye
	p.underwater = engine.eye_in_water(s)
	if s.has_worldgen {p.sea_level = f32(s.worldgen.sea_level)}
	ex, ez := i32(math.floor(eye.x)), i32(math.floor(eye.z))
	if top, ok := engine.world_column_top(&s.world, ex, ez); ok {
		roof := f64(top) + 1 // the top block's upper face
		if roof > eye.y {
			p.shelter = f32(roof - eye.y)
		} else {
			p.above = f32(max(s.prediction.state.position.y - roof, 0))
		}
	}
	p.night = 1 - atmosphere.smooth(-0.15, 0.1, sky.sun.y)
	if f64(app.seconds) >= a.water_next || f64(app.seconds) < a.water_next - 2 * WATER_EVERY {
		a.water = water_near(s, eye)
		a.water_next = f64(app.seconds) + WATER_EVERY
	}
	p.water = a.water
	for at, strength in s.hums {
		d := [3]f64{f64(at.x) + 0.5, f64(at.y) + 0.5, f64(at.z) + 0.5} - eye
		p.hum = max(
			p.hum,
			atmosphere.hum_of(strength, f32(math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z))),
		)
	}
	return
}

// water_near: how much water is round the eye (0..1): the columns of a coarse grid
// with water a little below to a little above it.
@(private = "file")
water_near :: proc(s: ^engine.Session, eye: [3]f64) -> f32 {
	ex, ey, ez := i32(math.floor(eye.x)), i32(math.floor(eye.y)), i32(math.floor(eye.z))
	wet := 0
	for dz := i32(-WATER_REACH); dz <= WATER_REACH; dz += WATER_STEP {
		for dx := i32(-WATER_REACH); dx <= WATER_REACH; dx += WATER_STEP {
			for dy in i32(-6) ..= 1 {
				b, _ := engine.world_block(&s.world, {ex + dx, ey + dy, ez + dz})
				if _, water := game.water_level(b); water {
					wet += 1
					break
				}
			}
		}
	}
	return min(f32(wet) / WATER_FULL, 1)
}

// lightning: the flash now (0..1), from the strikes of this slot and the last; a strike
// that has just flashed sends its thunder, timed to arrive as late as its distance says.
@(private = "file")
lightning :: proc(app: ^engine.App, s: ^engine.Session, place: atmosphere.Place) -> f32 {
	a := &app.atmosphere
	day := f64(s.rules.day_length)
	now := s.clock * day
	forced := protocol.weather_forced(s.weather)
	flash: f32
	for back in 0 ..= 1 {
		st, ok := game.strike_in(s.weather.seed, now - f64(back) * game.STRIKE_SLOT, day, forced)
		if !ok {continue}
		flash = max(flash, game.strike_flash(st, now))
		if st.at <= now && st.slot > a.strike {
			a.strike = st.slot
			if now - st.at < 0.5 {thunder(app, st, now, place)} 	// (one long gone when we came is not heard)
		}
	}
	return flash
}

// thunder: a strike's thunder, to start when the sound would arrive.
@(private = "file")
thunder :: proc(app: ^engine.App, st: game.Strike, now: f64, place: atmosphere.Place) {
	if app.mixer == nil || app.benchmark {return}
	near := 1 - (st.distance - game.STRIKE_NEAR) / (game.STRIKE_FAR - game.STRIKE_NEAR)
	variant := 0 if st.distance < 600 else (1 if st.distance < 1500 else 2)
	delay := f64(st.distance) / game.SOUND_SPEED - (now - st.at)
	muffled := 1 - atmosphere.exposure(place)
	gain := (0.3 + 0.7 * near) * (1 - 0.5 * muffled)
	cutoff := math.lerp(f32(900), f32(8000), near * near) * (1 - 0.7 * muffled)
	audio.play(
		app.mixer,
		{
			sound = app.sounds.thunder[variant],
			gain = {gain, gain},
			pitch = 0.85 + 0.25 * near,
			bus = .Ambience,
			cutoff = cutoff,
			start_frame = audio.clock(app.mixer) + u64(max(delay, 0) * f64(app.mixer.rate)),
		},
	)
}

// ambience_frame eases the beds towards the weights of where the player is.
@(private = "file")
ambience_frame :: proc(
	app: ^engine.App,
	w: game.Weather,
	climate: game.Climate,
	place: atmosphere.Place,
) {
	if app.mixer == nil || app.benchmark {return}
	a := &app.atmosphere
	kind, amount := game.precipitation_of(w, climate)
	target := atmosphere.bed_weights({w, kind, amount, climate, place})
	atmosphere.ambience_step(&a.mix, target, app.last_frame_ms / 1000)
	for b in sfx.Bed {
		g := a.mix.weight[b] * atmosphere.BED_LEVEL[b]
		if a.beds[b] == {} {
			a.beds[b] = audio.play(
				app.mixer,
				{
					sound = app.sounds.bed[b],
					gain = {g, g},
					pitch = 1,
					bus = .Ambience,
					loop = true,
					fade_in = 1,
				},
			)
			a.sent[b] = g
		} else if abs(g - a.sent[b]) > 0.002 {
			audio.set_voice_gain(app.mixer, a.beds[b], {g, g})
			a.sent[b] = g
		}
	}
}
