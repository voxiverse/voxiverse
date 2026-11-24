package render

// Look: a game's atmosphere (docs/games.md, "A game's look"): the colour and the air its
// world is drawn in, declared once as data in its client part (engine.Game.look). Every
// field's zero is the engine's own, so a game that declares nothing, or only a fog, is drawn
// as before in everything else. A look moves colour and atmosphere, never the art: the
// textures, the UI and the lighting model are every game's.
Look :: struct {
	time:         f32, // a time of day that stands, 0 < time <= 1 (0.25 sunrise, 0.5 noon, 0.75 sunset, 1 midnight); 0: the world's clock
	zenith:       [3]f32, // the sky overhead (linear rgb); zero: the time of day's
	horizon:      [3]f32, // the sky at the horizon, which the fog fades into; zero: the time of day's
	sun_light:    [3]f32, // what full sky light looks like on blocks and figures; zero: the time of day's
	cloud:        [3]f32, // the clouds' colour (linear rgb); zero: the time of day's
	stars:        f32, // the stars are at least this bright (0..1), by day too: an airless sky; 0: the time of day's
	lamp_light:   [3]f32, // what full block light looks like (a lamp, magma); zero: LAMP_LIGHT, warm
	ambient:      [3]f32, // light added everywhere, in the dark too; zero: none
	figure_light: [3]f32, // the least light creatures, players and items are drawn in, so they read in the dark; zero: FIGURE_LIGHT
	fog:          f32, // blocks away (horizontally) at which the fog is whole, at most the view's; 0: the view's edge
	fog_near:     f32, // where the fog begins, a fraction of fog (0..0.95); 0: FOG_NEAR
	no_clouds:    bool, // no clouds, whatever the player's setting
	no_sun:       bool, // no sun, moon or stars drawn (the light still follows the time)
	grade:        Grade, // the picture's colour, last
}

// Grade: the colour of the finished picture (the world, its figures and the sky; never the
// UI), applied as each is drawn. Zero is none.
Grade :: struct {
	tint:       [3]f32, // multiplies every colour; zero: none (white)
	saturation: f32, // -1 grey .. 0 as it is .. 1 twice as colourful
	contrast:   f32, // -1 flat .. 0 as it is .. 1 harsh, about a mid grey
	vignette:   f32, // 0 none .. 1 the corners dark
}

// LAMP_LIGHT: block light at level 15 (linear rgb): warm, like the lamp's texture.
LAMP_LIGHT :: [3]f32{1.00, 0.82, 0.58}

// FIGURE_LIGHT: the least light a figure is drawn in by default (a night without a moon).
FIGURE_LIGHT :: [3]f32{0.06, 0.06, 0.06}

// FOG_NEAR: where the fog begins by default, a fraction of its distance.
FOG_NEAR :: 0.6

// look_time: the time of day the look draws (its own, or the world's).
look_time :: proc(look: Look, world: f64) -> f64 {
	return f64(look.time) if look.time > 0 else world
}

// look_sky: the sky of a look at the world's time of day: sky_at its time, its colours over
// the time's.
look_sky :: proc(look: Look, world: f64) -> Sky {
	sky := sky_at(look_time(look, world))
	if look.zenith != {} {sky.zenith = look.zenith}
	if look.horizon != {} {sky.horizon = look.horizon}
	if look.sun_light != {} {sky.sky_light = look.sun_light}
	if look.cloud != {} {sky.cloud = look.cloud}
	sky.stars = max(sky.stars, look.stars)
	if look.no_sun {
		sky.stars = 0
		sky.glow_k = 0
	}
	return sky
}

// look_graded: whether the look changes the finished picture's colour.
look_graded :: proc(look: Look) -> bool {
	return look.grade != {}
}
