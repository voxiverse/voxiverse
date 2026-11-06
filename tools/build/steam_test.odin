package build

import "core:os"
import "core:strings"
import "core:testing"

// Vdf_Node: a parsed VDF value: a string, or a list of keys with their values.
Vdf_Node :: struct {
	text:     string,
	is_block: bool,
	keys:     [dynamic]string,
	values:   [dynamic]^Vdf_Node,
}

// vdf_parse reads Valve's text format: quoted strings, and { } blocks. ok is false
// for anything else (an unterminated string or block, a key without a value, text
// after the root).
vdf_parse :: proc(text: string) -> (root: ^Vdf_Node, ok: bool) {
	pos := 0
	root = new(Vdf_Node, context.temp_allocator)
	root.is_block = true
	if !vdf_block(text, &pos, root, true) {return nil, false}
	return root, true
}

vdf_skip :: proc(text: string, pos: ^int) {
	for pos^ < len(text) &&
	    (text[pos^] == ' ' || text[pos^] == '\t' || text[pos^] == '\n' || text[pos^] == '\r') {
		pos^ += 1
	}
}

vdf_string :: proc(text: string, pos: ^int) -> (s: string, ok: bool) {
	if pos^ >= len(text) || text[pos^] != '"' {return}
	pos^ += 1
	b := strings.builder_make(context.temp_allocator)
	for pos^ < len(text) {
		c := text[pos^]
		pos^ += 1
		switch c {
		case '"':
			return strings.to_string(b), true
		case '\\':
			if pos^ >= len(text) {return}
			strings.write_byte(&b, text[pos^])
			pos^ += 1
		case '\n':
			return
		case:
			strings.write_byte(&b, c)
		}
	}
	return
}

vdf_block :: proc(text: string, pos: ^int, into: ^Vdf_Node, top: bool) -> bool {
	for {
		vdf_skip(text, pos)
		if pos^ >= len(text) {return top}
		if text[pos^] == '}' {
			if top {return false}
			pos^ += 1
			return true
		}
		key, kok := vdf_string(text, pos)
		if !kok {return false}
		vdf_skip(text, pos)
		if pos^ >= len(text) {return false}
		value := new(Vdf_Node, context.temp_allocator)
		if text[pos^] == '{' {
			pos^ += 1
			value.is_block = true
			if !vdf_block(text, pos, value, false) {return false}
		} else {
			value.text = vdf_string(text, pos) or_return
		}
		append(&into.keys, key)
		append(&into.values, value)
		if top && len(into.keys) > 1 {return false} 	// one root
	}
}

vdf_get :: proc(n: ^Vdf_Node, key: string) -> ^Vdf_Node {
	for k, i in n.keys {if k == key {return n.values[i]}}
	return nil
}

fake_env :: proc(name: string) -> (string, bool) {
	switch name {
	case "STEAM_APP_ID":
		return "480", true
	case "STEAM_DEPOT_WINDOWS":
		return "481", true
	case "STEAM_DEPOT_LINUX":
		return "482", true
	case "STEAM_DEPOT_MACOS":
		return "483", true
	}
	return "", false
}

@(test)
test_vdf_parser_rejects_broken :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	for bad in ([]string{`"a" {`, `"a" "b`, `"a"`, `"a" {} "b" {}`, `}`}) {
		_, ok := vdf_parse(bad)
		testing.expectf(t, !ok, "%q parsed", bad)
	}
	root, ok := vdf_parse(`"a" { "b" "c\"d" }`)
	testing.expect(t, ok)
	testing.expect_value(t, vdf_get(vdf_get(root, "a"), "b").text, `c"d`)
}

@(test)
test_steam_scripts_parse :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	ids := steam_ids(fake_env)
	testing.expect(t, !ids.placeholders)
	testing.expect_value(t, ids.app, "480")

	root, ok := vdf_parse(app_build_vdf(ids, `Voxiverse "1.0"`))
	testing.expect(t, ok, "app_build.vdf parses")
	app := vdf_get(root, "appbuild")
	testing.expect(t, app != nil && app.is_block)
	testing.expect_value(t, vdf_get(app, "appid").text, "480")
	testing.expect_value(t, vdf_get(app, "desc").text, `Voxiverse "1.0"`)
	// Never the default branch.
	live := vdf_get(app, "setlive").text
	testing.expect_value(t, live, "playtest")
	testing.expect(t, live != "" && live != "default")
	depots := vdf_get(app, "depots")
	testing.expect_value(t, len(depots.keys), 3)
	for d, i in STEAM_DEPOTS {
		testing.expect_value(t, depots.keys[i], ids.depots[i])
		testing.expect_value(
			t,
			depots.values[i].text,
			strings.concatenate({"depot_build_", d.name, ".vdf"}, context.temp_allocator),
		)
		script, sok := vdf_parse(depot_build_vdf(ids.depots[i], d))
		testing.expectf(t, sok, "depot %s parses", d.name)
		cfg := vdf_get(script, "DepotBuildConfig")
		testing.expect_value(t, vdf_get(cfg, "DepotID").text, ids.depots[i])
		testing.expect_value(t, vdf_get(cfg, "contentroot").text, d.name)
		testing.expect_value(t, vdf_get(vdf_get(cfg, "FileMapping"), "recursive").text, "1")
		testing.expect_value(t, vdf_get(cfg, "FileExclusion").text, "steam_appid.txt")
	}
}

@(test)
test_steam_placeholders :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	ids := steam_ids(proc(name: string) -> (string, bool) {return "", false})
	testing.expect(t, ids.placeholders)
	testing.expect_value(t, ids.app, STEAM_APP_PLACEHOLDER)
	seen: map[string]bool
	seen[ids.app] = true
	for id in ids.depots {
		testing.expectf(t, !seen[id], "depot ID %s repeats", id)
		seen[id] = true
	}
	// An empty variable is unset too (a repository variable that was never filled in).
	ids = steam_ids(proc(name: string) -> (string, bool) {return " ", true})
	testing.expect(t, ids.placeholders)
}

@(test)
test_steam_appid_never_in_depot :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	dir := path_join({"build", "test-steam-appid"})
	os.remove_all(dir)
	defer os.remove_all(dir)
	os.make_directory_all(path_join({dir, "Voxiverse.app", "Contents", "MacOS"}))
	files := []string {
		path_join({dir, "steam_appid.txt"}),
		path_join({dir, "Voxiverse.app", "Contents", "MacOS", "steam_appid.txt"}),
		path_join({dir, "voxiverse"}),
	}
	for f in files {testing.expect(t, os.write_entire_file(f, transmute([]u8)string("480")) == nil)}
	remove_steam_appid(dir)
	testing.expect(t, !os.exists(files[0]))
	testing.expect(t, !os.exists(files[1]))
	testing.expect(t, os.exists(files[2]))
}
