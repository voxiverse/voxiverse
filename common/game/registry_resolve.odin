package game

import "core:fmt"
import "core:slice"
import "core:strings"

// Resolving: the merged definitions become the registry's tables. Blocks are
// numbered first (the builtins by their member's number, then the rest in
// load order), then items, then everything that refers to them.

@(private)
field_of :: proc(m: ^Merged_Def, name: string) -> ^Def_Field {
	for &f in m.fields {if f.name == name {return &f}}
	return nil
}

@(private)
rd_bool :: proc(b: ^Reg_Build, m: ^Merged_Def, name: string, def: bool) -> bool {
	f := field_of(m, name)
	if f == nil {return def}
	if f.value.kind != .Bool {
		fail_field(b, f, f.value, fmt.aprintf("%s is true or false", name))
		return def
	}
	return f.value.b
}

@(private)
rd_int :: proc(b: ^Reg_Build, m: ^Merged_Def, name: string, def, lo, hi: int) -> int {
	f := field_of(m, name)
	if f == nil {return def}
	if f.value.kind != .Int {
		fail_field(b, f, f.value, fmt.aprintf("%s is a whole number %d..%d", name, lo, hi))
		return def
	}
	if f.value.i < i64(lo) || f.value.i > i64(hi) {
		fail_field(b, f, f.value, fmt.aprintf("%s is %d..%d, got %d", name, lo, hi, f.value.i))
		return def
	}
	return int(f.value.i)
}

// rd_choice: the index of the string field's value among names (def when absent).
@(private)
rd_choice :: proc(b: ^Reg_Build, m: ^Merged_Def, name: string, names: []string, def: int) -> int {
	f := field_of(m, name)
	if f == nil {return def}
	return choice_of(b, f, f.value, name, names, def)
}

@(private)
choice_of :: proc(
	b: ^Reg_Build,
	f: ^Def_Field,
	v: Json_Value,
	name: string,
	names: []string,
	def: int,
) -> int {
	if v.kind == .String {
		for n, i in names {if n == v.s {return i}}
	}
	got := v.s if v.kind == .String else "a non-string"
	fail_field(
		b,
		f,
		v,
		fmt.aprintf(
			"%s is one of %s; got \"%s\"%s",
			name,
			join_quoted(names),
			got,
			suggestion(got, names, false),
		),
	)
	return def
}

// ref_index: the index in defs of the id text names, or an error.
@(private)
ref_index :: proc(
	b: ^Reg_Build,
	kind: Content_Kind,
	text: string,
	f: ^Def_Field,
	v: Json_Value,
) -> (
	int,
	bool,
) {
	id, ok := id_parse(text)
	if ok {
		full := strings.concatenate({id.namespace, ":", id.name})
		if at, found := b.index[kind][full]; found {return at, true}
	}
	fail_field(
		b,
		f,
		v,
		fmt.aprintf(
			"\"%s\" is not %s%s",
			text,
			KIND_NAMES[kind],
			suggestion(text, index_keys(b.index[kind]), false),
		),
	)
	return 0, false
}

@(private)
MODIFIER_STATS := []string{"speed", "jump", "air_jumps", "max_health"}
@(private)
EQUIP_NAMES := []string{"head", "chest", "legs", "feet", "offhand"}
@(private)
TOOL_NAMES := []string{"launcher", "hoe"}
@(private)
ARMOR_NAMES := []string{"cap", "tunic", "trousers", "boots"}
@(private)
RENDER_NAMES := []string{"cube", "cross", "none"}
@(private)
LAYER_NAMES := []string{"opaque", "cutout", "translucent"}

@(private)
resolve_all :: proc(b: ^Reg_Build, reg: ^Registry) {
	// --- Textures and sound sets. ---
	if len(b.defs[.Texture]) > MAX_TEXTURES {
		fail(
			b,
			-1,
			"",
			0,
			0,
			fmt.aprintf("%d textures; the limit is %d", len(b.defs[.Texture]), MAX_TEXTURES),
		)
	}
	if len(b.defs[.Sound]) > MAX_SOUNDS {
		fail(
			b,
			-1,
			"",
			0,
			0,
			fmt.aprintf("%d sound sets; the limit is %d", len(b.defs[.Sound]), MAX_SOUNDS),
		)
	}
	reg.textures = make([]Texture_Def, len(b.defs[.Texture]))
	for &m, i in b.defs[.Texture] {
		reg.textures[i] = {m.id, read_generator(b, &m, TEXTURE_GENERATOR_NAMES[:])}
	}
	reg.sounds = make([]Sound_Def, len(b.defs[.Sound]))
	for &m, i in b.defs[.Sound] {
		reg.sounds[i] = {m.id, read_generator(b, &m, SOUND_GENERATOR_NAMES[:])}
	}

	// --- Block numbers. ---
	blocks := b.defs[.Block]
	if len(blocks) > MAX_BLOCK_STATES {
		fail(
			b,
			-1,
			"",
			0,
			0,
			fmt.aprintf("%d blocks; the limit is %d", len(blocks), MAX_BLOCK_STATES),
		)
		return
	}
	number := make([]int, len(blocks)) // defs index -> block number
	slice.fill(number, -1)
	order := make([]int, len(blocks)) // block number -> defs index
	for builtin in Block {
		id := BUILTIN_BLOCK_IDS[builtin]
		at, found := b.index[.Block][id]
		if !found {
			fail(
				b,
				-1,
				"",
				0,
				0,
				fmt.aprintf(
					"%s is not defined by any pack; the engine needs it (common/game/block.odin)",
					id,
				),
			)
			continue
		}
		number[at] = int(builtin)
		order[int(builtin)] = at
	}
	if len(b.errs) > 0 {return}
	next := len(Block)
	for i in 0 ..< len(blocks) {
		if number[i] < 0 {
			number[i] = next
			order[next] = i
			next += 1
		}
	}
	for text, at in b.index[.Block] {reg.ids[.Block][text] = u32(number[at])}

	// --- Items: numbers. ---
	items := b.defs[.Item]
	item_numbers := make([]Item, len(items))
	builtin_item := make([]bool, len(items))
	reg.ids[.Item] = {}
	for i in 0 ..< len(items) {
		if items[i].auto {item_numbers[i] = Item(number[items[i].aux] + 1)}
	}
	for t in Tool {
		at, found := b.index[.Item][BUILTIN_TOOL_IDS[t]]
		if !found {
			fail(
				b,
				-1,
				"",
				0,
				0,
				fmt.aprintf(
					"%s is not defined by any pack; the engine needs it (common/game/items.odin)",
					BUILTIN_TOOL_IDS[t],
				),
			)
			continue
		}
		item_numbers[at] = item_of_tool(t)
		builtin_item[at] = true
	}
	for m in Material {
		at, found := b.index[.Item][BUILTIN_MATERIAL_IDS[m]]
		if !found {
			fail(
				b,
				-1,
				"",
				0,
				0,
				fmt.aprintf(
					"%s is not defined by any pack; the engine needs it (common/game/items.odin)",
					BUILTIN_MATERIAL_IDS[m],
				),
			)
			continue
		}
		item_numbers[at] = item_of_material(m)
		builtin_item[at] = true
	}
	for a in Armor {
		at, found := b.index[.Item][BUILTIN_ARMOR_IDS[a]]
		if !found {
			fail(
				b,
				-1,
				"",
				0,
				0,
				fmt.aprintf(
					"%s is not defined by any pack; the engine needs it (common/game/items.odin)",
					BUILTIN_ARMOR_IDS[a],
				),
			)
			continue
		}
		item_numbers[at] = item_of_armor(a)
		builtin_item[at] = true
	}
	if len(b.errs) > 0 {return}
	pack_count := 0
	for i in 0 ..< len(items) {
		if !items[i].auto && !builtin_item[i] {
			item_numbers[i] = PACK_ITEMS + Item(pack_count)
			pack_count += 1
		}
	}
	if pack_count > MAX_PACK_ITEMS {
		fail(
			b,
			-1,
			"",
			0,
			0,
			fmt.aprintf("%d items packs add; the limit is %d", pack_count, MAX_PACK_ITEMS),
		)
		return
	}
	for text, at in b.index[.Item] {reg.ids[.Item][text] = u32(item_numbers[at])}

	// --- Blocks. ---
	t := &reg.blocks
	t.count = len(blocks)
	t.flags = make([]Block_Flags, t.count)
	t.light = make([]u8, t.count)
	t.defs = make([]Block_Def, t.count)
	for n in 0 ..< t.count {
		m := &blocks[order[n]]
		read_block(b, reg, m, n, order, number)
	}

	// --- Items: definitions. ---
	reg.items.blocks = make([]Item_Info, t.count)
	reg.items.pack = make([]Item_Info, pack_count)
	for &m, i in items {
		info := read_item(b, &m, number, item_numbers)
		n := item_numbers[i]
		switch {
		case n >= ARMOR_ITEMS:
			reg.items.armor[Armor(int(n - ARMOR_ITEMS))] = info
		case n >= MATERIAL_ITEMS:
			reg.items.materials[Material(int(n - MATERIAL_ITEMS))] = info
		case n >= TOOL_ITEMS:
			reg.items.tools[Tool(int(n - TOOL_ITEMS))] = info
		case n >= PACK_ITEMS:
			reg.items.pack[int(n - PACK_ITEMS)] = info
		case:
			reg.items.blocks[int(n) - 1] = info
		}
	}

	// --- Block drops. ---
	for n in 0 ..< t.count {
		m := &blocks[order[n]]
		f := field_of(m, "drop")
		if f == nil {
			t.defs[n].drop = Item(n + 1) if .Placeable in t.flags[n] else NO_ITEM
			continue
		}
		if f.value.kind != .String {
			fail_field(b, f, f.value, "drop is an item id or \"none\"")
			continue
		}
		if f.value.s == "none" {continue}
		if at, ok := ref_index(b, .Item, f.value.s, f, f.value);
		   ok {t.defs[n].drop = item_numbers[at]}
	}

	// --- Tags. ---
	if len(b.defs[.Block_Tag]) > MAX_TAGS || len(b.defs[.Item_Tag]) > MAX_TAGS {
		fail(b, -1, "", 0, 0, fmt.aprintf("more than %d tags of one kind", MAX_TAGS))
		return
	}
	reg.block_tags = resolve_tags(b, .Block_Tag, .Block, number_of_blocks(number), nil)
	reg.item_tags = resolve_tags(b, .Item_Tag, .Item, nil, item_numbers)
	for text, at in b.index[.Block_Tag] {reg.ids[.Block_Tag][text] = u32(at)}
	for text, at in b.index[.Item_Tag] {reg.ids[.Item_Tag][text] = u32(at)}
	for text, at in b.index[.Texture] {reg.ids[.Texture][text] = u32(at)}
	for text, at in b.index[.Sound] {reg.ids[.Sound][text] = u32(at)}
	for text, at in b.index[.Recipe] {reg.ids[.Recipe][text] = u32(at)}
	for text, at in b.index[.Structure] {reg.ids[.Structure][text] = u32(at)}
	for ti, ai in reg.block_tags {
		for member in ti.members {
			tags := &reg.blocks.defs[member].tags
			tags^ = append_tag(tags^, u16(ai))
		}
	}
	// support references the tags: a tag index is the defs index.
	for n in 0 ..< t.count {
		m := &blocks[order[n]]
		f := field_of(m, "support")
		t.defs[n].support = NO_TAG
		if f == nil {continue}
		if f.value.kind != .Object {
			fail_field(b, f, f.value, "support is an object: {\"below\": \"<block tag>\"}")
			continue
		}
		for sm in f.value.members {
			if sm.key != "below" {
				fail_field(
					b,
					f,
					sm.value,
					fmt.aprintf(
						"\"%s\" is not a support field%s",
						sm.key,
						suggestion(sm.key, []string{"below"}),
					),
				)
				continue
			}
			if sm.value.kind != .String {
				fail_field(b, f, sm.value, "below is a block tag id")
				continue
			}
			if at, ok := ref_index(
				b,
				.Block_Tag,
				strings.trim_prefix(sm.value.s, "#"),
				f,
				sm.value,
			); ok {
				t.defs[n].support = i32(at)
			}
		}
	}

	// --- Recipes. ---
	if len(b.defs[.Recipe]) > MAX_RECIPES {
		fail(
			b,
			-1,
			"",
			0,
			0,
			fmt.aprintf("%d recipes; the limit is %d", len(b.defs[.Recipe]), MAX_RECIPES),
		)
		return
	}
	reg.recipes = make([]Recipe_Def, len(b.defs[.Recipe]))
	for &m, i in b.defs[.Recipe] {reg.recipes[i] = read_recipe(b, &m, item_numbers)}

	// --- Structures. ---
	if len(b.defs[.Structure]) > MAX_STRUCTURES {
		fail(
			b,
			-1,
			"",
			0,
			0,
			fmt.aprintf("%d structures; the limit is %d", len(b.defs[.Structure]), MAX_STRUCTURES),
		)
		return
	}
	reg.structures = make([]Structure_Def, len(b.defs[.Structure]))
	for &m, i in b.defs[.Structure] {
		tmpl, ok := template_decode_with(m.data, structure_resolver, reg)
		if !ok {
			fail(
				b,
				m.pack,
				m.file,
				0,
				0,
				"cannot be read: it is damaged, or names a block no pack defines",
			)
			continue
		}
		h := hasher_make()
		hasher_mix(&h, u64(tmpl.size.x))
		hasher_mix(&h, u64(tmpl.size.y))
		hasher_mix(&h, u64(tmpl.size.z))
		for c in tmpl.cells {hasher_mix(&h, u64(c))}
		reg.structures[i] = {m.id, tmpl, hasher_finish(h)}
	}
	if len(b.errs) > 0 {return}

	reg.packs = make([]Pack_Info, len(b.packs))
	copy(reg.packs, b.packs[:])
	reg.hash = registry_hash_of(reg)
}

@(private)
structure_resolver :: proc(user: rawptr, name: string) -> (u16, bool) {
	reg := cast(^Registry)user
	n, ok := registry_block(reg, name)
	return u16(n), ok
}

@(private)
number_of_blocks :: proc(number: []int) -> []Item {
	out := make([]Item, len(number))
	for n, i in number {out[i] = Item(n)}
	return out
}

@(private)
append_tag :: proc(tags: []u16, tag: u16) -> []u16 {
	out := make([]u16, len(tags) + 1)
	copy(out, tags)
	out[len(tags)] = tag
	return out
}

@(private)
read_generator :: proc(b: ^Reg_Build, m: ^Merged_Def, names: []string) -> string {
	f := field_of(m, "generator")
	if f == nil {
		fail(
			b,
			m.pack,
			m.file,
			m.line,
			m.column,
			"\"generator\" is missing; name the generator that draws it",
		)
		return ""
	}
	i := choice_of(b, f, f.value, "generator", names, 0)
	return names[i]
}

@(private)
read_block :: proc(b: ^Reg_Build, reg: ^Registry, m: ^Merged_Def, n: int, order, number: []int) {
	t := &reg.blocks
	flags: Block_Flags
	if rd_bool(b, m, "collides", true) {flags += {.Collides}}
	if rd_bool(b, m, "targetable", true) {flags += {.Targetable}}
	if rd_bool(b, m, "breakable", true) {flags += {.Breakable}}
	if rd_bool(b, m, "placeable", true) {flags += {.Placeable}}
	if rd_bool(b, m, "replaceable", false) {flags += {.Replaceable}}
	if rd_bool(b, m, "shades", false) {flags += {.Shades}}
	if rd_bool(b, m, "cull_same", false) {flags += {.Cull_Same}}
	if rd_bool(b, m, "liquid", false) {flags += {.Liquid}}
	render := Render_Kind(rd_choice(b, m, "render", RENDER_NAMES, 0))
	layer := Layer_Kind(rd_choice(b, m, "layer", LAYER_NAMES, 0))
	if rd_bool(b, m, "opaque", true) {
		if render != .Cube || layer != .Opaque {
			f := field_of(m, "opaque")
			if f != nil {
				fail_field(
					b,
					f,
					f.value,
					"opaque needs render \"cube\" and layer \"opaque\"; set opaque to false, or change them",
				)
			} else {
				fail(
					b,
					m.pack,
					m.file,
					m.line,
					m.column,
					"a block is opaque unless it says otherwise, which needs render \"cube\" and layer \"opaque\"; set \"opaque\": false",
				)
			}
		}
		flags += {.Opaque}
	}
	t.flags[n] = flags
	t.light[n] = u8(rd_int(b, m, "light", 0, 0, 15))
	d := &t.defs[n]
	d.id = m.id
	d.render = render
	d.layer = layer
	d.sound = NO_SOUND
	d.support = NO_TAG
	if f := field_of(m, "sound"); f != nil {
		if f.value.kind != .String {
			fail_field(b, f, f.value, "sound is a sound set id")
		} else if at, ok := ref_index(b, .Sound, f.value.s, f, f.value); ok {
			d.sound = i32(at)
		}
	}
	// Faces: side, top, bottom.
	if render == .None && field_of(m, "textures") == nil {return}
	f := field_of(m, "textures")
	if f == nil {
		at, found := b.index[.Texture][m.id]
		if !found {
			fail(
				b,
				m.pack,
				m.file,
				m.line,
				m.column,
				fmt.aprintf(
					"no texture \"%s\" for this block; add \"textures\", or a texture with that id",
					m.id,
				),
			)
			return
		}
		d.faces = {u32(at), u32(at), u32(at)}
		return
	}
	if f.value.kind != .Object {
		fail_field(
			b,
			f,
			f.value,
			"textures is an object: {\"all\": \"<texture>\"} or {\"side\": ..., \"top\": ..., \"bottom\": ...}",
		)
		return
	}
	errors_before := len(b.errs)
	got: [4]int = {-1, -1, -1, -1} // all, side, top, bottom
	keys := []string{"all", "side", "top", "bottom"}
	for tm in f.value.members {
		k := -1
		for name, i in keys {if name == tm.key {k = i}}
		if k < 0 {
			fail_field(
				b,
				f,
				tm.value,
				fmt.aprintf("\"%s\" is not a face%s", tm.key, suggestion(tm.key, keys)),
			)
			continue
		}
		if tm.value.kind != .String {
			fail_field(b, f, tm.value, fmt.aprintf("%s is a texture id", tm.key))
			continue
		}
		if at, ok := ref_index(b, .Texture, tm.value.s, f, tm.value); ok {got[k] = at}
	}
	if got[0] >= 0 {
		if got[1] >= 0 || got[2] >= 0 || got[3] >= 0 {
			fail_field(
				b,
				f,
				f.value,
				"\"all\" cannot be combined with side, top or bottom; use one or the others",
			)
			return
		}
		d.faces = {u32(got[0]), u32(got[0]), u32(got[0])}
		return
	}
	if got[1] < 0 {
		if len(b.errs) > errors_before {return}
		fail_field(b, f, f.value, "textures needs \"all\", or at least \"side\"")
		return
	}
	d.faces = {
		u32(got[1]),
		u32(got[2] if got[2] >= 0 else got[1]),
		u32(got[3] if got[3] >= 0 else got[1]),
	}
}

@(private)
read_item :: proc(
	b: ^Reg_Build,
	m: ^Merged_Def,
	number: []int,
	item_numbers: []Item,
) -> Item_Info {
	info: Item_Info
	info.name = m.id
	info.stack = 64
	if m.auto {info.block = Block(number[m.aux])}
	info.stack = rd_int(b, m, "stack", 64, 1, 999)
	if f := field_of(m, "places"); f != nil {
		if f.value.kind != .String {
			fail_field(b, f, f.value, "places is a block id")
		} else if at, ok := ref_index(b, .Block, f.value.s, f, f.value); ok {
			info.block = Block(number[at])
		}
	}
	if f := field_of(m, "tool"); f != nil {
		info.tool = Tool(choice_of(b, f, f.value, "tool", TOOL_NAMES, 0))
	}
	if f := field_of(m, "armor"); f != nil {
		info.armor = Armor(choice_of(b, f, f.value, "armor", ARMOR_NAMES, 0))
	}
	if f := field_of(m, "equip"); f != nil {
		info.equip = Equip_Slot(choice_of(b, f, f.value, "equip", EQUIP_NAMES, 0))
	}
	if f := field_of(m, "modifiers"); f != nil {
		if f.value.kind != .Array {
			fail_field(b, f, f.value, "modifiers is a list of {\"stat\": ..., \"amount\": ...}")
		} else if len(f.value.items) > 2 {
			fail_field(
				b,
				f,
				f.value,
				fmt.aprintf("an item has at most 2 modifiers, got %d", len(f.value.items)),
			)
		} else {
			for mod, i in f.value.items {
				if mod.kind != .Object {
					fail_field(b, f, mod, "a modifier is {\"stat\": ..., \"amount\": ...}")
					continue
				}
				for mm in mod.members {
					switch mm.key {
					case "stat":
						info.modifiers[i].kind = Modifier_Kind(
							choice_of(b, f, mm.value, "stat", MODIFIER_STATS, 0),
						)
					case "amount":
						if mm.value.kind != .Int && mm.value.kind != .Float {
							fail_field(b, f, mm.value, "amount is a number")
						} else {
							info.modifiers[i].amount = f32(mm.value.f)
						}
					case:
						fail_field(
							b,
							f,
							mm.value,
							fmt.aprintf(
								"\"%s\" is not a modifier field%s",
								mm.key,
								suggestion(mm.key, []string{"stat", "amount"}),
							),
						)
					}
				}
			}
		}
	}
	return info
}


// resolve_tags: each tag's members, flattened through #tags, as numbers.
@(private)
resolve_tags :: proc(
	b: ^Reg_Build,
	kind: Content_Kind,
	of: Content_Kind,
	block_numbers: []Item,
	item_numbers: []Item,
) -> []Tag_Def {
	tags := b.defs[kind]
	out := make([]Tag_Def, len(tags))
	state := make([]u8, len(tags)) // 0 new, 1 open, 2 done
	flat := make([][dynamic]u32, len(tags))
	for i in 0 ..< len(tags) {out[i].id = tags[i].id}
	visit :: proc(
		b: ^Reg_Build,
		kind, of: Content_Kind,
		i: int,
		state: []u8,
		flat: [][dynamic]u32,
		block_numbers, item_numbers: []Item,
		chain: ^[dynamic]string,
	) {
		if state[i] == 2 {return}
		tags := b.defs[kind]
		state[i] = 1
		append(chain, tags[i].id)
		if len(tags[i].values) > MAX_TAG_VALUES {
			fail(
				b,
				tags[i].pack,
				tags[i].file,
				tags[i].line,
				tags[i].column,
				fmt.aprintf(
					"tag has %d values; the limit is %d",
					len(tags[i].values),
					MAX_TAG_VALUES,
				),
			)
		}
		for v in tags[i].values {
			f := Def_Field {
				pack = v.pack,
				file = v.file,
			}
			jv := Json_Value {
				line   = v.line,
				column = v.column,
			}
			if strings.has_prefix(v.text, "#") {
				at, ok := ref_index(b, kind, v.text[1:], &f, jv)
				if !ok {continue}
				if state[at] == 1 {
					fail(
						b,
						v.pack,
						v.file,
						v.line,
						v.column,
						fmt.aprintf(
							"tag \"%s\" includes itself through \"%s\"; remove the loop",
							tags[i].id,
							tags[at].id,
						),
					)
					continue
				}
				visit(b, kind, of, at, state, flat, block_numbers, item_numbers, chain)
				for x in flat[at] {if !slice.contains(flat[i][:], x) {append(&flat[i], x)}}
				continue
			}
			at, ok := ref_index(b, of, v.text, &f, jv)
			if !ok {continue}
			n := u32(block_numbers[at]) if of == .Block else u32(item_numbers[at])
			if !slice.contains(flat[i][:], n) {append(&flat[i], n)}
		}
		pop(chain)
		state[i] = 2
	}
	chain := make([dynamic]string)
	for i in 0 ..< len(tags) {
		visit(b, kind, of, i, state, flat, block_numbers, item_numbers, &chain)
		slice.sort(flat[i][:])
		out[i].members = flat[i][:]
	}
	return out
}

@(private)
read_recipe :: proc(b: ^Reg_Build, m: ^Merged_Def, item_numbers: []Item) -> Recipe_Def {
	r: Recipe_Def
	r.id = m.id
	typ := field_of(m, "type")
	if typ == nil {
		fail(
			b,
			m.pack,
			m.file,
			m.line,
			m.column,
			"\"type\" is missing; it is \"shapeless\" or \"shaped\"",
		)
		return r
	}
	kind := choice_of(b, typ, typ.value, "type", []string{"shapeless", "shaped"}, 0)
	r.shaped = kind == 1
	input_of :: proc(
		b: ^Reg_Build,
		f: ^Def_Field,
		v: Json_Value,
		item_numbers: []Item,
	) -> (
		Recipe_Input,
		bool,
	) {
		if v.kind != .String {
			fail_field(b, f, v, "an input is an item id or a #tag")
			return {}, false
		}
		if strings.has_prefix(v.s, "#") {
			at, ok := ref_index(b, .Item_Tag, v.s[1:], f, v)
			return {NO_ITEM, i32(at)}, ok
		}
		at, ok := ref_index(b, .Item, v.s, f, v)
		return {item_numbers[at] if ok else NO_ITEM, NO_TAG}, ok
	}
	if r.shaped {
		pf, kf := field_of(m, "pattern"), field_of(m, "key")
		if pf == nil || kf == nil || pf.value.kind != .Array || kf.value.kind != .Object {
			fail(
				b,
				m.pack,
				m.file,
				m.line,
				m.column,
				"a shaped recipe needs \"pattern\" (a list of rows) and \"key\" (an object)",
			)
			return r
		}
		rows := pf.value.items
		if len(rows) < 1 || len(rows) > 3 {
			fail_field(
				b,
				pf,
				pf.value,
				fmt.aprintf("a pattern has 1 to 3 rows, got %d", len(rows)),
			)
			return r
		}
		width := 0
		for row in rows {
			if row.kind != .String {
				fail_field(b, pf, row, "a pattern row is a string")
				return r
			}
			if width == 0 {width = len(row.s)}
			if len(row.s) != width || width < 1 || width > 3 {
				fail_field(
					b,
					pf,
					row,
					"pattern rows are 1 to 3 characters, all as long as the first",
				)
				return r
			}
		}
		keys := make(map[u8]Recipe_Input)
		for km in kf.value.members {
			if len(km.key) != 1 || km.key == " " {
				fail_field(
					b,
					kf,
					km.value,
					fmt.aprintf("key \"%s\" is one character, not a space", km.key),
				)
				continue
			}
			if in_, ok := input_of(b, kf, km.value, item_numbers); ok {keys[km.key[0]] = in_}
		}
		r.width, r.height = width, len(rows)
		r.inputs = make([]Recipe_Input, width * len(rows))
		for row, y in rows {
			for c, x in transmute([]u8)row.s {
				if c == ' ' {
					r.inputs[y * width + x] = {NO_ITEM, NO_TAG}
				} else if in_, ok := keys[c]; ok {
					r.inputs[y * width + x] = in_
				} else {
					fail_field(b, pf, row, fmt.aprintf("\"%c\" is not in the key; add it", c))
				}
			}
		}
	} else {
		f := field_of(m, "inputs")
		if f == nil || f.value.kind != .Array {
			fail(
				b,
				m.pack,
				m.file,
				m.line,
				m.column,
				"a shapeless recipe needs \"inputs\", a list of {\"item\": ..., \"count\": ...}",
			)
			return r
		}
		list := make([dynamic]Recipe_Input)
		errors_before := len(b.errs)
		for e in f.value.items {
			if e.kind != .Object {
				fail_field(b, f, e, "an input is {\"item\": \"<id or #tag>\", \"count\": 1}")
				continue
			}
			count := 1
			in_: Recipe_Input
			have := false
			for em in e.members {
				switch em.key {
				case "item":
					in_, have = input_of(b, f, em.value, item_numbers)
				case "count":
					if em.value.kind != .Int || em.value.i < 1 || em.value.i > 9 {
						fail_field(b, f, em.value, "count is 1..9")
					} else {
						count = int(em.value.i)
					}
				case:
					fail_field(
						b,
						f,
						em.value,
						fmt.aprintf(
							"\"%s\" is not an input field%s",
							em.key,
							suggestion(em.key, []string{"item", "count"}),
						),
					)
				}
			}
			if have {for _ in 0 ..< count {append(&list, in_)}}
		}
		if (len(list) < 1 || len(list) > 9) && len(b.errs) == errors_before {
			fail_field(
				b,
				f,
				f.value,
				fmt.aprintf("a recipe uses 1 to 9 inputs in all, got %d", len(list)),
			)
		}
		r.inputs = list[:]
	}
	if of := field_of(m, "output"); of != nil {
		if of.value.kind != .Object {
			fail_field(b, of, of.value, "output is {\"item\": \"<id>\", \"count\": 1}")
			return r
		}
		r.output.count = 1
		for om in of.value.members {
			switch om.key {
			case "item":
				if om.value.kind != .String {
					fail_field(b, of, om.value, "item is an item id")
				} else if at, ok := ref_index(b, .Item, om.value.s, of, om.value); ok {
					r.output.item = item_numbers[at]
				}
			case "count":
				if om.value.kind != .Int || om.value.i < 1 || om.value.i > 999 {
					fail_field(b, of, om.value, "count is 1..999")
				} else {
					r.output.count = int(om.value.i)
				}
			case:
				fail_field(
					b,
					of,
					om.value,
					fmt.aprintf(
						"\"%s\" is not an output field%s",
						om.key,
						suggestion(om.key, []string{"item", "count"}),
					),
				)
			}
		}
	} else {
		fail(
			b,
			m.pack,
			m.file,
			m.line,
			m.column,
			"\"output\" is missing; say what the recipe makes",
		)
	}
	return r
}
