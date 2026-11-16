package engine

import "common:game"
import "common:starmap"

Dial_View :: struct {
	gate:    game.Block_Pos, // the block of the gate clicked
	symbols: [starmap.WORLD_LENGTH]u8,
	count:   int,
	last:    int, // the symbol pressed last: where a pad's focus goes on
}
