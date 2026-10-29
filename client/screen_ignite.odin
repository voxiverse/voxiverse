package client

import "core:math"

import "../common/game"
import "ui"

// Ignite (M48e): the big bang after
// the creation screen's button. The galaxy view collapses to a point, flashes
// and zooms into the home world, then the loading screen takes over, while
// the universe is created and the world loads in the background (the
// animation never waits for it, and plays out when loading is quicker). Any
// key or click skips it. With Reduce motion it is a short cross-fade.

IGNITE_COLLAPSE :: 0.9 // seconds
IGNITE_FLASH :: 0.15
IGNITE_ZOOM :: 1.1
IGNITE_SECONDS :: 2.5 // all of it: the rest, after the zoom, fades into the loading screen
IGNITE_FADE :: 0.3 // Reduce motion's cross-fade
IGNITE_STARS :: 1200 // the galaxy's stars the collapse draws

Ignite :: struct {
	active: bool,
	t:      f32, // seconds in
	frames: int, // frames drawn (input in the first is the one that started it)
	reduce: bool,
	stars:  [IGNITE_STARS]game.Star,
}

// ui_cue fires a UI sound's event name at the sound system. There are no UI
// sounds yet (next tier), so nothing plays; the names are kept for the
// tests to see (the last few).
ui_cue :: proc(app: ^App, name: string) {
	if len(app.cues) >= 16 {ordered_remove(&app.cues, 0)}
	append(&app.cues, name)
}

ignite_start :: proc(app: ^App, stars: []game.Star, seed: u64) {
	i := &app.ignite
	i^ = {
		active = true,
		reduce = app.settings.reduce_motion,
	}
	copy(i.stars[:], stars)
	ui_cue(app, "ui_ignite")
}

// ignite_duration: how long it plays.
ignite_duration :: proc(reduce: bool) -> f32 {
	return IGNITE_FADE if reduce else IGNITE_SECONDS
}

// ignite_step advances it by dt seconds; false once it is over.
ignite_step :: proc(i: ^Ignite, dt: f32) -> bool {
	if !i.active {return false}
	i.t += dt
	if i.t >= ignite_duration(i.reduce) {i.active = false}
	return i.active
}

// ignite_ui steps and draws it over everything (a key or click skips).
ignite_ui :: proc(app: ^App, ctx: ^ui.Context) {
	i := &app.ignite
	if !i.active {return}
	skip := i.frames > 0 && (ctx.input.keys_pressed != {} || ctx.input.mouse_pressed != {})
	i.frames += 1
	if skip || !ignite_step(i, min(app.last_frame_ms / 1000, 0.1)) {
		i.active = false
		return
	}
	prev := ui.begin_layer(ctx, .Tooltip)
	defer ui.end_layer(ctx, prev)
	ignite_draw(ctx, i)
}

ignite_draw :: proc(ctx: ^ui.Context, i: ^Ignite) {
	screen := ctx.screen
	centre := ui.Vec2{screen.w / 2, screen.h / 2}
	if i.reduce {
		ui.fill_rect(ctx, screen, {0, 0, 0, u8(255 * (1 - clamp(i.t / IGNITE_FADE, 0, 1)))})
		return
	}
	fade_start := f32(IGNITE_COLLAPSE + IGNITE_FLASH + IGNITE_ZOOM)
	if i.t < IGNITE_COLLAPSE {
		// The galaxy falls into its middle.
		e := clamp(i.t / IGNITE_COLLAPSE, 0, 1)
		e = e * e * e
		ui.fill_rect(ctx, screen, {0, 0, 0, 255})
		side := min(screen.w, screen.h) * 0.8
		view := ui.Rect{centre.x - side / 2, centre.y - side / 2, side, side}
		for s in i.stars {
			p := ui.Vec2{0.5, 0.5} + (s.position - ui.Vec2{0.5, 0.5}) * (1 - e)
			size := (1 + 1.5 * s.size) * (1 - 0.6 * e) * max(side / 400, 1)
			ui.fill_rect(
				ctx,
				{view.x + p.x * side - size / 2, view.y + p.y * side - size / 2, size, size},
				STAR_PALETTE[s.color],
			)
		}
	} else if i.t < IGNITE_COLLAPSE + IGNITE_FLASH {
		// One white flash, up and down.
		x := (i.t - IGNITE_COLLAPSE) / IGNITE_FLASH
		ui.fill_rect(ctx, screen, {0, 0, 0, 255})
		ui.fill_rect(ctx, screen, {255, 255, 255, u8(255 * (1 - abs(2 * x - 1)))})
	} else if i.t < fade_start {
		// Into the home world: its disc grows until it fills the screen.
		z := (i.t - IGNITE_COLLAPSE - IGNITE_FLASH) / IGNITE_ZOOM
		z = z * z * z
		ui.fill_rect(ctx, screen, {0, 0, 0, 255})
		radius := 4 + z * math.sqrt(screen.w * screen.w + screen.h * screen.h)
		draw_planet(ctx, centre, radius, i.t, 1)
	} else {
		// The planet is all there is; it gives way to the loading screen.
		x := clamp((i.t - fade_start) / (f32(IGNITE_SECONDS) - fade_start), 0, 1)
		radius := 4 + math.sqrt(screen.w * screen.w + screen.h * screen.h)
		draw_planet(ctx, centre, radius, i.t, 1 - x)
	}
}

// draw_planet draws a lit sphere (Earth's colours: seas, land, ice) of this
// radius, turned by spin, in horizontal bands; alpha fades it.
draw_planet :: proc(ctx: ^ui.Context, centre: ui.Vec2, radius, spin: f32, alpha: f32) {
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
			color := ui.Color{36, 84, 170, 255} // sea
			if n > 0.55 {color = {64, 140, 70, 255}} 	// land
			if n > 0.86 {color = {196, 176, 108, 255}} 	// desert
			if abs(ym) > 0.86 {color = {232, 238, 246, 255}} 	// ice caps
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
