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
	{
		name = "sandstone",
		family = .Stone,
		side = "sandstone_side",
		top = "sandstone_top",
		sound = "stone",
	},
	// Wood.
	{name = "oak_log", family = .Wood, side = "log_side", top = "log_top", sound = "wood"},
	{name = "oak_planks", family = .Wood, side = "planks", sound = "wood"},
	// Built and industrial.
	{
		name = "glass",
		family = .Built,
		side = "glass",
		sound = "glass",
		layer = .Cutout,
		cull_same = true,
	},
	{name = "lamp", family = .Built, side = "lamp", sound = "glass", light = 15},
	// Soft and domestic.
	{name = "white_wool", family = .Domestic, side = "wool", sound = "snow"},
	{name = "black_wool", family = .Domestic, side = "wool_black", sound = "snow"},
	// Natural.
	{name = "dirt", family = .Natural, side = "dirt", sound = "dirt"},
	{
		name = "grass",
		family = .Natural,
		side = "grass_side",
		top = "grass_top",
		bottom = "dirt",
		sound = "grass",
	},
	{name = "sand", family = .Natural, side = "sand", sound = "sand"},
	{name = "gravel", family = .Natural, side = "gravel", sound = "gravel"},
	{name = "clay", family = .Natural, side = "clay", sound = "dirt"},
	{name = "snow", family = .Natural, side = "snow", sound = "snow"},
	{name = "ice", family = .Natural, side = "ice", sound = "glass"},
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
// does not define (voxiverse:<generator>), after every pack's textures, so a block of a
// material resolves its faces like any other texture.
@(private)
seed_material_textures :: proc(b: ^Reg_Build) {
	for m in MATERIALS {
		for generator in material_faces(m) {
			id := strings.concatenate({BASE_NAMESPACE, ":", generator})
			if id in b.index[.Texture] {continue}
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
}
