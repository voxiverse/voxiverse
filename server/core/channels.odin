package core

import "core:mem"

import "common:game"

// Channels (M49): named values a cell carries beside its block, declared by packs
// (data/channels). The server keeps each chunk's stored channels in game.Chunk_Layers
// (palette-compressed pages from Chunk_Store.pools); light, the built-in computed
// channel, is read from the blocks. Changes go through set_channel, which wakes the
// cell as a block change does. A block change resets the cell's channels that do not
// `keep` their value.
//
// Channel changes are not in the journal yet (its entries are block changes): they are
// not undone by a rollback.

// Cell_Key: one channel of one cell.
Cell_Key :: struct {
	pos:     game.Block_Pos,
	channel: u8,
}

// channels_init sizes the page pools: as many pages of each class as chunks times the
// stored channels, so memory has the hard ceiling blocks have.
channels_init :: proc(w: ^Chunk_Store, capacity: int) -> mem.Allocator_Error {
	stored := game.registry_stored_channels(w.reg)
	return game.layer_pools_init(&w.pools, capacity * stored)
}

// chunk_layers_new: layers with every channel uniform at its default.
chunk_layers_new :: proc(w: ^Chunk_Store) -> (l: game.Chunk_Layers) {
	if w.reg == nil {return}
	for info, id in w.reg.channels {
		if id < game.MAX_CHANNELS {l.channels[id].uniform = info.default}
	}
	return
}

// chunk_saved_layers: the stored, saved channels of c that are not uniform at their
// default, as plain arrays from allocator (what a chunk record holds).
chunk_saved_layers :: proc(
	w: ^Chunk_Store,
	c: ^Chunk,
	allocator := context.temp_allocator,
) -> []game.Saved_Channel {
	if w.reg == nil {return nil}
	out := make([dynamic]game.Saved_Channel, allocator)
	for info, id in w.reg.channels {
		if info.computed != .None || !info.saved || id >= game.MAX_CHANNELS {continue}
		ch := &c.layers.channels[id]
		if ch.mode == .Uniform && ch.uniform == info.default {continue}
		append(&out, game.saved_channel_of(info.name, ch, allocator))
	}
	return out[:]
}

// chunks_channel reads channel ch at p: false if the chunk is not loaded (or there is no
// such channel). A computed channel is computed.
chunks_channel :: proc(w: ^World, p: game.Block_Pos, ch: int) -> (u16, bool) {
	infos := w.server.registry.channels
	if ch < 0 || ch >= len(infos) {return 0, false}
	c := chunks_get(&w.chunks, game.chunk_of(p))
	if c == nil || c.state != .Ready {return 0, false}
	switch infos[ch].computed {
	case .Light:
		return u16(light_above(w, p)), true
	case .None:
		return game.channel_get(&c.layers.channels[ch], game.local_index(game.local_of(p))), true
	}
	return 0, false
}

// set_channel sets channel ch at p to v (at most the channel's max), by act and
// told like a block change: false if the chunk is not loaded, the channel is computed
// or unknown, the change is refused (admit) or the page pools are exhausted. A value
// the cell already has is not a change.
set_channel :: proc(
	w: ^World,
	p: game.Block_Pos,
	ch: int,
	v: u16,
	act: Act,
	by: ^Client = nil,
) -> bool {
	s := w.server
	infos := s.registry.channels
	if ch < 0 ||
	   ch >= len(infos) ||
	   infos[ch].computed != .None ||
	   ch >= game.MAX_CHANNELS {return false}
	assert(v <= game.channel_max(infos[ch]), "channel value above its max")
	c := chunks_get(&w.chunks, game.chunk_of(p))
	if c == nil || c.state != .Ready {return false}
	cause := act_current(w, act)
	if admit(w, cause, p) != .Yes {return false}
	i := game.local_index(game.local_of(p))
	if game.channel_get(&c.layers.channels[ch], i) == v {return true}
	chunk_cow(&w.chunks, c)
	if game.channel_set(&c.layers.channels[ch], &w.chunks.pools, i, v) != nil {return false}
	c.modified = true
	if infos[ch].saved {mark_edited(w, c.pos)}
	changes_begin(w).cells[{p, u8(ch)}] = {}
	sim_wake(w, p, cause.action)
	return true
}

// channels_reset_cell: the block at p changed, so its channels that do not keep their
// value go back to their defaults (each recorded, unless record is false: a bulk edit
// sends its chunks whole).
channels_reset_cell :: proc(w: ^World, p: game.Block_Pos, record := true) {
	infos := w.server.registry.channels
	if len(infos) <= 1 {return}
	c := chunks_get(&w.chunks, game.chunk_of(p))
	if c == nil {return}
	i := game.local_index(game.local_of(p))
	for info, id in infos {
		if info.computed != .None || info.keep || id >= game.MAX_CHANNELS {continue}
		ch := &c.layers.channels[id]
		if game.channel_get(ch, i) == info.default {continue}
		chunk_cow(&w.chunks, c)
		game.channel_set(ch, &w.chunks.pools, i, info.default)
		if record {changes_begin(w).cells[{p, u8(id)}] = {}}
	}
}
