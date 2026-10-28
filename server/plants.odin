package server

import "../common/game"

// Support: a block with a support rule (game.has_support_rule: a plant stands
// on a block that holds it; a ladder is against a face that holds it) goes when
// what holds it does. When a block changes, its six neighbours are checked; one
// that lost its footing breaks and drops its item as if it had been broken by
// hand (block_drop), and so its neighbours in turn. Bulk edits check the boxes
// they changed, grown by one on every side.

// support_check breaks the block at p if what holds it is gone; true if it did.
support_check :: proc(w: ^World, p: game.Block_Pos, action: Action_Id) -> bool {
	t := &w.server.registry.blocks
	b, loaded := chunks_block(&w.chunks, p)
	if !loaded || !game.has_support_rule(t, b) {return false}
	query := game.Block_Query{&w.chunks, chunks_block, t}
	if game.support_holds(t, b, p, query) {return false}
	if !set_block(w, p, .Air, {action, .Support}) {return false}
	block_drop(w, p, b)
	return true
}

// supports_check_box checks every block in lo..hi and around it.
supports_check_box :: proc(w: ^World, lo, hi: game.Block_Pos, action: Action_Id) {
	for y in lo.y - 1 ..= hi.y + 1 {
		for z in lo.z - 1 ..= hi.z + 1 {
			for x in lo.x - 1 ..= hi.x + 1 {support_check(w, {x, y, z}, action)}
		}
	}
}
