package engine

import "client:planet"
import "common:game"

IGNITE_STARS :: 1200 // the galaxy's stars the collapse draws

Ignite :: struct {
	active: bool,
	t:      f32, // seconds in
	frames: int, // frames drawn (input in the first is the one that started it)
	reduce: bool,
	stars:  [IGNITE_STARS]game.Star,
	planet: planet.Planet_Palette, // the home world's colours (planet.odin)
}
