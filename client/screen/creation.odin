package screen

import "core:time"

// The two modes the creation screen offers (the base pack's; a pack's modes come with the full screen).
MODE_CREATIVE :: "creative"
MODE_SURVIVAL :: "survival"

import "client:engine"
import planet "client:planet"
import "client:ui"
import "common:game"
import "common:worldgen"

// Universe creation: the name, the
// seed as the glyphs of its home world's gate address (typed text or a number
// becomes a seed; Roll draws one), the galaxy around the home world, a
// small home-world preview, the game mode, and Ignite, which creates the
// universe (screen_ignite.odin).

CREATION_STARS :: 4000 // the galaxy view's stars
CREATION_SETTLE_SECONDS :: 0.4 // stars fade and re-settle after a roll

creation_destroy :: proc(c: ^engine.Creation_Screen) {
	delete(c.stars)
	delete(c.name)
	delete(c.seed_text)
}

// creation_open: the creation screen with a name and a seed ready.
creation_open :: proc(app: ^engine.App) {
	c := &app.creation
	if c.stars == nil {c.stars = make([]game.Star, CREATION_STARS)}
	clear(&c.name)
	text := engine.tr(.Creation_Default_Name, len(app.universes.entries) + 1)
	append(&c.name, text)
	clear(&c.seed_text)
	c.mode = MODE_CREATIVE
	creation_set_seed(c, u64(time.now()._nsec) ~ 0x5eed_5eed, false)
	c.typed = false
	c.planet = planet.home_planet_palette(app.registry)
	app.screen = .Creation
}

// creation_set_seed: this seed, the galaxy redrawn (animated: the stars
// re-settle over CREATION_SETTLE_SECONDS).
creation_set_seed :: proc(c: ^engine.Creation_Screen, seed: u64, animate: bool) {
	c.seed = seed
	game.galaxy_stars(game.seed_glyphs(seed), c.stars)
	c.settle = 0 if animate else 1
}

// creation_roll draws a new seed (entropy: where it comes from; the tests
// give it) and empties the seed field; the name and the mode stay.
creation_roll :: proc(c: ^engine.Creation_Screen, entropy: u64) {
	clear(&c.seed_text)
	c.typed = false
	// A fixed mix of the entropy, so a roll is never the number it came from.
	creation_set_seed(c, (entropy ~ 0x9e37_79b9_7f4a_7c15) * 0xff51_afd7_ed55_8ccd, true)
}

// creation_sync_seed follows the seed field after typing: text means its
// seed; emptied after typing, a fresh roll.
creation_sync_seed :: proc(c: ^engine.Creation_Screen, entropy: u64) {
	seed, typed := game.seed_of_text(string(c.seed_text[:]))
	switch {
	case typed:
		if !c.typed || seed != c.seed {creation_set_seed(c, seed, true)}
		c.typed = true
	case c.typed:
		creation_roll(c, entropy)
	}
}

// draw_galaxy draws stars as dots in r over a dark ground; settle (0 ..= 1)
// fades them in (and brings them in from a little way out); the home star
// is ringed.
draw_galaxy :: proc(ctx: ^ui.Context, r: ui.Rect, stars: []game.Star, settle: f32) {
	ui.fill_rect(ctx, r, ctx.theme.preview_fill)
	ease := 1 - (1 - settle) * (1 - settle)
	for s in stars {
		centre := ui.Vec2{0.5, 0.5}
		p := centre + (s.position - centre) * (0.85 + 0.15 * ease)
		size := (1 + 1.5 * s.size) * max(r.w / 400, 1)
		color := ui.Color(game.star_color(s))
		color.a = u8(f32(color.a) * (0.25 + 0.75 * ease))
		ui.fill_rect(
			ctx,
			{r.x + p.x * r.w - size / 2, r.y + p.y * r.h - size / 2, size, size},
			color,
		)
		if s.home {
			ring := 6 * max(r.w / 400, 1)
			ring_color := ctx.theme.focus_ring
			ring_color.a = u8(f32(ring_color.a) * ease)
			ui.stroke_rect(
				ctx,
				{r.x + p.x * r.w - ring, r.y + p.y * r.h - ring, 2 * ring, 2 * ring},
				1,
				ring_color,
			)
		}
	}
}

// Creation_Layout: where the compact screen puts everything (a pure
// function of the screen and the theme, so a test can check it fits).
Creation_Layout :: struct {
	panel, title, galaxy, planet, name, seed, glyphs, roll, mode, ignite: ui.Rect,
	fits:                                                                 bool, // false: the panel needs more height than the screen has
}

CREATION_PANEL_WIDTH :: 720
CREATION_TITLE_HEIGHT :: 60
CREATION_ROLL_WIDTH :: 90
CREATION_SEED_WIDTH :: 0.3 // of the seed row: the typed seed field

// creation_layout: one centred panel: the title, the galaxy and the planet
// side by side (each half the panel's width, square), then the name, the
// seed row (field, glyphs, Roll), the mode toggle and Ignite.
creation_layout :: proc(screen: ui.Rect, t: ui.Theme) -> (l: Creation_Layout) {
	width := min(screen.w - 40, CREATION_PANEL_WIDTH)
	band := width / 2
	height := CREATION_TITLE_HEIGHT + band + 4 * (t.row_height + t.spacing)
	l.fits = height <= screen.h && width > 0
	l.panel = ui.rect_center(screen, width, height)
	area := l.panel
	l.title = ui.cut_top(&area, CREATION_TITLE_HEIGHT)
	top := ui.cut_top(&area, band)
	l.galaxy = ui.cut_left(&top, band)
	l.planet = top
	ui.cut_top(&area, t.spacing)
	l.name = ui.cut_top(&area, t.row_height)
	ui.cut_top(&area, t.spacing)
	row := ui.cut_top(&area, t.row_height)
	ui.cut_top(&area, t.spacing)
	l.mode = ui.cut_top(&area, t.row_height)
	ui.cut_top(&area, t.spacing)
	l.ignite = ui.cut_top(&area, t.row_height)
	l.roll = ui.cut_right(&row, CREATION_ROLL_WIDTH)
	ui.cut_right(&row, t.spacing)
	l.seed = ui.cut_left(&row, row.w * CREATION_SEED_WIDTH)
	ui.cut_left(&row, t.spacing)
	l.glyphs = row
	return
}

creation_screen :: proc(app: ^engine.App, ctx: ^ui.Context) {
	ui.push_id(ctx, "creation")
	defer ui.pop_id(ctx)
	c := &app.creation
	t := &ctx.theme
	dt := min(app.last_frame_ms / 1000, 0.1)
	reduce := app.settings.reduce_motion
	if reduce {c.settle = 1} else {c.settle = min(c.settle + dt / CREATION_SETTLE_SECONDS, 1)}
	if !reduce {c.spin += dt * 0.6}

	l := creation_layout(ctx.screen, t^)
	ui.title(ctx, engine.tr(.Creation_Title), l.title)
	draw_galaxy(ctx, l.galaxy, c.stars, c.settle)
	ui.fill_rect(ctx, l.planet, t.preview_fill)
	draw_planet(
		ctx,
		{l.planet.x + l.planet.w / 2, l.planet.y + l.planet.h / 2},
		min(l.planet.w, l.planet.h) * 0.4,
		c.spin,
		1,
		c.planet,
	)
	ui.text_input(ctx, "name", &c.name, l.name, engine.tr(.Creation_Name))
	ui.text_input(ctx, "seed", &c.seed_text, l.seed, engine.tr(.Creation_Seed))
	creation_sync_seed(c, u64(time.now()._nsec))
	ui.label(ctx, game.address_text(game.seed_glyphs(c.seed)), l.glyphs, .Center)
	if ui.button(ctx, engine.tr(.Creation_Roll), l.roll) {
		creation_roll(c, u64(time.now()._nsec))
	}
	// The home world is Earth: animals, no peoples (a line at the planet's foot).
	home := worldgen.world_life(game.seed_glyphs(c.seed), home = true)
	line := l.planet
	line.y += line.h - t.row_height
	line.h = t.row_height
	ui.label(ctx, engine.life_line(home), line, .Center, t.text_muted)
	mode := 1 if c.mode == MODE_SURVIVAL else 0
	names := [2]string{engine.tr(.Universes_Mode_Creative), engine.tr(.Universes_Mode_Survival)}
	ui.choice(ctx, engine.tr(.Creation_Mode), &mode, names[:], l.mode)
	c.mode = MODE_SURVIVAL if mode == 1 else MODE_CREATIVE
	if ui.button(ctx, engine.tr(.Creation_Ignite), l.ignite) {creation_ignite(app)}
}

// creation_ignite creates the universe from the screen's choices and enters
// it, and the big bang plays over the loading.
creation_ignite :: proc(app: ^engine.App) {
	c := &app.creation
	plan := universe_plan(string(c.name[:]), c.seed, c.mode)
	engine.enter_world(app, plan.path, i64(plan.seed), mode = plan.mode)
	if app.session == nil {return} 	// (it could not start: the message says why)
	ignite_start(app, c.stars, c.seed)
}
