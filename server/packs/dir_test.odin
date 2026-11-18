package packs

import "core:testing"

import "common:game"

// A game's own pack is checked where it is: games/<game>/pack is named for its game, so
// its namespace is the game's (before, the folder's name, "pack", which no game's pack.json
// says, was taken for it and the pack refused).
@(test)
test_a_games_pack_read_in_place :: proc(t: ^testing.T) {
	src, errs := pack_read_dir("games/arena/pack", context.temp_allocator)
	testing.expect_value(t, len(errs), 0)
	testing.expect_value(t, src.namespace, "arena")
	reg, build_errs := game.registry_build({game.base_pack_source(context.temp_allocator), src})
	defer if reg != nil {game.registry_destroy(reg)}
	defer game.pack_errors_destroy(build_errs)
	testing.expect(t, reg != nil, "the game's pack did not build")
	for e in build_errs {testing.fail_now(t, game.pack_error_text(e))}
	_, has := game.mode_find(reg, "arena:fighter")
	testing.expect(t, has, "the game's mode is not there")
	// Any other folder is still its own name.
	other, _ := pack_read_dir("games/arena", context.temp_allocator)
	testing.expect_value(t, other.namespace, "arena")
	plain, _ := pack_read_dir("build/nonesuch/pack", context.temp_allocator)
	testing.expect_value(t, plain.namespace, "pack")
}
