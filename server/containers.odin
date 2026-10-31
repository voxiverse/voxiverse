package server

import "common:base"
import "common:game"

// Blocks that hold things (M30, on block entities since M48b): a chest's
// contents are the container entity of its block (block_entities.odin), kept
// with its chunk, saved with it, made when the block is placed and removed
// with it (its contents spill out). A player looking into a chest has its
// slots in their Inventory (chest, chest_open: common/game/inventory.odin), so
// the ordinary requests move stacks in and out of it, predicted by the
// client like the rest; the entity is the truth, copied in before each
// request and out after it, and told to everyone else looking at it.

// CONTAINER_SWEEP_TICKS: how often the records and the lookers are checked
// against their blocks and reach.
@(private = "file")
CONTAINER_SWEEP_TICKS :: 10

// Chests are looked into from this far beyond the reach before they close.
@(private = "file")
CHEST_LEASH :: 2.0

// use_block: c used the block at pos (right click): a chest opens.
@(private)
use_block :: proc(s: ^Server, c: ^Client, pos: game.Block_Pos) {
	w := c.world
	block, loaded := chunks_block(&w.chunks, pos)
	if !loaded || game.block_entity_kind(&s.registry.blocks, block) != .Container {return}
	if !game.in_reach(
		game.player_eye(c.player),
		pos,
		f64(w.rules.reach) + game.EDIT_REACH_SLACK,
	) {return}
	if _, was := c.open_chest.?; was {chest_close(c)}
	e := block_entity_at(w, pos)
	if e == nil {
		// (a chest no placement made, worldgen's: it has its entity from now on)
		entity_lifecycle(w, pos, .Air, block, {})
		e = block_entity_at(w, pos)
		if e == nil {return}
	}
	c.open_chest = pos
	c.inventory.chest_open = true
	c.inventory.chest = e.slots
	c.inv_changed = true
	record(s, c, .Item_Used, "chest", at = pos)
}

// chest_close: c looks into nothing now.
@(private)
chest_close :: proc(c: ^Client) {
	c.open_chest = nil
	if c.inventory.chest_open {c.inv_changed = true}
	c.inventory.chest, c.inventory.chest_open = {}, false
}

// chest_valid: the chest c looks into is still there, and near.
@(private = "file")
chest_valid :: proc(c: ^Client, pos: game.Block_Pos) -> bool {
	block, loaded := chunks_block(&c.world.chunks, pos)
	return(
		loaded &&
		game.block_entity_kind(&c.world.server.registry.blocks, block) == .Container &&
		game.in_reach(game.player_eye(c.player), pos, f64(c.world.rules.reach) + CHEST_LEASH) \
	)
}

// chest_refresh: before a request, what c sees in its chest is what the
// record holds (others may have changed it); a chest no longer there or near
// closes.
@(private)
chest_refresh :: proc(s: ^Server, c: ^Client) {
	pos, open := c.open_chest.?
	if !open {return}
	if !chest_valid(c, pos) {
		chest_close(c)
		return
	}
	if e := block_entity_at(c.world, pos); e != nil {c.inventory.chest = e.slots}
}

// chest_keep: after a request, the record is what c's chest holds now, and
// everyone else looking at it is told; or c closed it.
@(private)
chest_keep :: proc(s: ^Server, c: ^Client) {
	pos, open := c.open_chest.?
	if !open {return}
	if !c.inventory.chest_open {
		c.open_chest = nil
		return
	}
	w := c.world
	e := block_entity_at(w, pos)
	if e == nil || e.slots == c.inventory.chest {return}
	block_entity_touch(w, pos)
	e.slots = c.inventory.chest
	for &other in s.clients {
		if &other == c || other.state != .Playing || other.world != w {continue}
		if p, looking := other.open_chest.?; looking && p == pos {
			other.inventory.chest = e.slots
			other.inv_changed = true
		}
	}
}

// container_gone: the container at pos was removed with its block (value is
// what it held): everyone looking closes it, and what it held spills out (a
// world without drops spills too: they were somebody's). The stacks carry the
// action that spilled them, so a rollback can take them back.
@(private)
container_gone :: proc(w: ^World, pos: game.Block_Pos, value: ^game.Block_Entity, cause: Act) {
	for &c in w.server.clients {
		if c.world != w {continue}
		if p, looking := c.open_chest.?; looking && p == pos {chest_close(&c)}
	}
	r := &w.entities.rng
	at := [3]f64{f64(pos.x) + 0.5, f64(pos.y) + 0.3, f64(pos.z) + 0.5}
	for st in value.slots {
		if game.stack_empty(st) {continue}
		v := [3]f32{base.rng_f32_range(r, -1, 1), 2.5, base.rng_f32_range(r, -1, 1)}
		if ent := spawn_item(w, at, st, v, -1); ent != nil {ent.action = u32(cause.action)}
	}
}

// containers_tick: lookers who walked off, or whose chest vanished, close it.
@(private)
containers_tick :: proc(w: ^World) {
	s := w.server
	if s.tick % CONTAINER_SWEEP_TICKS != 0 {return}
	for &c in s.clients {
		if c.state != .Playing || c.world != w {continue}
		if pos, open := c.open_chest.?; open && !chest_valid(&c, pos) {chest_close(&c)}
	}
}
