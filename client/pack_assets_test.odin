package client

import "base:runtime"
import "core:log"
import "core:mem/virtual"
import "core:slice"
import "core:testing"

import "client:audio"
import "client:mesh"
import "client:sfx"
import "common:game"

// M47i: a pack's PNG is its texture's layer, level 0, exactly; its Ogg is the
// sound bank's samples (decoded whole, mono, at the mixer's rate).

@(private = "file")
test_assets_registry :: proc() -> ^game.Registry {
	sources := []game.Pack_Source {
		game.base_pack_source(context.temp_allocator),
		game.test_asset_pack(),
	}
	reg, _ := game.registry_build(sources, .Server, context.temp_allocator)
	return reg
}

@(test)
test_pack_png_is_the_texture_layer :: proc(t: ^testing.T) {
	reg := test_assets_registry()
	if !testing.expect(t, reg != nil) {return}
	marble, _ := game.registry_block(reg, "testpack:marble")
	layer := mesh.block_texture(reg, marble, .Pos_X)
	testing.expect_value(t, int(layer), len(game.TEXTURE_GENERATOR_NAMES))
	array := mesh.texture_array(reg)
	per_layer := 0
	for size := mesh.TEXTURE_SIZE;; size /= 2 {
		per_layer += size * size * 4
		if size == 1 {break}
	}
	level0 := array[int(layer) * per_layer:][:mesh.TEXTURE_SIZE * mesh.TEXTURE_SIZE * 4]
	want := game.test_marble_pixels()
	testing.expect(
		t,
		slice.equal(level0, slice.to_bytes(want[:])),
		"level 0 is not the PNG's pixels",
	)
	testing.expect_value(t, len(array), per_layer * game.registry_texture_layers(reg))
	// The layers before it are still the generators'.
	stone: [mesh.TEXTURE_SIZE * mesh.TEXTURE_SIZE]mesh.Rgba
	mesh.generate_texture(.Stone, stone[:])
	testing.expect(t, slice.equal(array[:1024], slice.to_bytes(stone[:])))
}

@(test)
test_pack_ogg_is_in_the_sound_bank :: proc(t: ^testing.T) {
	reg := test_assets_registry()
	if !testing.expect(t, reg != nil) {return}
	m := new(audio.Mixer)
	defer free(m)
	audio.mixer_init(m, audio.DEVICE_RATE)
	bank: Sound_Bank
	defer sounds_destroy(&bank)
	testing.expect_value(t, sounds_load_pack(&bank, m, reg), 2) // break and step: one file each
	marble, _ := game.registry_block(reg, "testpack:marble")
	id, ok := block_sound(&bank, reg, marble, .Break, 0)
	testing.expect(t, ok)
	raw, decoded := audio.decode_clip(game.test_click_ogg(), game.MAX_SOUND_SECONDS)
	if !testing.expect(t, decoded) {return}
	defer delete(raw.samples)
	want := audio.resample_sound(raw, m.rate)
	defer delete(want.samples)
	testing.expect(t, len(want.samples) > 100)
	testing.expect(
		t,
		slice.equal(m.sounds[id].samples, want.samples),
		"the bank's samples are not the Ogg's decode",
	)
	// A place has no file: it takes break's.
	place, place_ok := block_sound(&bank, reg, marble, .Place, 1)
	testing.expect(t, place_ok && place == id)
	step, _ := block_sound(&bank, reg, marble, .Step, 0)
	testing.expect(t, step != id)
	// A generated set still plays generated sounds.
	stone, stone_ok := block_sound(&bank, reg, .Stone, .Break, 0)
	testing.expect(t, stone_ok && int(stone) < audio.PACK_SOUND_BASE)
	_ = sfx.VARIANTS
}

@(private = "file")
marble_registry :: proc(light: int) -> ^game.Registry {
	sources := []game.Pack_Source {
		game.base_pack_source(context.temp_allocator),
		game.test_asset_pack(light),
	}
	reg, errs := game.registry_build(sources, .Server, runtime.default_allocator())
	for e in errs {log.error(game.pack_error_text(e))}
	return reg
}

// brightest_block_light: the highest block light of any vertex the chunk's
// mesh has (the mesh made now, on this thread).
@(private = "file")
brightest_block_light :: proc(w: ^World, pos: game.Chunk_Pos) -> (best: u32, meshed: bool) {
	for task in w.uploads {append(&w.urgent_tasks, task)} 	// (what edits meshed on the spot)
	clear(&w.uploads)
	mesh_now(w, pos)
	if len(w.uploads) != 1 {return 0, false}
	task := w.uploads[0]
	for v in task.vertices {
		_, block := mesh.vertex_light(v)
		best = max(best, block)
	}
	append(&w.urgent_tasks, task)
	clear(&w.uploads)
	return best, true
}

// M47i, hot reload: swapping the registry's contents (what a reload does)
// changes what the next mesh of a chunk is made of: marble lights 7 and then
// 12, and the stone beside it, one air block away, shows it.
@(test)
test_hot_reload_changes_the_next_mesh :: proc(t: ^testing.T) {
	old := marble_registry(7)
	fresh := marble_registry(12)
	if !testing.expect(t, old != nil && fresh != nil) {return}
	testing.expect_value(t, game.registry_id_changes(old, fresh), "")
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	scratch := new(game.Block_Array)
	defer free(scratch)
	w: World
	testing.expect(t, world_init(&w, old, 128, 32, 1, virtual.arena_allocator(&arena)) == nil)
	defer world_destroy(&w)
	add_columns(&w, 2)
	for z in i32(-1) ..= 1 {
		for y in i32(-1) ..= 1 {
			for x in i32(-1) ..= 1 {
				testing.expect(
					t,
					world_set_chunk(
						&w,
						{pos = {x, y, z}, uniform = .Air, is_uniform = true},
						scratch,
					),
				)
			}
		}
	}
	marble, _ := game.registry_block(old, "testpack:marble")
	testing.expect(t, world_set_block(&w, {5, 5, 5}, marble))
	testing.expect(t, world_set_block(&w, {7, 5, 5}, .Stone))
	before, ok := brightest_block_light(&w, {0, 0, 0})
	testing.expect(t, ok)
	// A reload: the new registry replaces the old one's contents in place.
	game.registry_swap(old, fresh)
	world_remesh_all(&w)
	after: u32
	after, ok = brightest_block_light(&w, {0, 0, 0})
	testing.expect(t, ok)
	testing.expectf(t, after > before, "block light %d before the reload, %d after", before, after)
	testing.expect(t, before <= 7, "the light before the reload is marble's 7 at most")
	testing.expect(t, after >= 10, "the light after the reload is about marble's 12")
	game.registry_destroy(old)
}
