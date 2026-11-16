package core

import "common:base"
import "common:game"
import "server:grid"

// Grids (server/grid): a world's networks over blocks, a power line's or a pipe's. A game
// opens one with the kinds it is made of (grid_open: which block types conduct, how far
// each reaches, which are machines that join it); the server keeps its parts as blocks
// change (every set_block and bulk edit, a saved chunk loading or unloading) and the game
// reads them (grid_parts, grid_part_at) to balance what each part's generators give
// against what its machines ask. Grids are not saved: they are the blocks', found again as
// the chunks load.

// grid_open: a grid of the kinds given in w, made of the blocks of those kinds already
// loaded; its number (grid_parts, grid_part_at). A game opens its grids in world_opened.
grid_open :: proc(w: ^World, kinds: []grid.Kind) -> int {
	append(&w.grids, grid.grid_make(kinds))
	g := &w.grids[len(w.grids) - 1]
	t := &w.server.registry.blocks
	for at in loaded_chunks(w) {grid_chunk_scan(g, t, at)}
	return len(w.grids) - 1
}

// grid_parts: the parts of w's grid g, by number (temp).
grid_parts :: proc(w: ^World, g: int) -> []^grid.Part {
	return grid.grid_parts(&w.grids[g])
}

// grid_part_at: the number of the part of w's grid g the block at p is in (false: none).
grid_part_at :: proc(w: ^World, g: int, p: game.Block_Pos) -> (u32, bool) {
	return grid.grid_part_of(&w.grids[g], p)
}

// grid_node: the block at p is a node of grid g (a machine), not a conductor.
grid_node :: proc(w: ^World, g: int, p: game.Block_Pos) -> bool {
	return grid.grid_is_node(&w.grids[g], p)
}

@(private = "file")
loaded_chunks :: proc(w: ^World) -> []^Chunk {
	out := make([dynamic]^Chunk, context.temp_allocator)
	it: base.Pool_Iterator
	for c in base.pool_next(&w.chunks.chunks, &it) {if c.state == .Ready {append(&out, c)}}
	return out[:]
}

// grid_chunk_scan: the members of a loaded chunk join grid g.
@(private = "file")
grid_chunk_scan :: proc(g: ^grid.Grid, t: ^game.Block_Table, c: ^Chunk) {
	if c.blocks.array == nil {
		if _, member := g.kinds[t.type_of[c.blocks.uniform]]; !member {return}
	}
	origin := game.chunk_origin(c.pos)
	for local in 0 ..< game.CHUNK_VOLUME {
		l := game.local_from_index(local)
		b := game.chunk_get(&c.blocks, l)
		if k, member := g.kinds[t.type_of[b]]; member {grid.grid_add(g, origin + l, k)}
	}
}

// grids_block: the block at p went from old to new: every grid of the world follows.
@(private)
grids_block :: proc(w: ^World, p: game.Block_Pos, old, new: game.Block) {
	for &g in w.grids {grid.grid_block(&g, &w.server.registry.blocks, p, old, new)}
}

// grids_chunk: a saved chunk came (its members join) or leaves (they go).
@(private)
grids_chunk :: proc(w: ^World, c: ^Chunk, came: bool) {
	if len(w.grids) == 0 {return}
	t := &w.server.registry.blocks
	for &g in w.grids {
		if came {
			grid_chunk_scan(&g, t, c)
			continue
		}
		origin := game.chunk_origin(c.pos)
		for local in 0 ..< game.CHUNK_VOLUME {
			l := game.local_from_index(local)
			if _, member := g.members[origin + l]; member {grid.grid_remove(&g, origin + l)}
		}
	}
}

grids_destroy :: proc(w: ^World) {
	for &g in w.grids {grid.grid_destroy(&g)}
	delete(w.grids)
	w.grids = nil
}
