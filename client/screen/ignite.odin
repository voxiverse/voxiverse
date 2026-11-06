package screen

import "core:math"

import "client:engine"
import "client:planet"
import "client:starfield"
import "client:ui"
import "common:game"

// Ignite: the big bang after
// the creation screen's button. The galaxy view collapses to a point, flashes
// and zooms into the home world, then the loading screen takes over, while
// the universe is created and the world loads in the background (the
// animation never waits for it, and plays out when loading is quicker). Any
// key or click skips it. With Reduce motion it is a short cross-fade.

// The phases, in order, and how long each lasts (seconds). They sum to
// IGNITE_SECONDS; the ring of the shockwave keeps growing under the streaks.
Ignite_Phase :: enum {
	Wind, // the arms wind inward, the galaxy collapses to a bright point
	Flash, // a flash and a shockwave ring from the point
	Streaks, // the stars streak outward (the title screen's warp)
	Dive, // the camera dives to the home planet until it fills the screen
	Fade, // cross-fade into the loading screen
	Done,
}

IGNITE_PHASES :: [5]f32{0.8, 0.4, 0.4, 0.6, 0.3}
IGNITE_SECONDS :: 2.5 // all of it
IGNITE_FADE :: 0.3 // Reduce motion's cross-fade
WIND_TURNS :: 1.5 // turns the innermost stars make while winding in
IGNITE_WARP_SPEED :: 12 // the streaks' starfield runs this much faster than the title's
IGNITE_MAX_QUADS :: 4096 // the most one frame's draw list may hold
IGNITE_STREAK_QUADS :: 12 // quads of one streak: 260 stars x 13 and the ring stay under the budget
RING_DOTS :: 180

// ui_cue fires a UI sound's event name at the sound system. There are no UI
// sounds yet (next tier), so nothing plays; the names are kept for the
// tests to see (the last few).
ui_cue :: proc(app: ^engine.App, name: string) {
	if len(app.cues) >= 16 {ordered_remove(&app.cues, 0)}
	append(&app.cues, name)
}

ignite_start :: proc(app: ^engine.App, stars: []game.Star, seed: u64) {
	i := &app.ignite
	i^ = {
		active = true,
		reduce = app.settings.reduce_motion,
		planet = planet.home_planet_palette(app.registry),
	}
	copy(i.stars[:], stars)
	i.fire.random = u32(seed) ~ u32(seed >> 32)
	starfield.starfield_update(&i.fire, 0, false) // seeds it
	ui_cue(app, "ui_ignite")
}

// ignite_duration: how long it plays.
ignite_duration :: proc(reduce: bool) -> f32 {
	return IGNITE_FADE if reduce else IGNITE_SECONDS
}

// ignite_step advances it by dt seconds; false once it is over.
ignite_step :: proc(i: ^engine.Ignite, dt: f32) -> bool {
	if !i.active {return false}
	i.t += dt
	if i.t >= ignite_duration(i.reduce) {i.active = false}
	return i.active
}

// ignite_ui steps and draws it over everything (a key or click skips).
ignite_ui :: proc(app: ^engine.App, ctx: ^ui.Context) {
	i := &app.ignite
	if !i.active {return}
	skip := i.frames > 0 && (ctx.input.keys_pressed != {} || ctx.input.mouse_pressed != {})
	i.frames += 1
	dt := min(app.last_frame_ms / 1000, 0.1)
	if skip || !ignite_step(i, dt) {
		i.active = false
		return
	}
	if !i.reduce {
		if phase, _ := ignite_phase(i.t); phase == .Streaks {
			starfield.starfield_update(&i.fire, dt, false, IGNITE_WARP_SPEED)
		}
	}
	prev := ui.begin_layer(ctx, .Tooltip)
	defer ui.end_layer(ctx, prev)
	ignite_draw(ctx, i)
}

// ignite_phase: the phase at t seconds in, and how far through it (0..1).
ignite_phase :: proc(t: f32) -> (phase: Ignite_Phase, x: f32) {
	start: f32
	for d, k in IGNITE_PHASES {
		if t < start + d {return Ignite_Phase(k), clamp((t - start) / d, 0, 1)}
		start += d
	}
	return .Done, 1
}

// Ignite_Frame: what one frame shows, as numbers (ignite_plan).
Ignite_Frame :: struct {
	phase:        Ignite_Phase,
	x:            f32, // 0..1 within the phase
	stars:        [engine.IGNITE_STARS]ui.Vec2, // screen positions (the first star_count)
	star_count:   int,
	star_scale:   f32, // the stars' size, 1 at the start
	point_alpha:  f32, // the bright point the galaxy collapses to
	flash_alpha:  f32,
	ring_radius:  f32, // pixels; 0: no ring
	streak_speed: f32, // the warp's speed factor (1: the title's)
	planet:       f32, // the planet's radius in pixels; 0: none
	fade_alpha:   f32, // how much of the loading screen shows through
}

// ignite_plan computes the frame at the animation's time without drawing.
ignite_plan :: proc(i: ^engine.Ignite, screen: ui.Rect) -> (f: Ignite_Frame) {
	f.streak_speed = 1
	if i.reduce {
		f.phase = .Fade
		f.x = clamp(i.t / IGNITE_FADE, 0, 1)
		f.fade_alpha = f.x
		return
	}
	f.phase, f.x = ignite_phase(i.t)
	centre := ui.Vec2{screen.w / 2, screen.h / 2}
	diag := math.sqrt(screen.w * screen.w + screen.h * screen.h)
	switch f.phase {
	case .Wind:
		e := f.x * f.x * (3 - 2 * f.x)
		side := min(screen.w, screen.h) * 0.8
		f.star_count = engine.IGNITE_STARS
		f.star_scale = (1 - 0.6 * e) * max(side / 400, 1)
		f.point_alpha = e
		for s, k in i.stars {
			v := (s.position - ui.Vec2{0.5, 0.5}) * side
			r := min(math.sqrt(v.x * v.x + v.y * v.y) / (side / 2), 1)
			a := WIND_TURNS * 2 * math.PI * e * (1 - r)
			sn, cs := math.sin(a), math.cos(a)
			turned := ui.Vec2{v.x * cs - v.y * sn, v.x * sn + v.y * cs}
			f.stars[k] = centre + turned * (1 - e)
		}
	case .Flash:
		f.flash_alpha = 1 - f.x
		f.ring_radius = diag * ring_progress(f.phase, f.x)
	case .Streaks:
		f.streak_speed = IGNITE_WARP_SPEED
		f.ring_radius = diag * ring_progress(f.phase, f.x)
	case .Dive:
		f.planet = 4 + f.x * f.x * f.x * diag
	case .Fade:
		f.planet = 4 + diag
		f.fade_alpha = f.x
	case .Done:
		f.planet = 4 + diag
		f.fade_alpha = 1
	}
	return
}

// ring_progress: how far the shockwave has gone (0..1 of the diagonal) at x
// through Flash or Streaks: it grows steadily from the flash on.
@(private = "file")
ring_progress :: proc(phase: Ignite_Phase, x: f32) -> f32 {
	d := IGNITE_PHASES
	span := d[Ignite_Phase.Flash] + d[Ignite_Phase.Streaks]
	since := x * d[phase] + (0 if phase == .Flash else d[Ignite_Phase.Flash])
	return since / span
}

ignite_draw :: proc(ctx: ^ui.Context, i: ^engine.Ignite) {
	screen := ctx.screen
	centre := ui.Vec2{screen.w / 2, screen.h / 2}
	f := ignite_plan(i, screen)
	if i.reduce {
		ui.fill_rect(ctx, screen, faded(ctx.theme.background, 1 - f.fade_alpha))
		return
	}
	ui.fill_rect(ctx, screen, ctx.theme.background)
	if f.star_count > 0 {
		for k in 0 ..< f.star_count {
			s := i.stars[k]
			size := (1 + 1.5 * s.size) * f.star_scale
			p := f.stars[k]
			ui.fill_rect(
				ctx,
				{p.x - size / 2, p.y - size / 2, size, size},
				ui.Color(game.star_color(s)),
			)
		}
		size := 2 + 6 * f.point_alpha
		ui.fill_rect(
			ctx,
			{centre.x - size / 2, centre.y - size / 2, size, size},
			faded(ctx.theme.text, f.point_alpha),
		)
	}
	if f.flash_alpha > 0 {ui.fill_rect(ctx, screen, faded(ctx.theme.text, f.flash_alpha))}
	if f.phase ==
	   .Streaks {starfield.starfield_draw(ctx, &i.fire, quads_max = IGNITE_STREAK_QUADS)}
	if f.ring_radius > 0 {
		diag := math.sqrt(screen.w * screen.w + screen.h * screen.h)
		colour := faded(ctx.theme.text, 0.8 * (1 - f.ring_radius / diag))
		for k in 0 ..< RING_DOTS {
			a := 2 * math.PI * f32(k) / RING_DOTS
			x := math.floor(centre.x + math.cos(a) * f.ring_radius)
			y := math.floor(centre.y + math.sin(a) * f.ring_radius)
			ui.fill_rect(ctx, {x, y, 3, 3}, colour)
		}
	}
	if f.planet > 0 {
		draw_planet(ctx, centre, f.planet, i.t, 1 - f.fade_alpha, i.planet)
	}
}

// faded: c with its alpha scaled by a (0..1).
faded :: proc(c: ui.Color, a: f32) -> ui.Color {
	out := c
	out.a = u8(f32(c.a) * clamp(a, 0, 1))
	return out
}

// draw_planet draws a lit sphere (the home world's colours: water, ground,
// dry ground, ice) of this radius, turned by spin, in horizontal bands;
// alpha fades it.
draw_planet :: proc(
	ctx: ^ui.Context,
	centre: ui.Vec2,
	radius, spin: f32,
	alpha: f32,
	palette: planet.Planet_Palette,
) {
	BANDS :: 48
	CELLS :: 14
	clip := ctx.screen
	for b in 0 ..< BANDS {
		y0 := -1 + 2 * f32(b) / BANDS
		y1 := -1 + 2 * f32(b + 1) / BANDS
		ym := (y0 + y1) / 2
		half := math.sqrt(max(1 - ym * ym, 0)) // the band's half width, in radii
		top := centre.y + y0 * radius
		height := (y1 - y0) * radius + 1
		if top > clip.h || top + height < 0 {continue}
		for cell in 0 ..< CELLS {
			u0 := -1 + 2 * f32(cell) / CELLS
			u1 := -1 + 2 * f32(cell + 1) / CELLS
			x0 := centre.x + u0 * half * radius
			x1 := centre.x + u1 * half * radius
			// Longitude of the cell's middle on the sphere, turned by spin.
			lon := math.asin(clamp((u0 + u1) / 2, -1, 1)) + spin
			n := planet_noise(math.floor(lon * 2.2), b / 3)
			color := palette.water
			if n > 0.55 {color = palette.ground}
			if n > 0.86 {color = palette.dry}
			if abs(ym) > 0.86 {color = palette.ice}
			// Light from the upper left: darker toward the lower right.
			lit := clamp(
				0.55 +
				0.45 * (-(u0 + u1) / 2 * 0.6 - ym * 0.5 + math.sqrt(max(1 - ym * ym, 0)) * 0.3),
				0.12,
				1,
			)
			color.r = u8(f32(color.r) * lit)
			color.g = u8(f32(color.g) * lit)
			color.b = u8(f32(color.b) * lit)
			color.a = u8(255 * alpha)
			ui.fill_rect(ctx, {x0, top, x1 - x0 + 1, height}, color)
		}
	}
}

@(private = "file")
planet_noise :: proc(a: f32, b: int) -> f32 {
	h := u32(i32(a)) * 0x9e37_79b1 ~ u32(b) * 0x85eb_ca6b
	h ~= h >> 15
	h *= 0x2c1b_3c6d
	h ~= h >> 12
	return f32(h & 0xffff) / 65535
}
