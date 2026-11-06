package core

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

import "common:game"

// A universe's packs: a pack the universe lists adds a block with no
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
	h := new(Harness)
	defer free(h)
	{
		context.logger = log.nil_logger() // (the refusal is the point)
		testing.expect(
			t,
			!harness_start(h, pack_config(dir, false)),
			"a world with unknown blocks loaded",
		)
	}
	testing.expect(
		t,
		strings.contains(h.srv.refusal, "testpack:marble"),
		fmt.tprintf("the refusal does not name the block: %q", h.srv.refusal),
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

// A listed pack the universe does not hold is found among the candidates (the client's
// local packs, the Workshop); a candidate that did not read cleanly stops the universe,
// naming where it came from; a candidate nobody lists is never loaded.
@(test)
test_listed_pack_is_found_among_candidates :: proc(t: ^testing.T) {
	found := []Pack_Candidate{{source = marble_pack(), origin = "Workshop item 7"}}
	reg, _, problems := packs_registry("", {"testpack"}, available = found)
	testing.expect_value(t, len(problems), 0)
	testing.expect(t, reg != nil, "the listed pack was not found")
	if reg != nil {
		_, has := game.registry_block(reg, "testpack:marble")
		testing.expect(t, has, "the Workshop pack's block is not in the registry")
		game.registry_destroy(reg)
	}

	reg, _, problems = packs_registry("", nil, available = found)
	testing.expect(t, reg != nil, "an unlisted candidate stopped the universe")
	if reg != nil {
		_, has := game.registry_block(reg, "testpack:marble")
		testing.expect(t, !has, "an unlisted candidate was loaded")
		game.registry_destroy(reg)
	}

	bad := []Pack_Candidate {
		{
			source = {namespace = "testpack"},
			origin = "Workshop item 7",
			problems = {"cannot read the item"},
		},
	}
	reg, _, problems = packs_registry("", {"testpack"}, available = bad)
	testing.expect(t, reg == nil, "a bad Workshop item did not stop the universe")
	testing.expect(
		t,
		len(problems) == 1 && strings.contains(problems[0], "Workshop item 7"),
		"the problem does not name the item",
	)

	reg, _, problems = packs_registry("", {"testpack"})
	testing.expect(t, reg == nil && len(problems) == 1, "a missing pack was not refused")
}
