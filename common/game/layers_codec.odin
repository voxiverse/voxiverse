package game

import "core:mem"

// The saved form of a chunk's channels: after the blocks, entities and waiting
// updates of a chunk record, `varint n` and n channels, each `string name` (the
// channel's own, so a record names its channels whatever the registry's order) and a
// body: `u8 0, varint value` (uniform) or `u8 1, varint palette count, the palette as
// varints, runs of (varint run, varint palette index)`, the runs covering exactly
// CHUNK_VOLUME cells in local_index order. Only stored, saved channels that are not
// uniform at their default are written, so a chunk without values costs one byte.

Saved_Channel :: struct {
	name:   string, // the registry's own string
	values: ^[CHANNEL_CELLS]u16, // (temp or the owner's: a copy of the cells)
}

MAX_CHANNEL_NAME :: 96

// saved_channel_of: the cells of ch as a plain array from allocator.
saved_channel_of :: proc(
	name: string,
	ch: ^Channel,
	allocator := context.temp_allocator,
) -> Saved_Channel {
	v := new([CHANNEL_CELLS]u16, allocator)
	for i in 0 ..< CHANNEL_CELLS {v[i] = channel_get(ch, i)}
	return {name, v}
}

write_channel_body :: proc(w: ^Writer, values: ^[CHANNEL_CELLS]u16) {
	first := values[0]
	same := true
	for v in values {if v != first {same = false; break}}
	if same {
		write_u8(w, 0)
		write_varint(w, u32(first))
		return
	}
	write_u8(w, 1)
	slot := make([]u16, 1 << 16, context.temp_allocator) // palette index + 1, 0: not in it
	palette := make([dynamic]u16, context.temp_allocator)
	for v in values {
		if slot[v] == 0 {
			append(&palette, v)
			slot[v] = u16(len(palette))
		}
	}
	write_varint(w, u32(len(palette)))
	for p in palette {write_varint(w, u32(p))}
	i := 0
	for i < CHANNEL_CELLS {
		v := values[i]
		run := 1
		for i + run < CHANNEL_CELLS && values[i + run] == v {run += 1}
		write_varint(w, u32(run))
		write_varint(w, u32(slot[v] - 1))
		i += run
	}
}

// read_channel_body decodes into out; a value above max, a palette of more than
// CHUNK_VOLUME entries, runs not summing to CHUNK_VOLUME or an index past the palette fail
// the reader.
read_channel_body :: proc(r: ^Reader, out: ^[CHANNEL_CELLS]u16, max: u16) {
	switch read_u8(r) {
	case 0:
		v := read_varint(r)
		if v > u32(max) {reader_fail(r); return}
		for &o in out {o = u16(v)}
	case 1:
		n := read_varint(r)
		if !r.ok || n == 0 || n > CHANNEL_CELLS {reader_fail(r); return}
		palette := make([]u16, n, context.temp_allocator)
		for &p in palette {
			v := read_varint(r)
			if v > u32(max) {reader_fail(r)}
			p = u16(v)
		}
		i := 0
		for r.ok && i < CHANNEL_CELLS {
			run := read_varint(r)
			index := read_varint(r)
			if !r.ok || run == 0 || run > u32(CHANNEL_CELLS - i) || index >= n {
				reader_fail(r)
				return
			}
			for &o in out[i:][:run] {o = palette[index]}
			i += int(run)
		}
	case:
		reader_fail(r)
	}
}

write_layers :: proc(w: ^Writer, saved: []Saved_Channel) {
	write_varint(w, u32(len(saved)))
	for s in saved {
		write_string(w, s.name)
		write_channel_body(w, s.values)
	}
}

// read_layers appends what write_layers wrote to out. A channel the reader's registry
// does not have is dropped (its name appended to unknown, if given: a view into the
// data); one named twice, or the computed one, fails the reader.
read_layers :: proc(
	r: ^Reader,
	out: ^[dynamic]Saved_Channel,
	unknown: ^[dynamic]string = nil,
	allocator := context.temp_allocator,
) {
	n := read_varint(r)
	if !r.ok {return}
	if n > MAX_CHANNELS {reader_fail(r); return}
	for _ in 0 ..< n {
		name := read_string(r, MAX_CHANNEL_NAME)
		values := new([CHANNEL_CELLS]u16, allocator)
		id := -1
		if r.reg != nil {
			for c, i in r.reg.channels {
				if c.name == name && c.computed == .None {id = i}
			}
		}
		max := channel_max(r.reg.channels[id]) if id >= 0 else u16(0xffff)
		read_channel_body(r, values, max)
		if !r.ok {return}
		if id < 0 {
			if unknown != nil {append(unknown, name)}
			continue
		}
		for s in out {if s.name == r.reg.channels[id].name {reader_fail(r); return}}
		append(out, Saved_Channel{r.reg.channels[id].name, values})
	}
}

// layers_apply sets the chunk's channels from saved (by name: a channel not in the
// registry is skipped), compacted.
layers_apply :: proc(
	l: ^Chunk_Layers,
	pools: ^Layer_Pools,
	infos: []Channel_Info,
	saved: []Saved_Channel,
) -> mem.Allocator_Error {
	for s in saved {
		for info, id in infos {
			if info.name != s.name || info.computed != .None {continue}
			ch := &l.channels[id]
			channel_release(ch, pools)
			ch^ = {
				uniform = info.default,
			}
			for v, i in s.values {
				if v != info.default {channel_set(ch, pools, i, v) or_return}
			}
			channel_compact(ch, pools)
		}
	}
	return nil
}

// layers_from_wire makes l what a chunk message said: every channel at its default but
// the ones listed (a mirror's or client's copy; released first).
layers_from_wire :: proc(
	l: ^Chunk_Layers,
	pools: ^Layer_Pools,
	infos: []Channel_Info,
	wire: []Wire_Channel,
) -> mem.Allocator_Error {
	layers_release(l, pools)
	for info, id in infos {
		if id < MAX_CHANNELS {l.channels[id] = {
				uniform = info.default,
			}}
	}
	for wc in wire {
		if int(wc.id) >= len(infos) {continue}
		ch := &l.channels[wc.id]
		d := infos[wc.id].default
		for v, i in wc.values {
			if v != d {channel_set(ch, pools, i, v) or_return}
		}
		channel_compact(ch, pools)
	}
	return nil
}

// layers_set sets one channel's value at local index i (the pools may be exhausted).
layers_set :: proc(
	l: ^Chunk_Layers,
	pools: ^Layer_Pools,
	ch: int,
	i: int,
	v: u16,
) -> mem.Allocator_Error {
	if ch < 0 || ch >= MAX_CHANNELS {return nil}
	return channel_set(&l.channels[ch], pools, i, v)
}
