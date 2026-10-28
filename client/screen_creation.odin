package client

import "core:time"

// The two modes the creation screen offers (the base pack's; a pack's modes come with the full screen).
MODE_CREATIVE :: "creative"
MODE_SURVIVAL :: "survival"

import "../common/game"
import "../common/worldgen"
import "ui"

// Universe creation (design.md, *Universes*; docs/plan.md M48e): the name, the
// seed as the glyphs of its home world's gate address (typed text or a number
// becomes a seed; Roll draws one), the galaxy around the home world, a
// small home-world preview, the game mode, and Ignite, which creates the
// universe (screen_ignite.odin).

CREATION_STARS :: 4000 // the galaxy view's stars
CREATION_SETTLE_SECONDS :: 0.4 // stars fade and re-settle after a roll

Creation_Screen :: struct {
	name:      [dynamic]u8,
	seed_text: [dynamic]u8, // typed: a word or a number; empty: the rolled seed
	seed:      u64, // what the universe will be made with
	typed:     bool, // seed comes from the text (else rolled)
	mode:      string, // the new universe's default game mode (its id)
	stars:     []game.Star, // the galaxy of seed (CREATION_STARS)
	settle:    f32, // 0 ..= 1: how far the stars have re-settled
	spin:      f32, // the preview planet's turn, radians
}

creation_destroy :: proc(c: ^Creation_Screen) {
	delete(c.stars)
	delete(c.name)
	delete(c.seed_text)
}

// creation_open: the creation screen with a name and a seed ready.
creation_open :: proc(app: ^App) {
	c := &app.creation
	if c.stars == nil {c.stars = make([]game.Star, CREATION_STARS)}
	clear(&c.name)
	text := tr(.Creation_Default_Name, len(app.universes.entries) + 1)
	append(&c.name, text)
	clear(&c.seed_text)
	c.mode = MODE_CREATIVE
	creation_set_seed(c, u64(time.now()._nsec) ~ 0x5eed_5eed, false)
	c.typed = false
	app.screen = .Creation
}

// creation_set_seed: this seed, the galaxy redrawn (animated: the stars
// re-settle over CREATION_SETTLE_SECONDS).
creation_set_seed :: proc(c: ^Creation_Screen, seed: u64, animate: bool) {
	c.seed = seed
	game.galaxy_stars(game.seed_glyphs(seed), c.stars)
	c.settle = 0 if animate else 1
}

// creation_roll draws a new seed (entropy: where it comes from; the tests
// give it) and empties the seed field; the name and the mode stay.
creation_roll :: proc(c: ^Creation_Screen, entropy: u64) {
	clear(&c.seed_text)
	c.typed = false
	// A fixed mix of the entropy, so a roll is never the number it came from.
	creation_set_seed(c, (entropy ~ 0x9e37_79b9_7f4a_7c15) * 0xff51_afd7_ed55_8ccd, true)
}

// creation_sync_seed follows the seed field after typing: text means its
// seed; emptied after typing, a fresh roll.
creation_sync_seed :: proc(c: ^Creation_Screen, entropy: u64) {
	seed, typed := game.seed_of_text(string(c.seed_text[:]))
	switch {
	case typed:
		if !c.typed || seed != c.seed {creation_set_seed(c, seed, true)}
		c.typed = true
	case c.typed:
		creation_roll(c, entropy)
	}
}

// Home_Facts: what the home world is like, in the generator's own
// parameters (the home world is Earth's: worldgen's defaults and the rules'
// defaults, whatever the seed; only its terrain's noise differs).
Home_Facts :: struct {
	warmth:  Text, // Fact_Cold, Fact_Mild or Fact_Hot
	wetness: Text, // Fact_Dry, Fact_Moderate or Fact_Wet
	minutes: int, // a day's length
	terrain: Text, // Fact_Terrain_*
}

home_facts_of :: proc(p: worldgen.Params, rules: game.Rules) -> (f: Home_Facts) {
	f.warmth = .Fact_Mild
	if p.warmth < -0.33 {f.warmth = .Fact_Cold} else if p.warmth > 0.33 {f.warmth = .Fact_Hot}
	f.wetness = .Fact_Moderate
	if p.wetness < -0.33 {f.wetness = .Fact_Dry} else if p.wetness > 0.33 {f.wetness = .Fact_Wet}
	f.minutes = int(rules.day_length / 60)
	switch {
	case p.mountain_height >= 90:
		f.terrain = .Fact_Terrain_Mountains
	case p.hill_height >= 12:
		f.terrain = .Fact_Terrain_Hills
	case:
		f.terrain = .Fact_Terrain_Flat
	}
	return
}

home_facts :: proc() -> Home_Facts {
	return home_facts_of(worldgen.PARAMS_DEFAULTS, game.RULES_DEFAULTS)
}

STAR_PALETTE := [game.STAR_COLORS]ui.Color {
	{255, 255, 255, 255},
	{255, 236, 190, 255},
	{190, 210, 255, 255},
	{255, 190, 160, 255},
	{200, 255, 220, 255},
}

// draw_galaxy draws stars as dots in r over a dark ground; settle (0 ..= 1)
// fades them in (and brings them in from a little way out); the home star
// is ringed.
draw_galaxy :: proc(ctx: ^ui.Context, r: ui.Rect, stars: []game.Star, settle: f32) {
	ui.fill_rect(ctx, r, {6, 8, 16, 255})
	ease := 1 - (1 - settle) * (1 - settle)
	for s in stars {
		centre := ui.Vec2{0.5, 0.5}
		p := centre + (s.position - centre) * (0.85 + 0.15 * ease)
		size := (1 + 1.5 * s.size) * max(r.w / 400, 1)
		color := STAR_PALETTE[s.color]
		color.a = u8(f32(color.a) * (0.25 + 0.75 * ease))
		ui.fill_rect(
			ctx,
			{r.x + p.x * r.w - size / 2, r.y + p.y * r.h - size / 2, size, size},
			color,
		)
		if s.home {
			ring := 6 * max(r.w / 400, 1)
			ui.stroke_rect(
				ctx,
				{r.x + p.x * r.w - ring, r.y + p.y * r.h - ring, 2 * ring, 2 * ring},
				1,
				{255, 220, 120, u8(255 * ease)},
			)
		}
	}
}

creation_screen :: proc(app: ^App, ctx: ^ui.Context) {
	ui.push_id(ctx, "creation")
	defer ui.pop_id(ctx)
	c := &app.creation
	t := &ctx.theme
	dt := min(app.last_frame_ms / 1000, 0.1)
	reduce := app.settings.reduce_motion
	if reduce {c.settle = 1} else {c.settle = min(c.settle + dt / CREATION_SETTLE_SECONDS, 1)}
	if !reduce {c.spin += dt * 0.6}

	area := ui.rect_center(ctx.screen, min(ctx.screen.w - 40, 1000), ctx.screen.h - 40)
	ui.title(ctx, tr(.Creation_Title), ui.cut_top(&area, 60))
	bottom := ui.cut_bottom(&area, t.row_height)
	ui.cut_bottom(&area, t.spacing)
	left := ui.cut_left(&area, min(area.h, area.w * 0.55))
	ui.cut_left(&area, 20)
	draw_galaxy(ctx, ui.rect_shrink(left, 0), c.stars, c.settle)

	ui.layout_begin(ctx, area)
	ui.label(ctx, tr(.Creation_Name), ui.next(ctx), .Left, t.text_muted)
	ui.text_input(ctx, "name", &c.name, ui.next(ctx))
	ui.label(ctx, tr(.Creation_Seed), ui.next(ctx), .Left, t.text_muted)
	row := ui.next(ctx)
	roll := ui.cut_right(&row, 90)
	ui.cut_right(&row, t.spacing)
	ui.text_input(ctx, "seed", &c.seed_text, row)
	creation_sync_seed(c, u64(time.now()._nsec))
	if ui.button(ctx, tr(.Creation_Roll), roll) {creation_roll(c, u64(time.now()._nsec))}
	addr := game.seed_glyphs(c.seed)
	ui.label(ctx, game.address_text(addr), ui.next(ctx), .Left)
	ui.label(ctx, tr(.Creation_Mode), ui.next(ctx), .Left, t.text_muted)
	modes := ui.next(ctx)
	half := (modes.w - t.spacing) / 2
	if ui.button(
		ctx,
		tr(.Universes_Mode_Creative),
		ui.cut_left(&modes, half),
		disabled = c.mode == MODE_CREATIVE,
	) {c.mode = MODE_CREATIVE}
	ui.cut_left(&modes, t.spacing)
	if ui.button(ctx, tr(.Universes_Mode_Survival), modes, disabled = c.mode == MODE_SURVIVAL) {
		c.mode = MODE_SURVIVAL
	}
	ui.label(ctx, tr(.Creation_Home_World), ui.next(ctx), .Left, t.text_muted)
	facts := home_facts()
	planet := ui.next(ctx, 130)
	draw_planet(ctx, {planet.x + planet.w / 2, planet.y + planet.h / 2}, 60, c.spin, 1)
	ui.label(
		ctx,
		tr(.Creation_Climate, tr(.Fact_Pair, tr(facts.warmth), tr(facts.wetness))),
		ui.next(ctx),
		.Left,
	)
	ui.label(ctx, tr(.Creation_Sky, tr(.Fact_Sky_Day, facts.minutes)), ui.next(ctx), .Left)
	ui.label(ctx, tr(.Creation_Terrain, tr(facts.terrain)), ui.next(ctx), .Left)
	ui.layout_end(ctx)

	cancel := ui.cut_left(&bottom, (bottom.w - t.spacing) / 3)
	ui.cut_left(&bottom, t.spacing)
	if ui.button(ctx, tr(.Dial_Cancel), cancel) {app.screen = .Universes}
	if ui.button(ctx, tr(.Creation_Ignite), bottom) {creation_ignite(app)}
}

// creation_ignite creates the universe from the screen's choices and enters
// it, and the big bang plays over the loading.
creation_ignite :: proc(app: ^App) {
	c := &app.creation
	plan := universe_plan(string(c.name[:]), c.seed, c.mode)
	enter_world(app, plan.path, i64(plan.seed), mode = plan.mode)
	if app.session == nil {return} 	// (it could not start: the message says why)
	ignite_start(app, c.stars, c.seed)
}
