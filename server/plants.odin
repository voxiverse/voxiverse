package server

import "../common/game"

// Plants need support: a plant (game.block_is_plant) stands on a block that
// holds it (game.plant_supported). When a block changes, the plant above it
// is checked; one that lost its footing breaks and drops its item as if it
// had been broken by hand (block_drop), and so the plant above that one is
// checked in turn. Bulk edits check the boxes they changed.

// plant_check breaks the plant at p if what it stands on does not hold it;
// true if it did.
plant_check :: proc(w: ^World, p: game.Block_Pos, action: Action_Id) -> bool {
	b, loaded := chunks_block(&w.chunks, p)
	if !loaded || !game.block_is_plant(&w.server.registry.blocks, b) {return false}
	below, below_loaded := chunks_block(&w.chunks, p + {0, -1, 0})
	if !below_loaded || game.block_supported(&w.server.registry.blocks, b, below) {return false}
	if !set_block(w, p, .Air, {action, .Support}) {return false}
	block_drop(w, p, b)
	return true
}

// plants_check_box checks every plant that stood on a block of lo..hi (and
// those inside it, whose support may be gone too).
plants_check_box :: proc(w: ^World, lo, hi: game.Block_Pos, action: Action_Id) {
	for y in lo.y + 1 ..= hi.y + 1 {
		for z in lo.z ..= hi.z {
			for x in lo.x ..= hi.x {plant_check(w, {x, y, z}, action)}
		}
	}
}
