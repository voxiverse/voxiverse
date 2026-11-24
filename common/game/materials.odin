package game

import "core:fmt"
import "core:strings"

// Materials: what a block can be made of (docs/packs.md, "Materials"). A block that names
// one, `"material": "basalt_bricks"`, gets from it everything that follows from what it is
// made of: its textures, its sound set, the light it gives and whether it is seen through.
// Its own fields say otherwise where it gives them (a machine's top, a dimmer lamp). Its
// dust and its colour on a map follow from its textures (the client samples and averages
// their pixels).
//
// The materials ship with the client: their textures are generators (client/texture), so
// a pack a server sends can make a block of any of them without the base pack defining one,
// and a pack that names one this client does not have is refused.

Material_Family :: enum u8 {
	Stone, // rock, and what is cut from it
	Wood,
	Metal,
	Built, // concrete, brick, glass, panels and fixtures
	Domestic, // plaster, thatch, roofs, cloth, books
	Natural, // soil, grass, sand, leaves, snow and ice
	Fantasy, // the dungeon's and the strange
}

MATERIAL_FAMILY_NAMES := [Material_Family]string {
	.Stone    = "stone and masonry",
	.Wood     = "wood",
	.Metal    = "metal",
	.Built    = "built and industrial",
	.Domestic = "soft and domestic",
	.Natural  = "natural",
	.Fantasy  = "fantasy and dungeon",
}

// Material_Def: one material. A face's texture is the base pack's texture of that
// generator's name (voxiverse:<generator>), made by the registry when the base pack has
// none of its own.
Material_Def :: struct {
	name:      string,
	family:    Material_Family,
	side:      string, // the generator of its sides
	top:       string, // of its top ("": the side's)
	bottom:    string, // of its bottom ("": the top's)
	sound:     string, // its sound set: the base pack's voxiverse:<sound>
	light:     u8, // the light it gives, 0..15
	layer:     Layer_Kind, // not .Opaque: seen through (holes: .Cutout; tinted: .Translucent)
	cull_same: bool, // two blocks of it side by side show no face between them (glass)
}

NO_MATERIAL :: i16(-1)

// MATERIALS: every material, by family. Each has a name of its own; docs/packs.md lists
// them (a test holds the list to this table).
@(rodata)
MATERIALS := [?]Material_Def {
	// Stone and masonry.
	{name = "stone", family = .Stone, side = "stone", sound = "stone"},
	{name = "cobblestone", family = .Stone, side = "cobblestone", sound = "stone"},
	{name = "stone_bricks", family = .Stone, side = "stone_bricks", sound = "stone"},
	{name = "stone_tiles", family = .Stone, side = "stone_tiles", sound = "stone"},
	{name = "polished_stone", family = .Stone, side = "polished_stone", sound = "stone"},
	{name = "basalt", family = .Stone, side = "basalt", sound = "stone"},
	{name = "basalt_cobble", family = .Stone, side = "basalt_cobble", sound = "stone"},
	{name = "basalt_bricks", family = .Stone, side = "basalt_bricks", sound = "stone"},
	{name = "basalt_tiles", family = .Stone, side = "basalt_tiles", sound = "stone"},
	{name = "polished_basalt", family = .Stone, side = "polished_basalt", sound = "stone"},
	{
		name = "sandstone",
		family = .Stone,
		side = "sandstone_side",
		top = "sandstone_top",
		sound = "stone",
	},
	{name = "sandstone_cobble", family = .Stone, side = "sandstone_cobble", sound = "stone"},
	{name = "sandstone_bricks", family = .Stone, side = "sandstone_bricks", sound = "stone"},
	{name = "sandstone_tiles", family = .Stone, side = "sandstone_tiles", sound = "stone"},
	{name = "polished_sandstone", family = .Stone, side = "polished_sandstone", sound = "stone"},
	{name = "limestone", family = .Stone, side = "limestone", sound = "stone"},
	{name = "limestone_cobble", family = .Stone, side = "limestone_cobble", sound = "stone"},
	{name = "limestone_bricks", family = .Stone, side = "limestone_bricks", sound = "stone"},
	{name = "limestone_tiles", family = .Stone, side = "limestone_tiles", sound = "stone"},
	{name = "polished_limestone", family = .Stone, side = "polished_limestone", sound = "stone"},
	{name = "slate", family = .Stone, side = "slate", sound = "stone"},
	{name = "slate_cobble", family = .Stone, side = "slate_cobble", sound = "stone"},
	{name = "slate_bricks", family = .Stone, side = "slate_bricks", sound = "stone"},
	{name = "slate_tiles", family = .Stone, side = "slate_tiles", sound = "stone"},
	{name = "polished_slate", family = .Stone, side = "polished_slate", sound = "stone"},
	// Wood.
	{
		name = "birch_log",
		family = .Wood,
		side = "birch_log",
		top = "birch_log_end",
		sound = "wood",
	},
	{name = "birch_planks", family = .Wood, side = "birch_planks", sound = "wood"},
	{name = "birch_panel", family = .Wood, side = "birch_panel", sound = "wood"},
	{name = "oak_log", family = .Wood, side = "log_side", top = "log_top", sound = "wood"},
	{name = "oak_planks", family = .Wood, side = "planks", sound = "wood"},
	{name = "oak_panel", family = .Wood, side = "oak_panel", sound = "wood"},
	{
		name = "spruce_log",
		family = .Wood,
		side = "spruce_log_side",
		top = "spruce_log_end",
		sound = "wood",
	},
	{name = "spruce_planks", family = .Wood, side = "spruce_planks", sound = "wood"},
	{name = "spruce_panel", family = .Wood, side = "spruce_panel", sound = "wood"},
	{
		name = "redwood_log",
		family = .Wood,
		side = "redwood_log",
		top = "redwood_log_end",
		sound = "wood",
	},
	{name = "redwood_planks", family = .Wood, side = "redwood_planks", sound = "wood"},
	{name = "redwood_panel", family = .Wood, side = "redwood_panel", sound = "wood"},
	{
		name = "weathered_log",
		family = .Wood,
		side = "weathered_log",
		top = "weathered_log_end",
		sound = "wood",
	},
	{name = "weathered_planks", family = .Wood, side = "weathered_planks", sound = "wood"},
	{name = "weathered_panel", family = .Wood, side = "weathered_panel", sound = "wood"},
	// Metal.
	{name = "iron_plate", family = .Metal, side = "iron_plate", sound = "metal"},
	{name = "riveted_iron", family = .Metal, side = "riveted_iron", sound = "metal"},
	{
		name = "iron_grating",
		family = .Metal,
		side = "iron_grating",
		sound = "metal",
		layer = .Cutout,
	},
	{name = "rusted_iron", family = .Metal, side = "rusted_iron", sound = "metal"},
	{name = "dark_steel", family = .Metal, side = "dark_steel", sound = "metal"},
	{name = "copper", family = .Metal, side = "copper", sound = "metal"},
	{name = "verdigris_copper", family = .Metal, side = "verdigris_copper", sound = "metal"},
	{name = "brass", family = .Metal, side = "brass", sound = "metal"},
	{name = "hazard_stripes", family = .Metal, side = "hazard_stripes", sound = "metal"},
	{name = "pipes", family = .Metal, side = "pipes", top = "iron_plate", sound = "metal"},
	// Built and industrial.
	{name = "concrete", family = .Built, side = "concrete", sound = "stone"},
	{name = "stained_concrete", family = .Built, side = "stained_concrete", sound = "stone"},
	{name = "concrete_tiles", family = .Built, side = "concrete_tiles", sound = "stone"},
	{name = "asphalt", family = .Built, side = "asphalt", sound = "gravel"},
	{name = "red_bricks", family = .Built, side = "red_bricks", sound = "stone"},
	{name = "painted_red", family = .Built, side = "painted_red", sound = "metal"},
	{name = "painted_blue", family = .Built, side = "painted_blue", sound = "metal"},
	{name = "painted_yellow", family = .Built, side = "painted_yellow", sound = "metal"},
	{name = "painted_white", family = .Built, side = "painted_white", sound = "metal"},
	{
		name = "glass",
		family = .Built,
		side = "glass",
		sound = "glass",
		layer = .Cutout,
		cull_same = true,
	},
	{
		name = "tinted_glass",
		family = .Built,
		side = "tinted_glass",
		sound = "glass",
		layer = .Translucent,
		cull_same = true,
	},
	{name = "lamp", family = .Built, side = "lamp", sound = "glass", light = 15},
	{
		name = "screen",
		family = .Built,
		side = "screen",
		top = "dark_steel",
		sound = "glass",
		light = 7,
	},
	{name = "vent", family = .Built, side = "vent", top = "iron_plate", sound = "metal"},
	{
		name = "conveyor",
		family = .Built,
		side = "conveyor_side",
		top = "conveyor_top",
		bottom = "dark_steel",
		sound = "metal",
	},
	// Soft and domestic.
	{name = "thatch", family = .Domestic, side = "thatch", sound = "grass"},
	{name = "white_plaster", family = .Domestic, side = "white_plaster", sound = "stone"},
	{name = "cream_plaster", family = .Domestic, side = "cream_plaster", sound = "stone"},
	{name = "ochre_plaster", family = .Domestic, side = "ochre_plaster", sound = "stone"},
	{name = "clay_roof", family = .Domestic, side = "clay_roof", sound = "stone"},
	{name = "slate_roof", family = .Domestic, side = "slate_roof", sound = "stone"},
	{name = "white_wool", family = .Domestic, side = "wool", sound = "snow"},
	{name = "black_wool", family = .Domestic, side = "wool_black", sound = "snow"},
	{name = "red_wool", family = .Domestic, side = "red_wool", sound = "snow"},
	{name = "blue_wool", family = .Domestic, side = "blue_wool", sound = "snow"},
	{name = "green_wool", family = .Domestic, side = "green_wool", sound = "snow"},
	{name = "yellow_wool", family = .Domestic, side = "yellow_wool", sound = "snow"},
	{name = "carpet", family = .Domestic, side = "carpet", sound = "snow"},
	{name = "bookshelf", family = .Domestic, side = "bookshelf", top = "planks", sound = "wood"},
	// Natural.
	{name = "dirt", family = .Natural, side = "dirt", sound = "dirt"},
	{name = "mud", family = .Natural, side = "mud", sound = "dirt"},
	{name = "dry_earth", family = .Natural, side = "dry_earth", sound = "dirt"},
	{
		name = "grass",
		family = .Natural,
		side = "grass_side",
		top = "grass_top",
		bottom = "dirt",
		sound = "grass",
	},
	{
		name = "dry_grass",
		family = .Natural,
		side = "dry_grass_side",
		top = "dry_grass_top",
		bottom = "dirt",
		sound = "grass",
	},
	{
		name = "snowy_grass",
		family = .Natural,
		side = "snowy_grass_side",
		top = "snow",
		bottom = "dirt",
		sound = "snow",
	},
	{name = "sand", family = .Natural, side = "sand", sound = "sand"},
	{name = "red_sand", family = .Natural, side = "red_sand", sound = "sand"},
	{name = "gravel", family = .Natural, side = "gravel", sound = "gravel"},
	{name = "clay", family = .Natural, side = "clay", sound = "dirt"},
	{name = "moss", family = .Natural, side = "moss", sound = "grass"},
	{name = "oak_leaves", family = .Natural, side = "leaves", sound = "grass", layer = .Cutout},
	{
		name = "birch_leaves",
		family = .Natural,
		side = "birch_leaves",
		sound = "grass",
		layer = .Cutout,
	},
	{
		name = "autumn_leaves",
		family = .Natural,
		side = "autumn_leaves",
		sound = "grass",
		layer = .Cutout,
	},
	{
		name = "spruce_leaves",
		family = .Natural,
		side = "spruce_leaves",
		sound = "grass",
		layer = .Cutout,
	},
	{name = "snow", family = .Natural, side = "snow", sound = "snow"},
	{name = "ice", family = .Natural, side = "ice", sound = "glass"},
	{name = "packed_ice", family = .Natural, side = "packed_ice", sound = "glass"},
	// Fantasy and dungeon.
	{name = "dark_bricks", family = .Fantasy, side = "dark_bricks", sound = "stone"},
	{name = "mossy_bricks", family = .Fantasy, side = "mossy_bricks", sound = "stone"},
	{name = "rune_stone", family = .Fantasy, side = "rune_stone", sound = "stone", light = 6},
	{name = "bone", family = .Fantasy, side = "bone", sound = "stone"},
	{name = "crystal", family = .Fantasy, side = "crystal", sound = "glass", light = 10},
	{name = "magma", family = .Fantasy, side = "magma", sound = "stone", light = 12},
	{name = "obsidian", family = .Fantasy, side = "obsidian", sound = "glass"},
	// The world classes' ground, fungi, plants and rare resources (common/worldgen/classes.odin).
	{name = "red_rock", family = .Stone, side = "red_rock", sound = "stone"},
	{name = "amber_ore", family = .Stone, side = "amber_ore", sound = "stone"},
	{name = "opal_ore", family = .Stone, side = "opal_ore", sound = "stone"},
	{name = "cryolite_ore", family = .Stone, side = "cryolite_ore", sound = "stone"},
	{name = "sulfur_ore", family = .Stone, side = "sulfur_ore", sound = "stone"},
	{name = "ilmenite_ore", family = .Stone, side = "ilmenite_ore", sound = "stone"},
	{name = "jade_ore", family = .Stone, side = "jade_ore", sound = "stone"},
	{name = "nacre", family = .Stone, side = "nacre", sound = "stone"},
	{name = "ash", family = .Natural, side = "ash", sound = "gravel"},
	{name = "regolith", family = .Natural, side = "regolith", sound = "sand"},
	{
		name = "mycelium",
		family = .Natural,
		side = "mycelium_side",
		top = "mycelium_top",
		bottom = "dirt",
		sound = "grass",
	},
	{name = "fungus_stem", family = .Natural, side = "fungus_stem", sound = "wood"},
	{name = "fungus_cap", family = .Natural, side = "fungus_cap", sound = "wood"},
	{name = "glow_cap", family = .Natural, side = "glow_cap", sound = "wood", light = 11},
	{
		name = "spore_sprout",
		family = .Natural,
		side = "spore_sprout",
		sound = "grass",
		layer = .Cutout,
	},
}

// material_faces: m's generators: side, top, bottom.
material_faces :: proc(m: Material_Def) -> [3]string {
	top := m.top if m.top != "" else m.side
	return {m.side, top, m.bottom if m.bottom != "" else top}
}

// material_index: the material of this name (false: none).
material_index :: proc(name: string) -> (int, bool) {
	for m, i in MATERIALS {if m.name == name {return i, true}}
	return 0, false
}

// materials_doc: the list docs/packs.md gives, by family: a line each, the family in bold
// and its materials' names.
materials_doc :: proc(allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for family in Material_Family {
		names := make([dynamic]string, context.temp_allocator)
		for m in MATERIALS {if m.family == family {append(&names, m.name)}}
		if len(names) == 0 {continue}
		fmt.sbprintf(&b, "- **%s** (%d): ", MATERIAL_FAMILY_NAMES[family], len(names))
		for name, i in names {
			if i > 0 {strings.write_string(&b, ", ")}
			fmt.sbprintf(&b, "`%s`", name)
		}
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// seed_material_textures: a texture for each face of every material that the base pack
// does not define (voxiverse:<generator>), after every pack's textures and in generator
// order, so a block of a material resolves its faces like any other texture.
@(private)
seed_material_textures :: proc(b: ^Reg_Build) {
	faces := make(map[string]bool, allocator = context.temp_allocator)
	for m in MATERIALS {for generator in material_faces(m) {faces[generator] = true}}
	for generator in TEXTURE_GENERATOR_NAMES {
		id := strings.concatenate({BASE_NAMESPACE, ":", generator})
		if generator not_in faces || id in b.index[.Texture] {continue}
		b.index[.Texture][id] = len(b.defs[.Texture])
		field := Def_Field {
			name = "generator",
			value = {kind = .String, s = generator},
			file = "materials",
		}
		def := Merged_Def {
			id   = id,
			file = "materials",
		}
		append(&def.fields, field)
		append(&b.defs[.Texture], def)
	}
}
