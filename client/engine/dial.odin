package engine

import "client:font"
import "common:game"
import "common:starmap"

Dial_View :: struct {
	gate:    game.Block_Pos, // the block of the gate clicked
	symbols: [starmap.WORLD_LENGTH]u8,
	count:   int,
	last:    int, // the symbol pressed last: where a pad's focus goes on
}

// symbol_glyph: a gate address's symbol, drawn for the UI from its strokes
// (starmap.symbol_strokes): the UI's ui.Drawn_Glyphs.
symbol_glyph :: proc(r: rune) -> (glyph: font.Drawn, ok: bool) {
	symbol := starmap.symbol_of_rune(r) or_return
	strokes := make([dynamic][2][2]f32, context.temp_allocator)
	starmap.symbol_strokes(symbol, &strokes)
	return {strokes[:], starmap.SYMBOL_WEIGHT, starmap.SYMBOL_ADVANCE}, true
}
