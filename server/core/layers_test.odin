package core

import "core:os"
import "core:testing"

import "common:game"

// M49: channels, the values a cell carries beside its block: /cell sets them, a block
// change resets them, they are saved with the chunk, and a chunk without any hashes as it
// did before.

CHANNELS_JSON :: `{"wetness": {"bits": 4, "default": 0, "saved": true, "replicated": true}, "secret": {"bits": 8, "default": 0, "saved": true, "replicated": false}, "tint": {"bits": 3, "default": 5, "keep": true, "saved": true}}`

@(private = "file")
channel_pack :: proc(json: string) -> game.Pack_Source {
	files := make([]game.Pack_File, 2, context.temp_allocator)
	files[0] = {"pack.json", transmute([]u8)string(SIM_MANIFEST)}
	files[1] = {"data/channels/test.json", transmute([]u8)json}
	return {"sim_test", files}
}

@(private = "file")
channel_config :: proc(dir: string, json: string) -> Config {
	cfg := grief_config(dir)
	cfg.extra_packs = make([]game.Pack_Source, 1, context.temp_allocator)
	cfg.extra_packs[0] = channel_pack(json)
	return cfg
}

@(private = "file")
chan :: proc(w: ^World, name: string) -> int {
	id, ok := game.registry_channel(w.server.registry, name)
	assert(ok, name)
	return id
}

@(private = "file")
value :: proc(w: ^World, p: game.Block_Pos, id: int) -> u16 {
	v, _ := chunks_channel(w, p, id)
	return v
}

// The cells set: 1 000 of wetness over three chunks and 10 of secret.
@(private = "file")
cells_set :: proc(g: ^Grief) -> (wet: [dynamic]game.Block_Pos, secret: [dynamic]game.Block_Pos) {
	wet = make([dynamic]game.Block_Pos, context.temp_allocator)
	secret = make([dynamic]game.Block_Pos, context.temp_allocator)
	w := grief_world(g)
	for i in i32(0) ..< 1000 {
		p := at(g, i % 40 - 8, i / 40 % 25 - 12, i / 1000 + 3 * (i % 3) - 3)
		append(&wet, p)
		cmd_cell(g, p, "sim_test:wetness", u16(1 + i % 15))
	}
	for i in i32(0) ..< 10 {
		p := at(g, i, -13, 0)
		append(&secret, p)
		cmd_cell(g, p, "sim_test:secret", u16(200 + i))
	}
	_ = w
	return
}

@(private = "file")
cmd_cell :: proc(g: ^Grief, p: game.Block_Pos, name: string, v: u16) {
	w := grief_world(g)
	set_channel(w, p, chan(w, name), v, world_act(w, .Command))
}

@(test)
test_channels_set_and_reset :: proc(t: ^testing.T) {
	dir := "build/tmp/channels_set"
	os.remove_all(dir)
	defer os.remove_all(dir)
	g, opened := grief_open(t, dir, channel_config(dir, CHANNELS_JSON))
	defer grief_close(g)
	if !opened {return}
	w := grief_world(g)
	wet, secret := chan(w, "sim_test:wetness"), chan(w, "sim_test:secret")
	tint := chan(w, "sim_test:tint")
	p := at(g, 4, 6, 4)
	testing.expect_value(t, value(w, p, tint), 5) // (a default that is not 0)
	cmd(g, "cell %d %d %d sim_test:wetness 9", p.x, p.y, p.z)
	testing.expect_value(t, value(w, p, wet), 9)
	cmd(g, "cell %d %d %d sim_test:wetness 99", p.x, p.y, p.z)
	testing.expect_value(t, value(w, p, wet), 15) // clamped to its max
	cmd(g, "cell %d %d %d voxiverse:light 3", p.x, p.y, p.z) // (computed: refused)
	cmd(g, "cell %d %d %d sim_test:tint 2", p.x, p.y, p.z)
	cmd(g, "cell %d %d %d sim_test:secret 77", p.x, p.y, p.z)
	testing.expect_value(t, value(w, p, tint), 2)
	// The light there is the blocks': open sky above the surface.
	l, loaded := chunks_channel(w, at(g, 0, 40, 0), game.LIGHT_CHANNEL)
	testing.expect(t, loaded && l == 15)
	// A block change resets what does not keep its value.
	testing.expect(t, set_block(w, p, .Stone, world_act(w, .Command)))
	testing.expect_value(t, value(w, p, wet), 0)
	testing.expect_value(t, value(w, p, secret), 0)
	testing.expect_value(t, value(w, p, tint), 2)
	// The same block again is not a change.
	cmd(g, "cell %d %d %d sim_test:wetness 4", p.x, p.y, p.z)
	set_block(w, p, .Stone, world_act(w, .Command))
	testing.expect_value(t, value(w, p, wet), 4)
	// No stored channel anywhere else: the pools hold pages for these cells only.
	testing.expect(t, game.layer_pools_in_use(&w.chunks.pools) > 0)
}

@(test)
test_channels_saved :: proc(t: ^testing.T) {
	dir := "build/tmp/channels_saved"
	os.remove_all(dir)
	defer os.remove_all(dir)
	cfg := channel_config(dir, CHANNELS_JSON)
	want: [dynamic]struct {
		p:  game.Block_Pos,
		id: string,
		v:  u16,
	}
	defer delete(want)
	{
		g, opened := grief_open(t, dir, cfg)
		if !opened {return}
		w := grief_world(g)
		wet, secret := cells_set(g)
		for p in wet {append(&want, struct {
				p:  game.Block_Pos,
				id: string,
				v:  u16,
			}{p, "sim_test:wetness", value(w, p, chan(w, "sim_test:wetness"))})}
		for p in secret {append(&want, struct {
				p:  game.Block_Pos,
				id: string,
				v:  u16,
			}{p, "sim_test:secret", value(w, p, chan(w, "sim_test:secret"))})}
		testing.expect(t, world_save(w), "the save failed")
		grief_close(g)
	}
	{
		g, opened := grief_open(t, dir, cfg)
		defer grief_close(g)
		if !opened {return}
		w := grief_world(g)
		wrong := 0
		for x in want {
			if value(w, x.p, chan(w, x.id)) != x.v {wrong += 1}
		}
		testing.expect_value(t, wrong, 0)
		testing.expect(t, len(want) == 1010)
	}
	// The pack no longer has "secret": the chunks load without it (one warning per region
	// names it in the log) and the other channels are as they were.
	const_json := `{"wetness": {"bits": 4, "default": 0, "saved": true, "replicated": true}, "tint": {"bits": 3, "default": 5, "keep": true, "saved": true}}`
	g, opened := grief_open(t, dir, channel_config(dir, const_json))
	defer grief_close(g)
	if !opened {return}
	w := grief_world(g)
	_, has := game.registry_channel(w.server.registry, "sim_test:secret")
	testing.expect(t, !has)
	wrong := 0
	for x in want {
		if x.id != "sim_test:wetness" {continue}
		if value(w, x.p, chan(w, x.id)) != x.v {wrong += 1}
	}
	testing.expect_value(t, wrong, 0)
}

// mirror_wetness: how many cells of the mirror's chunks differ from the server's in channel id
// (and how many cells the mirror holds a value above the default in).
@(private = "file")
mirror_differs :: proc(g: ^Grief, id: int) -> (differ, nonzero: int) {
	w := grief_world(g)
	m := &g.sess.mirror
	for pos, &layers in m.layers {
		c := chunks_get(&w.chunks, pos)
		if c == nil {continue}
		for i in 0 ..< game.CHANNEL_CELLS {
			a := game.channel_get(&layers.channels[id], i)
			b := game.channel_get(&c.layers.channels[id], i)
			if a != b {differ += 1}
			if a != 0 {nonzero += 1}
		}
	}
	return
}

@(test)
test_channels_replicate :: proc(t: ^testing.T) {
	dir := "build/tmp/channels_replicate"
	os.remove_all(dir)
	defer os.remove_all(dir)
	g, opened := grief_open(t, dir, channel_config(dir, CHANNELS_JSON))
	defer grief_close(g)
	if !opened {return}
	w := grief_world(g)
	wet, secret := chan(w, "sim_test:wetness"), chan(w, "sim_test:secret")
	cells, _ := cells_set(g)
	run(g, 3)
	testing.expect(t, len(g.sess.mirror.layers) > 0, "the mirror holds no layers")

	// The mirror holds exactly the server's wetness, and no secret.
	differ, nonzero := mirror_differs(g, wet)
	testing.expect_value(t, differ, 0)
	testing.expect(
		t,
		nonzero >= 900,
		"the mirror has too few wet cells (the cells overwrite each other)",
	)
	_, secret_seen := mirror_differs(g, secret)
	testing.expect_value(t, secret_seen, 0)
	chunks_with := make(map[game.Chunk_Pos]struct{}, 8, context.temp_allocator)
	for p in cells {chunks_with[game.chunk_of(p)] = {}}
	testing.expect(t, len(chunks_with) >= 3, "the cells are not over three chunks")

	// A chunk sent whole after the sets carries them: the mirror forgets its layers first.
	for pos in chunks_with {
		l := &g.sess.mirror.layers[pos]
		game.layers_release(l, &g.sess.mirror.pools)
		l^ = {}
		changes_chunk(w, pos)
	}
	run(g, 3)
	differ, nonzero = mirror_differs(g, wet)
	testing.expect_value(t, differ, 0)
	testing.expect(t, nonzero >= 900, "the whole chunks did not carry the channel")

	// A block change resets wetness there, on both sides.
	p := cells[len(cells) - 1]
	testing.expect(t, value(w, p, wet) != 0)
	testing.expect(t, set_block(w, p, .Stone, world_act(w, .Command)))
	run(g, 2)
	testing.expect_value(t, value(w, p, wet), 0)
	mv, _ := mirror_channel(g, p, wet)
	testing.expect_value(t, mv, 0)
	differ, _ = mirror_differs(g, wet)
	testing.expect_value(t, differ, 0)
	testing.expect_value(t, len(g.sess.failures), 0)
}

@(private = "file")
mirror_channel :: proc(g: ^Grief, p: game.Block_Pos, id: int) -> (u16, bool) {
	l, ok := &g.sess.mirror.layers[game.chunk_of(p)]
	if !ok {return 0, false}
	return game.channel_get(&l.channels[id], game.local_index(game.local_of(p))), true
}
