package client

import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_text_keys_have_strings :: proc(t: ^testing.T) {
	for key in Text {
		testing.expectf(t, TEXT_EN[key] != "", "%v has no string", key)
	}
}

@(test)
test_tr_positional :: proc(t: ^testing.T) {
	testing.expect_value(t, tr(.Title_Version, "1.2"), "Voxiverse 1.2")
	testing.expect_value(t, tr(.Title_Singleplayer), "Singleplayer")
	// A placeholder with no argument stays as written.
	testing.expect_value(t, tr(.Title_Version), "Voxiverse {0}")
}

// No UI string literal is left in a screen, menu, overlay or HUD file: a
// ui.button, ui.label, ui.title or toast call takes a key (tr) or a name
// from the registry, never English written in the call. Dev panels (dev_*)
// are not translated and not scanned. The scan reads the sources.
@(test)
test_no_string_literals_in_ui_calls :: proc(t: ^testing.T) {
	dir, err := os.open(#directory)
	if !testing.expect(t, err == nil, "cannot open the client directory") {return}
	defer os.close(dir)
	infos, read_err := os.read_all_directory(dir, context.temp_allocator)
	if !testing.expect(t, read_err == nil) {return}
	scanned := 0
	for info in infos {
		name := info.name
		if !strings.has_suffix(name, ".odin") || strings.has_suffix(name, "_test.odin") {continue}
		layered := false
		for prefix in ([]string{"screen_", "menu_", "overlay_", "hud_"}) {
			if strings.has_prefix(name, prefix) {layered = true}
		}
		if !layered {continue}
		data, ok := os.read_entire_file(info.fullpath, context.temp_allocator)
		if !testing.expectf(t, ok == nil, "cannot read %s", name) {continue}
		scanned += 1
		for hit in literal_calls(string(data)) {
			testing.expectf(t, false, "%s:%d: a string literal in %s", name, hit.line, hit.call)
		}
	}
	testing.expect(t, scanned >= 10, "the scan found the layer files")
}

@(private = "file")
Literal_Call :: struct {
	line: int,
	call: string,
}

// literal_calls: the ui.button, ui.label, ui.title and toast calls in
// source whose arguments (but for `id = "..."`, an id and not a text)
// contain a string literal (the empty one aside).
@(private = "file")
literal_calls :: proc(source: string) -> []Literal_Call {
	out := make([dynamic]Literal_Call, context.temp_allocator)
	// Comments out (a // to the end of the line), strings kept.
	b := strings.builder_make(context.temp_allocator)
	in_string := false
	for i := 0; i < len(source); i += 1 {
		c := source[i]
		if in_string {
			strings.write_byte(&b, c)
			if c == '\\' && i + 1 < len(source) {
				i += 1
				strings.write_byte(&b, source[i])
			} else if c == '"' {in_string = false}
			continue
		}
		if c == '"' {in_string = true} else if c == '\'' && i + 2 < len(source) {
			// a character literal: copied whole ('"' is not a string)
			end := i + 2
			if source[i + 1] == '\\' {end += 1}
			strings.write_string(&b, source[i:min(end + 1, len(source))])
			i = end
			continue
		} else if c == '/' && i + 1 < len(source) && source[i + 1] == '/' {
			for i < len(source) && source[i] != '\n' {i += 1}
			strings.write_byte(&b, '\n')
			continue
		}
		strings.write_byte(&b, c)
	}
	text := strings.to_string(b)
	for call in ([]string{"ui.button(", "ui.label(", "ui.title(", "toast("}) {
		from := 0
		for {
			at := strings.index(text[from:], call)
			if at < 0 {break}
			at += from
			from = at + len(call)
			if at > 0 {
				prev := text[at - 1]
				if prev == '_' ||
				   (prev >= 'a' && prev <= 'z') ||
				   (prev >= 'A' && prev <= 'Z') {continue}
			}
			// The arguments, to the matching parenthesis.
			depth, i := 1, from
			quoted := false
			for ; i < len(text) && depth > 0; i += 1 {
				c := text[i]
				if quoted {
					if c == '\\' {i += 1} else if c == '"' {quoted = false}
					continue
				}
				switch c {
				case '"':
					quoted = true
				case '(':
					depth += 1
				case ')':
					depth -= 1
				}
			}
			args := text[from:max(i - 1, from)]
			if id := strings.index(args, "id = \""); id >= 0 {
				end := strings.index(args[id + 6:], "\"")
				if end >=
				   0 {args = strings.concatenate({args[:id], args[id + 6 + end + 1:]}, context.temp_allocator)}
			}
			args, _ = strings.replace_all(args, "\"\"", "", context.temp_allocator) // (nothing to say)
			if strings.contains(args, "\"") {
				line := 1 + strings.count(text[:at], "\n")
				append(&out, Literal_Call{line, strings.trim_right(call, "(")})
			}
		}
	}
	return out[:]
}

// Screens take every colour from the theme's named colours (M40): no
// `ui.Color{...}` literal in a screen, menu, overlay or HUD file. The two
// exceptions are artwork palettes, not interface colours: the ignite
// screen's planet and the creation screen's star colours.
@(test)
test_no_colour_literals_in_screens :: proc(t: ^testing.T) {
	dir, err := os.open(#directory)
	if !testing.expect(t, err == nil, "cannot open the client directory") {return}
	defer os.close(dir)
	infos, read_err := os.read_all_directory(dir, context.temp_allocator)
	if !testing.expect(t, read_err == nil) {return}
	scanned := 0
	for info in infos {
		name := info.name
		if !strings.has_suffix(name, ".odin") || strings.has_suffix(name, "_test.odin") {continue}
		if name == "screen_ignite.odin" || name == "screen_creation.odin" {continue}
		layered := false
		for prefix in ([]string{"screen_", "menu_", "overlay_", "hud_"}) {
			if strings.has_prefix(name, prefix) {layered = true}
		}
		if !layered {continue}
		data, ok := os.read_entire_file(info.fullpath, context.temp_allocator)
		if !testing.expectf(t, ok == nil, "cannot read %s", name) {continue}
		scanned += 1
		testing.expectf(
			t,
			!strings.contains(string(data), "ui.Color{"),
			"%s has a colour literal: use a theme colour",
			name,
		)
	}
	testing.expect(t, scanned >= 10, "the scan found the layer files")
}
