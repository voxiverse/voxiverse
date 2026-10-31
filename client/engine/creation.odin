package engine

import "client:planet"
import "common:game"

Creation_Screen :: struct {
	name:      [dynamic]u8,
	seed_text: [dynamic]u8, // typed: a word or a number; empty: the rolled seed
	seed:      u64, // what the universe will be made with
	typed:     bool, // seed comes from the text (else rolled)
	mode:      string, // the new universe's default game mode (its id)
	stars:     []game.Star, // the galaxy of seed (CREATION_STARS)
	settle:    f32, // 0 ..= 1: how far the stars have re-settled
	spin:      f32, // the preview planet's turn, radians
	planet:    planet.Planet_Palette, // the home world's colours (planet.odin)
}
