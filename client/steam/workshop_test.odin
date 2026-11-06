package steam

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"

import "common:game"
import "server:packs"


@(private = "file")
write_pack :: proc(t: ^testing.T, root, item: string, src: game.Pack_Source) {
	for f in src.files {
		path := fmt.tprintf("%s/%s/%s/%s", root, item, src.namespace, f.path)
		dir := filepath.dir(path)
		err := os.make_directory_all(dir)
		testing.expect(t, err == nil || err == .Exist)
		testing.expect(t, os.write_entire_file(path, f.data) == nil)
	}
}

@(private = "file")
errors_text :: proc(errs: []game.Pack_Error) -> string {
	s := ""
	for e in errs {s = fmt.tprintf("%s%s\n", s, game.pack_error_text(e))}
	return s
}

// build: base plus the sources through the normal registry build; the errors as text.
@(private = "file")
build :: proc(extra: []game.Pack_Source) -> (ok: bool, text: string) {
	all := make([dynamic]game.Pack_Source, context.temp_allocator)
	append(&all, game.base_pack_source(context.temp_allocator))
	append(&all, ..extra)
	reg, errs := game.registry_build(all[:])
	if reg == nil {
		text = errors_text(errs)
		game.pack_errors_destroy(errs)
		return false, text
	}
	game.registry_destroy(reg)
	return true, ""
}

@(test)
test_subscribed_item_loads_as_a_pack :: proc(t: ^testing.T) {
	WS_DIR :: "build/tmp/ws_load"
	os.remove_all(WS_DIR)
	defer os.remove_all(WS_DIR)
	write_pack(t, WS_DIR, "111", game.test_asset_pack())
	c: Client
	items := []Fake_Item{{111, WS_DIR + "/111"}}
	testing.expect(t, open_fake(&c, {items = items}))
	defer shutdown(&c)
	found, errs := workshop_packs(&c, context.temp_allocator)
	testing.expect_value(t, len(errs), 0)
	testing.expect_value(t, len(found), 1)
	testing.expect_value(t, found[0].item, 111)
	testing.expect_value(t, found[0].source.namespace, "testpack")
	ok, text := build({found[0].source})
	testing.expectf(t, ok, "the Workshop pack did not load: %s", text)
}

@(test)
test_malformed_item_fails_like_a_local_pack :: proc(t: ^testing.T) {
	WS_DIR :: "build/tmp/ws_bad"
	os.remove_all(WS_DIR)
	defer os.remove_all(WS_DIR)
	bad := game.test_asset_pack()
	files := make([dynamic]game.Pack_File, context.temp_allocator)
	for f in bad.files {
		if f.path == "data/blocks/marble.json" {
			append(
				&files,
				game.Pack_File{f.path, transmute([]u8)string(`{"marble": {"light": 99}`)},
			)
		} else {
			append(&files, f)
		}
	}
	bad.files = files[:]
	write_pack(t, WS_DIR, "222", bad)
	// The same pack as a local folder (a different parent, the same name).
	os.make_directory_all("build/tmp/ws_bad_local")
	defer os.remove_all("build/tmp/ws_bad_local")
	for f in bad.files {
		path := fmt.tprintf("build/tmp/ws_bad_local/%s/%s", bad.namespace, f.path)
		os.make_directory_all(filepath.dir(path))
		testing.expect(t, os.write_entire_file(path, f.data) == nil)
	}
	local, local_errs := packs.pack_read_dir(
		"build/tmp/ws_bad_local/testpack",
		context.temp_allocator,
	)
	testing.expect_value(t, len(local_errs), 0)
	local_ok, local_text := build({local})
	testing.expect(t, !local_ok)

	c: Client
	items := []Fake_Item{{222, WS_DIR + "/222"}}
	testing.expect(t, open_fake(&c, {items = items}))
	defer shutdown(&c)
	found, errs := workshop_packs(&c, context.temp_allocator)
	testing.expect_value(t, len(errs), 0)
	testing.expect_value(t, len(found), 1)
	ok, text := build({found[0].source})
	testing.expect(t, !ok)
	testing.expect_value(t, text, local_text)
}

@(test)
test_item_without_a_pack_folder_is_refused :: proc(t: ^testing.T) {
	WS_DIR :: "build/tmp/ws_empty"
	os.remove_all(WS_DIR)
	defer os.remove_all(WS_DIR)
	os.make_directory_all(WS_DIR + "/333")
	testing.expect(t, os.write_entire_file(WS_DIR + "/333/readme.txt", {'x'}) == nil)
	c: Client
	items := []Fake_Item{{333, WS_DIR + "/333"}, {444, WS_DIR + "/missing"}}
	testing.expect(t, open_fake(&c, {items = items}))
	defer shutdown(&c)
	found, errs := workshop_packs(&c, context.temp_allocator)
	testing.expect_value(t, len(found), 0)
	testing.expect_value(t, len(errs), 2)
}

@(test)
test_steam_off_has_no_workshop :: proc(t: ^testing.T) {
	c: Client
	testing.expect(t, !open_fake(&c, {fail_init = true, items = []Fake_Item{{1, "x"}}}))
	found, errs := workshop_packs(&c, context.temp_allocator)
	testing.expect_value(t, len(found), 0)
	testing.expect_value(t, len(errs), 0)
	testing.expect(t, !workshop_publish(&c, {title = "T"}))
}

@(test)
test_publish_calls_the_fake_with_the_packs_metadata :: proc(t: ^testing.T) {
	WS_DIR :: "build/tmp/ws_publish"
	os.remove_all(WS_DIR)
	defer os.remove_all(WS_DIR)
	dir :: WS_DIR + "/mine"
	err := os.make_directory_all(dir)
	testing.expect(t, err == nil || err == .Exist)
	manifest := `{"format": 1, "namespace": "mine", "version": "1.0.0", "title": "My Pack", "description": "Blocks.", "requires": ["voxiverse"]}`
	testing.expect(t, os.write_entire_file(dir + "/pack.json", transmute([]u8)manifest) == nil)
	testing.expect(t, os.write_entire_file(dir + "/preview.png", {1, 2, 3}) == nil)

	info, reason := workshop_publish_info(dir, context.temp_allocator)
	testing.expect_value(t, reason, "")
	testing.expect_value(t, info.title, "My Pack")
	testing.expect_value(t, info.description, "Blocks.")
	// filepath.join uses the platform separator (backslash on Windows).
	testing.expect_value(
		t,
		info.preview,
		filepath.join({dir, "preview.png"}, context.temp_allocator) or_else "",
	)

	c: Client
	testing.expect(t, open_fake(&c, {}))
	testing.expect(t, workshop_publish(&c, info))
	testing.expect_value(t, c.fake.published, 1)
	testing.expect_value(t, c.fake.last_publish, info)
	shutdown(&c)

	testing.expect(t, open_fake(&c, {fail_publish = true}))
	testing.expect(t, !workshop_publish(&c, info))
	testing.expect_value(t, c.fake.published, 0)
	shutdown(&c)

	_, reason = workshop_publish_info(WS_DIR + "/nowhere", context.temp_allocator)
	testing.expect(t, reason != "")
}
