package sheet

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "client:font"
import "client:mesh"
import "client:texture"
import "common:game"
import "server:packs"

// Draws the block textures where a person (or an agent) can look at them:
// build/sheets/materials.png, every material (game.MATERIALS) by family,
// each face tiled 3 x 3 at 4x and named by its material;
// build/sheets/<pack>.png for the base pack and each game's pack; and
// all.png, the lot one under another. A pack's sheet has two parts:
//
//   - the pack's own textures, each large (8x, nearest neighbour) with its
//     name, grouped by family (texture.Family; a pack's PNGs are "images");
//   - every texture its blocks show, as in the world: tiled 3 x 3 at 4x, so
//     seams and repetition show, named with the blocks that use it.
//
//	build sheet

FONT_DATA :: #load("../../assets/fonts/jetbrains_mono_regular.ttf")

OUT_DIR :: "build/sheets"
PAGE_WIDTH :: 1520
MARGIN :: 24
TITLE_SIZE :: 28
HEADING_SIZE :: 20
LABEL_SIZE :: 15

// Grid: a part of a sheet: each texture scale pixels a texel, tiles x tiles
// times, in cells with room for its labels.
Grid :: struct {
	scale, tiles: int,
	cell_width:   int,
	label_lines:  int,
}
OWN :: Grid {
	scale       = 8,
	tiles       = 1,
	cell_width  = 184,
	label_lines = 1,
}
WORLD :: Grid {
	scale       = 4,
	tiles       = 3,
	cell_width  = 245,
	label_lines = 3, // its name, and two of the blocks that show it
}

// Entry: a texture on a sheet.
Entry :: struct {
	texture: int, // its index in Registry.textures
	family:  int, // what it is grouped by: texture.Family (len(Family) for a pack's image), or game.Material_Family
	group:   string, // the family's name
	label:   string,
	note:    string, // the second line: the blocks that use it
	order:   int, // within its family (else by texture)
}

main :: proc() {
	context.allocator = context.temp_allocator // a short run that draws and exits
	pen: Pen
	ok: bool
	if pen.font, ok = font.load(FONT_DATA); !ok {
		fmt.eprintln("sheet: cannot read the font")
		os.exit(1)
	}
	if err := os.make_directory_all(OUT_DIR); err != nil && err != .Exist {
		fmt.eprintfln("sheet: cannot make %s: %v", OUT_DIR, err)
		os.exit(1)
	}
	base := game.base_pack_source()
	all := Canvas {
		width = PAGE_WIDTH,
	}
	add :: proc(all: ^Canvas, c: ^Canvas, name: string) {
		write_png(c, fmt.tprintf("%s.png", name))
		at := all.height
		grow(all, at + c.height)
		copy(all.pixels[at * PAGE_WIDTH:], c.pixels[:])
		fill(all, 0, all.height - 2, PAGE_WIDTH, 2, DIM) // a rule between packs
	}
	sheet :: proc(all: ^Canvas, reg: ^game.Registry, ns: string, pen: ^Pen) {
		c := sheet_draw(reg, ns, pen)
		add(all, &c, ns)
	}
	reg, errs := game.registry_build({base})
	if reg == nil {fail(errs)}
	materials := materials_draw(reg, &pen)
	add(&all, &materials, "materials")
	sheet(&all, reg, game.BASE_NAMESPACE, &pen)
	for dir in game_pack_dirs() {
		src, read_errs := packs.pack_read_dir(dir)
		if len(read_errs) > 0 {fail(read_errs)}
		game_reg, build_errs := game.registry_build({base, src})
		if game_reg == nil {fail(build_errs)}
		sheet(&all, game_reg, src.namespace, &pen)
	}
	write_png(&all, "all.png")
}

fail :: proc(errs: []game.Pack_Error) -> ! {
	for e in errs {fmt.eprintln(game.pack_error_text(e))}
	os.exit(1)
}

// game_pack_dirs: games/<game>/pack for every game that has one, in name order.
game_pack_dirs :: proc() -> []string {
	entries, err := os.read_all_directory_by_path(packs.GAMES_FOLDER, context.temp_allocator)
	if err != nil {return nil}
	dirs := make([dynamic]string)
	for e in entries {
		dir, _ := filepath.join({packs.GAMES_FOLDER, e.name, packs.GAME_PACK_FOLDER})
		if os.is_dir(dir) {append(&dirs, dir)}
	}
	slice.sort(dirs[:])
	return dirs[:]
}

write_png :: proc(c: ^Canvas, name: string) {
	path, _ := filepath.join({OUT_DIR, name})
	data := png_compressed(c.width, c.height, slice.to_bytes(c.pixels[:]))
	if err := os.write_entire_file(path, data); err != nil {
		fmt.eprintfln("sheet: cannot write %s: %v", path, err)
		os.exit(1)
	}
	fmt.printfln("sheet %s (%dx%d)", path, c.width, c.height)
}

// sheet_draw draws the sheet of the pack ns in reg.
sheet_draw :: proc(reg: ^game.Registry, ns: string, pen: ^Pen) -> Canvas {
	c := Canvas {
		width = PAGE_WIDTH,
	}
	prefix := strings.concatenate({ns, ":"})
	own := make([dynamic]Entry)
	for tex, i in reg.textures {
		if !strings.has_prefix(tex.id, prefix) {continue}
		append(&own, entry(reg, i, ns, ""))
	}
	// The textures the pack's blocks show, with the blocks (by name, once each).
	users := make(map[int][dynamic]string)
	for state in 0 ..< reg.blocks.count {
		def := reg.blocks.defs[state]
		if def.render == .None || !strings.has_prefix(def.id, prefix) {continue}
		for f in def.faces {
			list := users[int(f)] or_else make([dynamic]string)
			name := strings.trim_prefix(def.id, prefix)
			if !slice.contains(list[:], name) {append(&list, name)}
			users[int(f)] = list
		}
	}
	world := make([dynamic]Entry)
	for i, list in users {append(&world, entry(reg, i, ns, strings.join(list[:], ", ")))}

	y := MARGIN
	draw_text(&c, pen, MARGIN, y, ns, TITLE_SIZE, ACCENT)
	summary := fmt.tprintf(
		"%d textures of its own; its blocks show %d (build/sheets/%s.png)",
		len(own),
		len(world),
		ns,
	)
	draw_text(
		&c,
		pen,
		MARGIN + text_width(pen, ns, TITLE_SIZE) + 20,
		y + 8,
		summary,
		LABEL_SIZE,
		DIM,
	)
	y += line_height(pen, TITLE_SIZE) + 16
	y = part_draw(&c, pen, y, reg, "Its textures (8x)", own[:], OWN)
	if len(own) == 0 {
		draw_text(
			&c,
			pen,
			MARGIN,
			y,
			"none of its own: its blocks use the base pack's",
			LABEL_SIZE,
			DIM,
		)
		y += line_height(pen, LABEL_SIZE) + 24
	}
	y = part_draw(
		&c,
		pen,
		y,
		reg,
		"As in the world (tiled 3 x 3, 4x), with the blocks that show it",
		world[:],
		WORLD,
	)
	grow(&c, y + MARGIN)
	return c
}

// materials_draw draws the materials' sheet: every material by family, each face of it
// tiled as in the world and named by the material.
materials_draw :: proc(reg: ^game.Registry, pen: ^Pen) -> Canvas {
	c := Canvas {
		width = PAGE_WIDTH,
	}
	y := MARGIN
	draw_text(&c, pen, MARGIN, y, "materials", TITLE_SIZE, ACCENT)
	counts := make([dynamic]string)
	for family in game.Material_Family {
		n := 0
		for m in game.MATERIALS {if m.family == family {n += 1}}
		append(&counts, fmt.tprintf("%s %d", game.MATERIAL_FAMILY_NAMES[family], n))
	}
	summary := fmt.tprintf("%d materials: %s", len(game.MATERIALS), strings.join(counts[:], ", "))
	draw_text(
		&c,
		pen,
		MARGIN + text_width(pen, "materials", TITLE_SIZE) + 20,
		y + 8,
		fit(pen, summary, LABEL_SIZE, PAGE_WIDTH - 2 * MARGIN - 160),
		LABEL_SIZE,
		DIM,
	)
	y += line_height(pen, TITLE_SIZE) + 16
	y = part_draw(
		&c,
		pen,
		y,
		reg,
		"By family (tiled 3 x 3, 4x), each named by its material and the face where they differ",
		material_entries(reg),
		WORLD,
	)
	grow(&c, y + MARGIN)
	return c
}

// entry: texture i of reg as a sheet shows it.
entry :: proc(reg: ^game.Registry, i: int, ns, note: string) -> Entry {
	tex := reg.textures[i]
	family, group := len(texture.Family), "images"
	if int(tex.layer) < len(game.TEXTURE_GENERATOR_NAMES) {
		f := texture.family(texture.Generator(tex.layer))
		family, group = int(f), texture.FAMILY_NAMES[f]
	}
	label := strings.trim_prefix(tex.id, strings.concatenate({ns, ":"}))
	if game.BASE_NAMESPACE != ns && strings.has_prefix(tex.id, game.BASE_NAMESPACE) {
		label = strings.trim_prefix(tex.id, strings.concatenate({game.BASE_NAMESPACE, ":"}))
	}
	return {texture = i, family = family, group = group, label = label, note = note, order = i}
}

// material_entries: every material's faces, by material family: its side, then its top
// and its bottom where they differ, each named by the material (and the face).
material_entries :: proc(reg: ^game.Registry) -> []Entry {
	FACE_NAMES := [3]string{"side", "top", "bottom"}
	out := make([dynamic]Entry)
	for m, mi in game.MATERIALS {
		faces := game.material_faces(m)
		for generator, k in faces {
			if k > 0 && generator == faces[k - 1] {continue}
			if k == 2 && generator == faces[0] {continue}
			note := FACE_NAMES[k]
			if k == 0 && faces[1] == faces[0] && faces[2] == faces[0] {note = ""}
			append(
				&out,
				Entry {
					texture = material_texture(reg, generator),
					family = int(m.family),
					group = game.MATERIAL_FAMILY_NAMES[m.family],
					label = m.name,
					note = note,
					order = mi * 3 + k,
				},
			)
		}
	}
	return out[:]
}

// material_texture: the base pack's texture of a material's face's generator.
material_texture :: proc(reg: ^game.Registry, generator: string) -> int {
	return int(reg.ids[.Texture][strings.concatenate({game.BASE_NAMESPACE, ":", generator})])
}

// part_draw draws a heading and its entries, by family, each family's from
// a new row under its name; it returns the y below them.
part_draw :: proc(
	c: ^Canvas,
	pen: ^Pen,
	y: int,
	reg: ^game.Registry,
	heading: string,
	entries: []Entry,
	grid: Grid,
) -> int {
	y := y
	draw_text(c, pen, MARGIN, y, heading, HEADING_SIZE, TEXT)
	y += line_height(pen, HEADING_SIZE) + 12
	slice.sort_by(entries, proc(a, b: Entry) -> bool {
		if a.family != b.family {return a.family < b.family}
		return a.order < b.order
	})
	side := texture.SIZE * grid.scale * grid.tiles
	label := line_height(pen, LABEL_SIZE)
	cell_height := side + 6 + grid.label_lines * label + 18
	columns := (PAGE_WIDTH - 2 * MARGIN) / grid.cell_width
	pixels: [texture.SIZE * texture.SIZE]texture.Rgba
	for start := 0; start < len(entries); {
		family := entries[start].family
		end := start
		for end < len(entries) && entries[end].family == family {end += 1}
		draw_text(c, pen, MARGIN, y, entries[start].group, LABEL_SIZE, ACCENT)
		y += label + 6
		for e, k in entries[start:end] {
			x := MARGIN + (k % columns) * grid.cell_width
			top := y + (k / columns) * cell_height
			mesh.texture_layer_pixels(reg, reg.textures[e.texture].layer, pixels[:])
			draw_texture(c, x, top, pixels[:], grid.scale, grid.tiles)
			width := grid.cell_width - 12
			draw_text(
				c,
				pen,
				x,
				top + side + 6,
				fit(pen, e.label, LABEL_SIZE, width),
				LABEL_SIZE,
				TEXT,
			)
			for line, n in wrap(pen, e.note, LABEL_SIZE, width, grid.label_lines - 1) {
				draw_text(c, pen, x, top + side + 6 + (n + 1) * label, line, LABEL_SIZE, DIM)
			}
		}
		y += ((end - start + columns - 1) / columns) * cell_height + 8
		start = end
	}
	return y + 12
}
