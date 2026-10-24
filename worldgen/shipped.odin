package worldgen

import "core:path/filepath"
import "core:strings"

import "../game"

// Templates shipped with the game: assets/structures/*.vxs, built in-game
// by us and compiled in (world generation reads no files).

@(private = "file")
SHIPPED := #load_directory("../assets/structures")

// shipped_template: the shipped template called name.
shipped_template :: proc(name: string, allocator := context.allocator) -> (game.Template, bool) {
	for f in SHIPPED {
		if strings.trim_suffix(filepath.base(f.name), ".vxs") ==
		   name {return game.template_decode(f.data, allocator)}
	}
	return {}, false
}

shipped_names :: proc(allocator := context.allocator) -> []string {
	names := make([dynamic]string, allocator)
	for f in SHIPPED {
		if strings.has_suffix(
			f.name,
			".vxs",
		) {append(&names, strings.trim_suffix(filepath.base(f.name), ".vxs"))}
	}
	return names[:]
}
