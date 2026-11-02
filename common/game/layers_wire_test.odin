package game

import "core:testing"

import "common:base"

// Replicated channels on the wire: the layered chunk encodings and the Cell key.

// wire_reg: the base registry with channels: 0 light (computed), 1 wetness (4 bits),
// 2 secret (not replicated), 3 tint (3 bits, default 5), 4 a computed one.
@(private = "file")
wire_reg :: proc() -> ^Registry {
	reg := new(Registry, context.temp_allocator)
	reg^ = test_reg()^
	infos := make([]Channel_Info, 5, context.temp_allocator)
	infos[0] = {
		name       = "voxiverse:light",
		bits       = 4,
		computed   = .Light,
		replicated = false,
	}
	infos[1] = {
		name       = "wetness",
		bits       = 4,
		replicated = true,
	}
	infos[2] = {
		name = "secret",
		bits = 8,
	}
	infos[3] = {
		name       = "tint",
		bits       = 3,
		default    = 5,
		replicated = true,
	}
	infos[4] = {
		name       = "derived",
		bits       = 4,
		replicated = true,
		computed   = .Light,
	}
	reg.channels = infos
	return reg
}

@(private = "file")
wire_decode :: proc(data: []u8, scratch: ^Block_Array) -> (Server_Message, bool) {
	return decode_server(data, scratch, wire_reg())
}

@(private = "file")
chunk_bytes :: proc(blocks: ^Chunk_Blocks, channels: []Wire_Channel) -> [dynamic]u8 {
	w: Writer
	writer_init(&w, context.temp_allocator)
	encode_server(&w, Chunk_Message{pos = {1, 2, 3}, channels = channels}, blocks)
	return w.buf
}

@(private = "file")
filled :: proc(f: proc(i: int) -> u16) -> ^[CHANNEL_CELLS]u16 {
	v := new([CHANNEL_CELLS]u16, context.temp_allocator)
	for &x, i in v {x = f(i)}
	return v
}

@(test)
test_layered_chunks_round_trip :: proc(t: ^testing.T) {
	scratch := new(Block_Array)
	defer free(scratch)
	arr := new(Block_Array, context.temp_allocator)
	for &b, i in arr {b = Block(i % 3)}
	plain_u := Chunk_Blocks {
		uniform = .Stone,
	}
	plain_a := Chunk_Blocks {
		array = arr,
	}

	// No channels: the plain encodings, byte for byte.
	for blocks in ([]^Chunk_Blocks{&plain_u, &plain_a}) {
		with_none := chunk_bytes(blocks, nil)
		w: Writer
		writer_init(&w, context.temp_allocator)
		write_chunk_blocks(&w, blocks)
		tail := string(with_none[len(with_none) - len(w.buf):])
		testing.expect(t, tail == string(w.buf[:]), "a plain chunk's bytes changed")
	}

	// Uniform blocks with one uniform channel, and palette blocks with two.
	uniform_ch := new([CHANNEL_CELLS]u16, context.temp_allocator)
	for &v in uniform_ch {v = 5}
	wet := filled(proc(i: int) -> u16 {return u16(i % 7 if i % 5 == 0 else 0)})
	tint := filled(proc(i: int) -> u16 {return u16(i % 8)})
	for c in ([]struct {
			blocks:   ^Chunk_Blocks,
			channels: []Wire_Channel,
		}{{&plain_u, {{3, uniform_ch}}}, {&plain_a, {{1, wet}, {3, tint}}}, {&plain_u, {{1, wet}}}}) {
		m, ok := wire_decode(chunk_bytes(c.blocks, c.channels)[:], scratch)
		got := m.(Chunk_Message)
		testing.expect(t, ok && got.pos == {1, 2, 3})
		testing.expect_value(t, got.is_uniform, c.blocks.array == nil)
		if c.blocks.array != nil {testing.expect(t, scratch^ == c.blocks.array^)}
		if testing.expect_value(t, len(got.channels), len(c.channels)) {
			for want, i in c.channels {
				testing.expect_value(t, got.channels[i].id, want.id)
				testing.expect(t, got.channels[i].values^ == want.values^, "channel values differ")
			}
		}
	}

	// A chunk_wire_channels of layers: only replicated, stored channels not at their default.
	pools: Layer_Pools
	testing.expect(t, layer_pools_init(&pools, 16) == nil)
	defer layer_pools_destroy(&pools)
	l: Chunk_Layers
	infos := wire_reg().channels
	for info, id in infos {if id < MAX_CHANNELS {l.channels[id].uniform = info.default}}
	testing.expect_value(t, len(chunk_wire_channels(&l, infos)), 0)
	channel_set(&l.channels[2], &pools, 7, 9) // secret: not replicated
	testing.expect_value(t, len(chunk_wire_channels(&l, infos)), 0)
	channel_set(&l.channels[1], &pools, 7, 9)
	channel_set(&l.channels[1], &pools, 8, 2)
	l.channels[3].uniform = 2
	got := chunk_wire_channels(&l, infos)
	if testing.expect_value(t, len(got), 2) {
		testing.expect_value(t, got[0].id, 1)
		testing.expect_value(t, got[0].values[7], 9)
		testing.expect_value(t, got[1].id, 3)
		testing.expect_value(t, got[1].values[100], 2)
	}
	into: Chunk_Layers
	testing.expect(t, layers_from_wire(&into, &pools, infos, got) == nil)
	testing.expect_value(t, channel_get(&into.channels[1], 8), 2)
	testing.expect_value(t, channel_get(&into.channels[3], 4095), 2)
	testing.expect_value(t, channel_get(&into.channels[2], 7), 0)
	layers_release(&into, &pools)
	layers_release(&l, &pools)
}

// Every malformed layered chunk is refused.
@(test)
test_layered_chunks_refuse_malformed :: proc(t: ^testing.T) {
	scratch := new(Block_Array)
	defer free(scratch)
	stone := Chunk_Blocks {
		uniform = .Stone,
	}
	head := chunk_bytes(&stone, nil)
	good_len := len(head)
	build :: proc(head: []u8, tail: []u8) -> []u8 {
		out := make([dynamic]u8, context.temp_allocator)
		append(&out, ..head)
		out[len(head) - 3] += 2 // the encoding byte (u8 encoding, u16 block)
		append(&out, ..tail)
		return out[:]
	}
	ok_tail := []u8{1, 1, 0, 3} // one channel, wetness, uniform 3
	_, ok := wire_decode(build(head[:good_len], ok_tail), scratch)
	testing.expect(t, ok, "the good layered chunk was refused")

	cases := []struct {
		why:  string,
		tail: []u8,
	} {
		{"no channels listed", {0}},
		{"channel 0 (computed light)", {1, 0, 0, 3}},
		{"an unknown channel", {1, 9, 0, 3}},
		{"a computed channel", {1, 4, 0, 3}},
		{"a channel listed twice", {2, 1, 0, 3, 1, 0, 4}},
		{"a value above max", {1, 1, 0, 16}},
		{"a palette past 4096", {1, 1, 1, 0xa1, 0x20}},
		{"runs not summing to 4096", {1, 1, 1, 1, 3, 100, 0}},
		{"an index past the palette", {1, 1, 1, 1, 3, 0x80, 0x20, 1}},
		{"a palette value above max", {1, 1, 1, 1, 99, 0x80, 0x20, 0}},
		{"too many channels", {9, 1, 0, 1}},
		{"an unknown body mode", {1, 1, 7, 1}},
	}
	for c in cases {
		_, ok = wire_decode(build(head[:good_len], c.tail), scratch)
		testing.expectf(t, !ok, "%s was accepted", c.why)
	}
	// Layers where the plain reader reads (saves and replays have their own sections).
	r := reader_make(build(head[:good_len], ok_tail)[good_len - 3:], wire_reg())
	_, _ = read_chunk_blocks(&r, scratch)
	testing.expect(t, !r.ok, "the plain reader took a layered chunk")
	// Every proper prefix, and a trailing byte.
	full := build(head[:good_len], ok_tail)
	for n in 0 ..< len(full) {
		_, ok = wire_decode(full[:n], scratch)
		testing.expectf(t, !ok, "a %d-byte prefix decoded", n)
	}
}

// Mutated layered chunks never crash the decoder, and what it accepts is within the channels' maxima.
@(test)
test_layered_chunk_mutations :: proc(t: ^testing.T) {
	scratch := new(Block_Array)
	defer free(scratch)
	arr := new(Block_Array, context.temp_allocator)
	for &b, i in arr {b = Block(i % 4)}
	wet := filled(proc(i: int) -> u16 {return u16(i / 300)})
	tint := filled(proc(i: int) -> u16 {return u16(i % 8)})
	seeds := [3][dynamic]u8 {
		chunk_bytes(&{array = arr}, {{1, wet}, {3, tint}}),
		chunk_bytes(&{uniform = .Stone}, {{3, tint}}),
		chunk_bytes(&{uniform = .Stone}, {{1, wet}}),
	}
	rng := base.rng_make(49)
	infos := wire_reg().channels
	accepted := 0
	for _ in 0 ..< 3000 {
		data := make([dynamic]u8, context.temp_allocator)
		append(&data, ..seeds[base.rng_int_max(&rng, 3)][:])
		for _ in 0 ..< 1 + base.rng_int_max(&rng, 3) {
			i := base.rng_int_max(&rng, len(data))
			data[i] = u8(base.rng_u32(&rng))
		}
		if base.rng_int_max(&rng, 4) == 0 {resize(&data, base.rng_int_max(&rng, len(data) + 1))}
		m, ok := wire_decode(data[:], scratch)
		if !ok {continue}
		chunk, is_chunk := m.(Chunk_Message)
		if !is_chunk {continue}
		accepted += 1
		for ch in chunk.channels {
			if !testing.expect(
				t,
				int(ch.id) < len(infos) && infos[ch.id].computed == .None,
			) {continue}
			for v in ch.values {testing.expect(t, v <= channel_max(infos[ch.id]), "value above max accepted")}
		}
	}
	testing.expect(t, accepted > 0)
}

@(private = "file")
Cell_Test :: struct {
	key:   Key,
	value: u16,
}

// The Channel record: Cell keys (a position and a channel) in order, several channels of one
// cell, cells of two chunks; they arrive as the sender put them, sorted.
@(test)
test_channel_record_round_trip :: proc(t: ^testing.T) {
	schema := game_schema(context.temp_allocator)
	l: Link
	link_init(&l, &schema)
	defer link_destroy(&l)
	kind := int(State_Kind.Channel)
	put := []Cell_Test {
		{key_of_cell({40, 3, 2}, 3), 7},
		{key_of_cell({1, 1, 1}, 1), 15},
		{key_of_cell({1, 1, 1}, 3), 0},
		{key_of_cell({2, 1, 1}, 1), 4},
		{key_of_cell({-20, 60, 100}, 7), 65535},
		{key_of_cell({1, 1, 1}, 2), 9},
	}
	for c in put {
		v := Channel_Record{c.value}
		sender_put(&l.tx, kind, c.key, &v)
	}
	link_step(&l)
	testing.expect(t, !l.failed, "the Channel records were refused")
	testing.expect_value(t, len(l.events), len(put))
	for i in 1 ..< len(l.events) {
		testing.expect(
			t,
			key_less(.Cell, l.events[i - 1].key, l.events[i].key),
			"the records are not in key order",
		)
	}
	for c in put {
		found := false
		for e in l.events {
			if e.key == c.key {
				found = (^Channel_Record)(e.value).value == c.value
			}
		}
		testing.expectf(t, found, "cell %v channel %d lost", key_block(c.key), c.key.d)
	}
}
