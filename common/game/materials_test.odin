package game

import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

// Every material is whole: a name of its own, faces the client draws (generators), a sound
// set the base pack has, a light a block can give.
@(test)
test_materials_are_whole :: proc(t: ^testing.T) {
	reg := registry_base()
	defer registry_destroy(reg)
	seen := make(map[string]bool, allocator = context.temp_allocator)
	for m in MATERIALS {
		testing.expectf(t, id_part_valid(m.name, 48), "%q is not a name", m.name)
		testing.expectf(t, m.name not_in seen, "%q is a material twice", m.name)
		seen[m.name] = true
		for g in material_faces(m) {
			testing.expectf(
				t,
				slice.contains(TEXTURE_GENERATOR_NAMES[:], g),
				"%s's face %q is not a generator",
				m.name,
				g,
			)
		}
		_, sound :=
			reg.ids[.Sound][strings.concatenate({BASE_NAMESPACE, ":", m.sound}, context.temp_allocator)]
		testing.expectf(t, sound, "%s sounds like %q, which is no base sound set", m.name, m.sound)
		testing.expectf(t, m.light <= 15, "%s gives light %d", m.name, m.light)
		testing.expectf(
			t,
			m.layer != .Opaque || !m.cull_same,
			"%s is opaque and culls its own kind",
			m.name,
		)
	}
}

// A pack's block of a material is one line, and has the material's textures, sound and
// light; what the block says itself wins; a stair of it is one line too.
@(test)
test_a_block_of_a_material :: proc(t: ^testing.T) {
	reg, errs := build_with(
		pack_of(
			"testpack",
			[]File {
				{
					"data/blocks/a.json",
					`{"wall": {"material": "stone_bricks"},
					  "pane": {"material": "glass"},
					  "dim_lamp": {"material": "lamp", "light": 6},
					  "loud": {"material": "sandstone", "sound": "voxiverse:wood", "textures": {"top": "voxiverse:dirt"}},
					  "steps": {"shape": "voxiverse:stairs", "material": "cobblestone"}}`,
				},
			},
		),
	)
	testing.expect_value(t, errors_text(errs), "")
	if reg == nil {return}
	defer registry_destroy(reg)
	def :: proc(reg: ^Registry, id: string) -> (Block_Def, Block_Flags, u8) {
		b, _ := registry_block(reg, id)
		return reg.blocks.defs[b], reg.blocks.flags[b], reg.blocks.light[b]
	}
	texture :: proc(reg: ^Registry, id: string) -> u32 {return reg.ids[.Texture][id]}
	sound :: proc(reg: ^Registry, id: string) -> i32 {return i32(reg.ids[.Sound][id])}

	wall, wall_flags, _ := def(reg, "testpack:wall")
	bricks, _ := registry_block(reg, "stone_bricks")
	testing.expect_value(t, wall.faces, reg.blocks.defs[bricks].faces)
	testing.expect_value(t, wall.sound, sound(reg, "voxiverse:stone"))
	testing.expect_value(t, MATERIALS[wall.material].name, "stone_bricks")
	testing.expect(t, .Opaque in wall_flags)

	pane, pane_flags, _ := def(reg, "testpack:pane")
	testing.expect_value(t, pane.layer, Layer_Kind.Cutout)
	testing.expect(t, .Opaque not_in pane_flags && .Cull_Same in pane_flags)

	_, _, light := def(reg, "testpack:dim_lamp")
	testing.expect_value(t, light, 6)

	loud, _, _ := def(reg, "testpack:loud")
	testing.expect_value(t, loud.sound, sound(reg, "voxiverse:wood"))
	testing.expect_value(t, loud.faces[0], texture(reg, "voxiverse:sandstone_side"))
	testing.expect_value(t, loud.faces[1], texture(reg, "voxiverse:dirt"))
	testing.expect_value(t, loud.faces[2], texture(reg, "voxiverse:sandstone_top"))

	steps, _ := registry_block(reg, "testpack:steps")
	stone_steps, _ := registry_block(reg, "cobblestone_stairs")
	type_of :: proc(reg: ^Registry, b: Block) -> Type_Def {return(
			reg.blocks.types[reg.blocks.type_of[b]] \
		)}
	testing.expect_value(t, type_of(reg, steps).state_count, type_of(reg, stone_steps).state_count)
	testing.expect_value(t, type_of(reg, steps).place, Place_Rule.Stairs)
	testing.expect_value(t, reg.blocks.defs[steps].faces, reg.blocks.defs[stone_steps].faces)
}

// A material this client does not have is refused where it is named, with the nearest;
// a shape's block says only what a shape may.
@(test)
test_an_unknown_material_is_refused :: proc(t: ^testing.T) {
	_, errs := build_with(
		pack_of(
			"testpack",
			[]File{{"data/blocks/a.json", `{"wall": {"material": "stone_brick"}}`}},
		),
	)
	testing.expect_value(
		t,
		errors_text(errs),
		`testpack/data/blocks/a.json:1:23: "stone_brick" is not a material this game has; did you mean "stone_bricks"? (the materials are the client's: docs/packs.md, "Materials")`,
	)
	_, errs = build_with(
		pack_of(
			"testpack",
			[]File{{"data/shapes/a.json", `{"low": {"boxes": [], "block": {"textures": {}}}}`}},
		),
	)
	testing.expect(
		t,
		strings.contains(errors_text(errs), `"textures" is not what a shape says of its blocks`),
		errors_text(errs),
	)
}

PACKS_DOC :: #directory + "/../../docs/packs.md"
MATERIALS_BEGIN :: "<!-- materials: written from common/game/materials.odin (materials_doc) -->\n"
MATERIALS_END :: "<!-- end of materials -->"

// docs/packs.md lists the materials there are (materials_doc, between its markers).
@(test)
test_the_doc_lists_the_materials :: proc(t: ^testing.T) {
	data, err := os.read_entire_file(PACKS_DOC, context.temp_allocator)
	testing.expectf(t, err == nil, "cannot read %s: %v", PACKS_DOC, err)
	text := string(data)
	begin := strings.index(text, MATERIALS_BEGIN)
	end := strings.index(text, MATERIALS_END)
	testing.expectf(
		t,
		begin >= 0 && end > begin,
		"docs/packs.md has no materials list between its markers",
	)
	if begin < 0 || end <= begin {return}
	listed := text[begin + len(MATERIALS_BEGIN):end]
	testing.expectf(
		t,
		listed == materials_doc(),
		"docs/packs.md's materials are stale; between its markers put:\n%s",
		materials_doc(),
	)
}
