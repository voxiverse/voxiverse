package worldgen

import "core:strings"

import "../game"

// Templates the base pack ships (assets/packs/voxiverse/server/structures,
// in the registry): world generation reads no files.

// shipped_template: the registry's structure called name (a name without a
// colon is voxiverse:'s), as a copy.
shipped_template :: proc(
	reg: ^game.Registry,
	name: string,
	allocator := context.allocator,
) -> (
	game.Template,
	bool,
) {
	id, ok := game.id_parse(name)
	if !ok {return {}, false}
	index, found := reg.ids[.Structure][game.id_text(id, context.temp_allocator)]
	if !found {return {}, false}
	t := reg.structures[index].template
	t.cells = make([]u16, len(t.cells), allocator)
	copy(t.cells, reg.structures[index].template.cells)
	return t, true
}

// shipped_names: the short names of the registry's structures.
shipped_names :: proc(reg: ^game.Registry, allocator := context.allocator) -> []string {
	names := make([dynamic]string, allocator)
	for s in reg.structures {
		append(&names, strings.trim_prefix(s.id, game.BASE_NAMESPACE + ":"))
	}
	return names[:]
}
