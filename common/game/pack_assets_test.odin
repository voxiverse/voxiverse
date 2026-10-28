package game

import "core:encoding/endian"
import "core:testing"

import "../../base"

@(test)
test_pack_assets_load :: proc(t: ^testing.T) {
	reg, errs := build_with(test_asset_pack())
	testing.expect_value(t, errors_text(errs), "")
	if reg == nil {return}
	marble, _ := registry_block(reg, "testpack:marble")
	tex := reg.textures[reg.blocks.defs[marble].faces[0]]
	testing.expect_value(t, tex.image, TEST_MARBLE_PNG)
	testing.expect_value(t, int(tex.layer), len(TEXTURE_GENERATOR_NAMES))
	testing.expect_value(t, registry_texture_layers(reg), len(TEXTURE_GENERATOR_NAMES) + 1)
	want := test_marble_pixels()
	testing.expect(t, reg.images[0] == want, "the PNG's pixels are not the registry's image")
	snd := reg.sounds[reg.blocks.defs[marble].sound]
	testing.expect(t, sound_has_files(snd))
	testing.expect_value(t, len(snd.clips[.Break]), 1)
	testing.expect_value(t, len(snd.clips[.Place]), 0)
	testing.expect_value(t, len(snd.clips[.Step]), 1)
}

@(private = "file")
build_assets :: proc(files: []File) -> string {
	pack := test_asset_pack()
	list := make([dynamic]Pack_File, context.temp_allocator)
	append(&list, ..pack.files)
	for f in files {
		replaced := false
		for &g in list {
			if g.path == f.path {g.data, replaced = transmute([]u8)f.text, true}
		}
		if !replaced {append(&list, Pack_File{f.path, transmute([]u8)f.text})}
	}
	_, errs := build_with(Pack_Source{"testpack", list[:]})
	return errors_text(errs)
}

@(test)
test_pack_assets_refused :: proc(t: ^testing.T) {
	big, _ := base.png_encode(
		32,
		32,
		make([]u8, 32 * 32 * 4, context.temp_allocator),
		context.temp_allocator,
	)
	testing.expect_value(
		t,
		build_assets({{TEST_MARBLE_PNG, string(big)}}),
		"testpack/assets/textures/marble.png: textures are 16x16 pixels; assets/textures/marble.png is 32x32",
	)
	huge := make([]u8, MAX_PNG_BYTES + 1, context.temp_allocator)
	testing.expect_value(
		t,
		build_assets({{TEST_MARBLE_PNG, string(huge)}}),
		"testpack/assets/textures/marble.png: file is 65537 bytes; the limit is 65536",
	)
	testing.expect_value(
		t,
		build_assets({{TEST_MARBLE_PNG, "not a png"}}),
		"testpack/assets/textures/marble.png: not a PNG file",
	)
	testing.expect_value(
		t,
		build_assets({{"assets/textures/old.png", string(big)}}),
		"testpack/assets/textures/old.png: assets/textures/old.png is not used; remove it",
	)
	testing.expect_value(
		t,
		build_assets({{"assets/sounds/spare.ogg", string(test_click_ogg())}}),
		"testpack/assets/sounds/spare.ogg: assets/sounds/spare.ogg is not used; remove it",
	)
	// A sound of 6 s (the last page's position says so; the file is not decoded to find out).
	long := make([]u8, len(test_click_ogg()), context.temp_allocator)
	copy(long, test_click_ogg())
	rate, _, _ := ogg_length(long)
	at := len(long) - 4
	for at > 0 && string(long[at:at + 4]) != "OggS" {at -= 1}
	endian.put_i64(long[at + 6:], .Little, i64(rate) * 6)
	testing.expect_value(
		t,
		build_assets({{TEST_MARBLE_OGG, string(long)}}),
		"testpack/assets/sounds/click.ogg: sound is 6.0 s; the limit is 5 s\ntestpack/assets/sounds/click.ogg: sound is 6.0 s; the limit is 5 s", // (break and step name it)
	)
	testing.expect_value(
		t,
		build_assets({{TEST_MARBLE_OGG, "OggS nonsense"}}),
		"testpack/assets/sounds/click.ogg: not an Ogg Vorbis file\ntestpack/assets/sounds/click.ogg: not an Ogg Vorbis file",
	)
	testing.expect_value(
		t,
		build_assets(
			{{"assets/sounds/marble.json", `{"marble": {"step": ["assets/sounds/click.ogg"]}}`}},
		),
		"testpack/assets/sounds/marble.json:1:2: a sound set of files needs \"break\"; the other actions fall back to it",
	)
	testing.expect_value(
		t,
		build_assets(
			{{"assets/textures/marble.json", `{"marble": {"image": "assets/textures/nope.png"}}`}},
		),
		"testpack/assets/textures/marble.json:1:22: assets/textures/nope.png is not a file of this pack; PNG textures are in assets/textures/\ntestpack/assets/textures/marble.png: assets/textures/marble.png is not used; remove it",
	)
}

// A reload may change what a thing is, never its number.
@(test)
test_registry_id_changes :: proc(t: ^testing.T) {
	a, ea := build_with(test_asset_pack(7))
	b, eb := build_with(test_asset_pack(12))
	testing.expect(t, a != nil && b != nil)
	if a == nil || b == nil {return}
	testing.expect_value(t, len(ea) + len(eb), 0)
	testing.expect_value(t, registry_id_changes(a, b), "")
	testing.expect(t, a.hash != b.hash)
	base_only, _ := build_with()
	testing.expect_value(
		t,
		registry_id_changes(a, base_only),
		"this reload changes ids (removed testpack:marble); restart the universe to apply it",
	)
	testing.expect_value(
		t,
		registry_id_changes(base_only, a),
		"this reload changes ids (added testpack:marble); restart the universe to apply it",
	)
	// registry_swap: a's address now holds b's contents.
	registry_swap(a, b)
	marble, _ := registry_block(a, "testpack:marble")
	testing.expect_value(t, block_light(&a.blocks, marble), u8(12))
}
