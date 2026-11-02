package game

import "core:testing"

@(private = "file")
pools_for :: proc(cap: int) -> Layer_Pools {
	p: Layer_Pools
	assert(layer_pools_init(&p, cap) == nil)
	return p
}

@(test)
test_channel_modes_promote_and_keep_values :: proc(t: ^testing.T) {
	pools := pools_for(2)
	defer layer_pools_destroy(&pools)
	ch: Channel
	plain: [CHANNEL_CELLS]u16
	testing.expect_value(t, ch.mode, Channel_Mode.Uniform)
	steps := [?]struct {
		many: int,
		mode: Channel_Mode,
	}{{2, .Small}, {16, .Small}, {17, .Large}, {256, .Large}, {257, .Direct}, {600, .Direct}}
	cell := 0
	for s in steps {
		for v in 0 ..< s.many {
			if v == 0 {continue}
			cell += 1
			testing.expect(t, channel_set(&ch, &pools, cell, u16(v)) == nil)
			plain[cell] = u16(v)
		}
		testing.expect_value(t, ch.mode, s.mode)
		for i in 0 ..< CHANNEL_CELLS {
			if channel_get(&ch, i) != plain[i] {
				testing.fail_now(t, "value changed")
			}
		}
	}
	layers := Chunk_Layers{}
	layers.channels[0] = ch
	layers_release(&layers, &pools)
	testing.expect_value(t, layer_pools_in_use(&pools), 0)
}

@(test)
test_channel_compact_smallest_mode :: proc(t: ^testing.T) {
	pools := pools_for(2)
	defer layer_pools_destroy(&pools)
	ch: Channel
	for i in 0 ..< 200 {channel_set(&ch, &pools, i, u16(i + 1))}
	testing.expect_value(t, ch.mode, Channel_Mode.Large)
	for i in 0 ..< 200 {channel_set(&ch, &pools, i, 0)}
	channel_set(&ch, &pools, 5, 9)
	channel_set(&ch, &pools, 2, 7)
	testing.expect(t, channel_compact(&ch, &pools) == nil)
	testing.expect_value(t, ch.mode, Channel_Mode.Small)
	pg := (^Small_Page)(ch.page)
	testing.expect_value(t, pg.count, u8(3))
	testing.expect_value(t, pg.palette[0], u16(0))
	testing.expect_value(t, pg.palette[1], u16(7)) // cell 2 comes before cell 5
	testing.expect_value(t, pg.palette[2], u16(9))
	testing.expect_value(t, channel_get(&ch, 5), u16(9))
	testing.expect_value(t, channel_get(&ch, 2), u16(7))
	testing.expect_value(t, layer_pools_in_use(&pools), 1)
	channel_set(&ch, &pools, 5, 0)
	channel_set(&ch, &pools, 2, 0)
	channel_compact(&ch, &pools)
	testing.expect_value(t, ch.mode, Channel_Mode.Uniform)
	testing.expect_value(t, layer_pools_in_use(&pools), 0)
}

@(test)
test_channel_pool_out_of_memory :: proc(t: ^testing.T) {
	pools := pools_for(1)
	defer layer_pools_destroy(&pools)
	a, b: Channel
	testing.expect(t, channel_set(&a, &pools, 0, 1) == nil)
	testing.expect(t, channel_set(&b, &pools, 0, 1) == .Out_Of_Memory)
	testing.expect_value(t, b.mode, Channel_Mode.Uniform)
	l := Chunk_Layers{}
	l.channels[0] = a
	layers_release(&l, &pools)
	zero: Layer_Pools
	defer layer_pools_destroy(&zero)
	testing.expect(t, layer_pools_init(&zero, 0) == nil)
	testing.expect(t, channel_set(&b, &zero, 0, 1) == .Out_Of_Memory)
}

@(test)
test_channel_random_sets_match_array :: proc(t: ^testing.T) {
	pools := pools_for(2)
	defer layer_pools_destroy(&pools)
	ch: Channel
	plain: [CHANNEL_CELLS]u16
	s := u64(12345)
	next :: proc(s: ^u64) -> u64 {
		s^ = s^ * 6364136223846793005 + 1442695040888963407
		return s^ >> 33
	}
	for n in 0 ..< 10000 {
		i := int(next(&s) % CHANNEL_CELLS)
		spread := u64(5) if n < 3000 else u64(400) if n < 6000 else u64(60000)
		v := u16(next(&s) % spread)
		testing.expect(t, channel_set(&ch, &pools, i, v) == nil)
		plain[i] = v
		if n % 250 == 0 {
			if n % 1000 == 0 {channel_compact(&ch, &pools)}
			for k in 0 ..< CHANNEL_CELLS {
				if channel_get(&ch, k) != plain[k] {testing.fail_now(t, "differs")}
			}
		}
	}
	for k in 0 ..< CHANNEL_CELLS {
		if channel_get(&ch, k) != plain[k] {testing.fail_now(t, "differs at the end")}
	}
	l := Chunk_Layers{}
	l.channels[0] = ch
	layers_release(&l, &pools)
	testing.expect_value(t, layer_pools_in_use(&pools), 0)
}

@(test)
test_layers_hash_ignores_mode :: proc(t: ^testing.T) {
	pools := pools_for(4)
	defer layer_pools_destroy(&pools)
	defaults := []u16{0, 3}
	l := Chunk_Layers{}
	testing.expect(t, layers_default(&l, defaults) == false) // channel 1's default is 3
	l.channels[1].uniform = 3
	testing.expect(t, layers_default(&l, defaults))
	which := bit_set[0 ..< MAX_CHANNELS]{0, 1}
	hash :: proc(l: ^Chunk_Layers, d: []u16, w: bit_set[0 ..< MAX_CHANNELS]) -> u64 {
		h := hasher_make()
		hasher_mix(&h, 77)
		hash_chunk_layers(&h, l, d, w)
		return h.h
	}
	base := hash(&Chunk_Layers{channels = {1 = {uniform = 3}}}, defaults, which)
	testing.expect_value(t, hash(&l, defaults, which), base)
	// the same values in Large and in Direct hash alike
	a, b: Layer_Pools
	assert(layer_pools_init(&a, 2) == nil)
	assert(layer_pools_init(&b, 2) == nil)
	defer layer_pools_destroy(&a)
	defer layer_pools_destroy(&b)
	x, y: Chunk_Layers
	for i in 0 ..< 100 {channel_set(&x.channels[0], &a, i, u16(i))}
	testing.expect_value(t, x.channels[0].mode, Channel_Mode.Large)
	for i in 0 ..< 300 {channel_set(&y.channels[0], &b, i, u16(i))}
	for i in 100 ..< 300 {channel_set(&y.channels[0], &b, i, 0)}
	testing.expect_value(t, y.channels[0].mode, Channel_Mode.Direct)
	testing.expect_value(t, hash(&x, defaults, which), hash(&y, defaults, which))
	testing.expect(t, hash(&x, defaults, which) != base)
	layers_release(&x, &a)
	layers_release(&y, &b)
}

@(test)
test_channel_body_round_trip :: proc(t: ^testing.T) {
	values := new([CHANNEL_CELLS]u16, context.temp_allocator)
	out := new([CHANNEL_CELLS]u16, context.temp_allocator)
	for shape in 0 ..< 3 {
		for i in 0 ..< CHANNEL_CELLS {
			switch shape {
			case 0:
				values[i] = 7
			case 1:
				values[i] = u16(i / 100 % 4)
			case:
				values[i] = u16(i * 31 % 1000)
			}
		}
		w: Writer
		writer_init(&w, context.temp_allocator)
		write_channel_body(&w, values)
		r := reader_make(w.buf[:])
		read_channel_body(&r, out, 1000)
		testing.expect(t, reader_finish(&r), "a body did not read back whole")
		testing.expect(t, out^ == values^, "the values changed")
		if shape == 0 {testing.expect_value(t, len(w.buf), 2)} 	// (uniform: a tag and a value)
	}
}

@(test)
test_channel_body_refuses_damage :: proc(t: ^testing.T) {
	out := new([CHANNEL_CELLS]u16, context.temp_allocator)
	body :: proc(f: proc(w: ^Writer)) -> []u8 {
		w: Writer
		writer_init(&w, context.temp_allocator)
		f(&w)
		return w.buf[:]
	}
	cases := [?][]u8 {
		body(proc(w: ^Writer) {write_u8(w, 0); write_varint(w, 16)}), 	// above max 15
		body(proc(w: ^Writer) {write_u8(w, 2)}), 	// an unknown tag
		body(proc(w: ^Writer) {write_u8(w, 1); write_varint(w, 0)}), 	// an empty palette
		body(proc(w: ^Writer) {write_u8(w, 1); write_varint(w, 5000)}), 	// too big a palette
		body(proc(w: ^Writer) {write_u8(w, 1); write_varint(w, 1); write_varint(w, 99)}), 	// above max
		body(proc(w: ^Writer) {
			write_u8(w, 1)
			write_varint(w, 1)
			write_varint(w, 3)
			write_varint(w, 4000)
			write_varint(w, 0)
		}), // runs short of 4096
		body(proc(w: ^Writer) {
			write_u8(w, 1)
			write_varint(w, 1)
			write_varint(w, 3)
			write_varint(w, 4097)
			write_varint(w, 0)
		}), // runs past it
		body(proc(w: ^Writer) {
			write_u8(w, 1)
			write_varint(w, 1)
			write_varint(w, 3)
			write_varint(w, 4096)
			write_varint(w, 1)
		}), // an index past the palette
	}
	for c, i in cases {
		r := reader_make(c)
		read_channel_body(&r, out, 15)
		testing.expectf(t, !reader_finish(&r), "damaged body %d was accepted", i)
	}
}

@(test)
test_layers_without_values_cost_one_byte :: proc(t: ^testing.T) {
	w: Writer
	writer_init(&w, context.temp_allocator)
	write_layers(&w, nil)
	testing.expect_value(t, len(w.buf), 1)
	r := reader_make(w.buf[:])
	got := make([dynamic]Saved_Channel, context.temp_allocator)
	read_layers(&r, &got)
	testing.expect(t, reader_finish(&r) && len(got) == 0)
}
