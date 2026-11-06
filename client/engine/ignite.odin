package engine

import "client:planet"
import "client:starfield"
import "common:game"

IGNITE_STARS :: 1200 // the galaxy's stars the collapse draws

Ignite :: struct {
	active: bool,
	t:      f32, // seconds in
	frames: int, // frames drawn (input in the first is the one that started it)
	reduce: bool,
	stars:  [IGNITE_STARS]game.Star,
	fire:   starfield.Starfield, // the streaks (its own, so the menus' stars are not disturbed)
	planet: planet.Planet_Palette, // the home world's colours (planet.odin)
}
