package server

import "base:runtime"
import "core:os"
import "core:strings"
import "core:testing"

import "../common/game"

// M47i, hot reload: a pack file changes while the universe runs; the registry
// is rebuilt, swapped in place at a safe moment, and the player here is told
// (Packs_Changed). A reload that would change a number (a block removed) is
// refused and the old registry stays.

@(test)
test_hot_reload :: proc(t: ^testing.T) {
	dir := "build/test_hot_reload"
	os.remove_all(dir)
	defer os.remove_all(dir)
	cfg := grief_config(dir)
	cfg.extra_packs = make([]game.Pack_Source, 1, runtime.default_allocator())
	cfg.extra_packs[0] = game.test_asset_pack(7, allocator = runtime.default_allocator())
	g, ok := grief_open(t, dir, cfg)
	if !ok {grief_close(g); return}
	defer grief_close(g)
	srv := grief_srv(g)
	reg := srv.registry
	marble, _ := game.registry_block(reg, "testpack:marble")
	hash := reg.hash
	testing.expect_value(t, game.block_light(&reg.blocks, marble), u8(7))

	// Marble's light 7 -> 12: swapped in place (everyone's pointer stays good).
	srv.config.extra_packs[0] = game.test_asset_pack(12, allocator = runtime.default_allocator())
	packs_reload_request(srv)
	run(g, 4)
	testing.expect(t, srv.registry == reg, "the registry moved")
	testing.expect_value(t, srv.reload.swaps, 1)
	testing.expect_value(t, game.block_light(&reg.blocks, marble), u8(12))
	testing.expect(t, reg.hash != hash, "the content hash did not change with the light")
	testing.expect_value(t, g.sess.mirror.packs_changed, reg.hash) // (the player here was told)
	testing.expect_value(t, len(srv.pack_blobs), 1)

	// A block removed: refused, the old registry stays in use.
	hash = reg.hash
	cut := make([dynamic]game.Pack_File, context.temp_allocator)
	for f in srv.config.extra_packs[0].files {
		if f.path != "data/blocks/marble.json" {append(&cut, f)}
	}
	srv.config.extra_packs[0] = {"testpack", cut[:]}
	packs_reload_request(srv)
	run(g, 4)
	testing.expect_value(t, srv.reload.swaps, 1)
	testing.expect_value(t, reg.hash, hash)
	testing.expect_value(t, game.block_light(&reg.blocks, marble), u8(12))
	testing.expect(t, srv.reload.pending == nil)
	told := false
	for n in g.sess.mirror.notices {
		told ||=
			n ==
			"this reload changes ids (removed testpack:marble); restart the universe to apply it"
	}
	testing.expect(t, told, "the owner was not told why the reload was refused")
}

// A registry's pack names and versions are its own (voxiverse#79: a join
// read them after the temp allocator and a reload had moved on): they read the
// same after the sources they came from are gone and after a swap.
@(test)
test_packs_text_outlives_sources :: proc(t: ^testing.T) {
	extra := make([]game.Pack_Source, 1, runtime.default_allocator())
	defer delete(extra, runtime.default_allocator())
	extra[0] = game.test_asset_pack(7, allocator = runtime.default_allocator())
	reg, _, problems := packs_registry("", nil, extra, base_dir = "assets/packs/voxiverse")
	if !testing.expect(t, reg != nil, "the registry did not build") {
		for p in problems {testing.expect_value(t, p, "")}
		return
	}
	defer game.registry_destroy(reg)
	want := strings.clone(packs_text(reg))
	defer delete(want)
	free_all(context.temp_allocator) // (the sources were made in it)
	for _ in 0 ..< 64 {_ = make([]u8, 4096, context.temp_allocator)} // (and it is reused)
	testing.expect_value(t, packs_text(reg), want)

	again, _, _ := packs_registry("", nil, extra, base_dir = "assets/packs/voxiverse")
	if !testing.expect(t, again != nil) {return}
	game.registry_swap(reg, again)
	free_all(context.temp_allocator)
	testing.expect_value(t, packs_text(reg), want)
}
