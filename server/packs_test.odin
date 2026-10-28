package server

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

import "../common/game"

// A universe's packs (M47a): a pack the universe lists adds a block with no
// code of its own; the block is placed, saved by name and loaded again, and a
// universe whose packs no longer define a saved block is refused (unless it
// says `unknown_blocks = air`).

MANIFEST :: `{"format": 1, "namespace": "testpack", "version": "1.0.0", "title": "Test pack", "requires": ["voxiverse"]}`
MARBLE :: `{"marble": {"textures": {"all": "voxiverse:stone"}, "light": 7, "sound": "voxiverse:stone"}}`

@(private = "file")
marble_pack :: proc() -> game.Pack_Source {
	files := make([]game.Pack_File, 2, context.temp_allocator)
	files[0] = {"pack.json", transmute([]u8)string(MANIFEST)}
	files[1] = {"data/blocks/marble.json", transmute([]u8)string(MARBLE)}
	return {"testpack", files}
}

@(private = "file")
pack_config :: proc(dir: string, with_pack: bool) -> Config {
	cfg := grief_config(dir)
	if with_pack {
		cfg.extra_packs = make([]game.Pack_Source, 1, context.temp_allocator)
		cfg.extra_packs[0] = marble_pack()
	}
	return cfg
}

@(test)
test_pack_block_is_placed_saved_and_loaded :: proc(t: ^testing.T) {
	dir := "build/test_pack_block"
	os.remove_all(dir)
	defer os.remove_all(dir)
	g, ok := grief_open(t, dir, pack_config(dir, true))
	if !ok {grief_close(g); return}
	reg := grief_srv(g).registry
	marble, found := game.registry_block(reg, "testpack:marble")
	testing.expect(t, found, "the pack's block is not in the registry")
	at := at(g, 3, 0, 0)
	cmd(g, "setblock %d %d %d testpack:marble", at.x, at.y, at.z)
	b, _ := chunks_block(&grief_world(g).chunks, at)
	testing.expect_value(t, b, marble)
	testing.expect(
		t,
		game.block_light(&reg.blocks, marble) == 7 && game.block_collides(&reg.blocks, marble),
		"the pack's flags did not reach the table",
	)
	grief_close(g)

	// Saved by name: the region file names it, and a game without the pack
	// does not know it.
	files, _ := os.read_all_directory_by_path(
		fmt.tprintf("%s/%s", dir, WORLDS_DIR),
		context.temp_allocator,
	)
	testing.expect(t, len(files) == 1, "no world was saved")
	regions := fmt.tprintf("%s/%s/%s/regions", dir, WORLDS_DIR, files[0].name)
	entries, _ := os.read_all_directory_by_path(regions, context.temp_allocator)
	testing.expect(t, len(entries) > 0, "no region was saved")
	named := false
	base_reg := test_reg()
	for e in entries {
		data, _ := os.read_entire_file_from_path(
			fmt.tprintf("%s/%s", regions, e.name),
			context.temp_allocator,
		)
		if strings.contains(string(data), "testpack:marble") {named = true}
		_ = base_reg
	}
	testing.expect(t, named, "the region file does not name testpack:marble")

	// Loaded again with the pack: still there.
	g2, ok2 := grief_open(t, dir, pack_config(dir, true))
	if !ok2 {grief_close(g2); return}
	defer grief_close(g2)
	marble2, _ := game.registry_block(grief_srv(g2).registry, "testpack:marble")
	b2, loaded := chunks_block(&grief_world(g2).chunks, at)
	testing.expect(t, loaded)
	testing.expect_value(t, b2, marble2)
}

@(test)
test_unknown_block_refuses_the_world :: proc(t: ^testing.T) {
	dir := "build/test_pack_unknown"
	os.remove_all(dir)
	defer os.remove_all(dir)
	g, ok := grief_open(t, dir, pack_config(dir, true))
	if !ok {grief_close(g); return}
	at := at(g, 3, 0, 0)
	cmd(g, "setblock %d %d %d testpack:marble", at.x, at.y, at.z)
	grief_close(g)

	// Without the pack: refused, naming the block.
	srv: Server
	{
		context.logger = log.nil_logger() // (the refusal is the point)
		testing.expect(
			t,
			!start(&srv, pack_config(dir, false), {}),
			"a world with unknown blocks loaded",
		)
	}
	testing.expect(
		t,
		strings.contains(srv.refusal, "testpack:marble"),
		fmt.tprintf("the refusal does not name the block: %q", srv.refusal),
	)

	// `unknown_blocks = air`: loads, the block is air.
	path := fmt.tprintf("%s/%s", dir, UNIVERSE_FILE)
	text, _ := os.read_entire_file_from_path(path, context.temp_allocator)
	with := fmt.tprintf("%s\nunknown_blocks = air\n", string(text))
	_ = os.write_entire_file(path, transmute([]u8)with)
	g2, ok2 := grief_open(t, dir, pack_config(dir, false))
	if !ok2 {grief_close(g2); return}
	defer grief_close(g2)
	b, loaded := chunks_block(&grief_world(g2).chunks, at)
	testing.expect(t, loaded)
	testing.expect_value(t, b, game.Block.Air)
}
