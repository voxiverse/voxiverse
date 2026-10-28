package game

import "core:fmt"
import "core:mem/virtual"
import "core:slice"
import "core:strings"

// registry_build: the registry the packs make, or every error found (never
// both). Pack files are in memory (Pack_Source), so tests build registries
// from string literals and nothing here touches the disk. The base pack comes
// first; a pack's namespace is its directory's name.

Pack_File :: struct {
	path: string, // within the pack: "data/blocks/stone.json"
	data: []u8,
}

Pack_Source :: struct {
	namespace: string, // the pack's directory name
	files:     []Pack_File,
}

// Pack_Error: <pack>/<file>:<line>:<column>: <what is wrong>; <the fix>
// (line 0: the file as a whole, no position).
Pack_Error :: struct {
	pack:    string,
	file:    string,
	line:    i32,
	column:  i32,
	message: string,
}

pack_error_text :: proc(e: Pack_Error, allocator := context.temp_allocator) -> string {
	where_ := e.pack
	if e.file != "" {where_ = fmt.aprintf("%s/%s", e.pack, e.file, allocator = allocator)}
	if e.line > 0 {
		return fmt.aprintf(
			"%s:%d:%d: %s",
			where_,
			e.line,
			e.column,
			e.message,
			allocator = allocator,
		)
	}
	if where_ == "" {return e.message}
	return fmt.aprintf("%s: %s", where_, e.message, allocator = allocator)
}

@(private)
KIND_DIRS := [Content_Kind]string {
	.Texture   = "assets/textures",
	.Sound     = "assets/sounds",
	.Block     = "data/blocks",
	.Item      = "data/items",
	.Block_Tag = "data/block_tags",
	.Item_Tag  = "data/item_tags",
	.Recipe    = "data/recipes",
	.Structure = "server/structures",
	.Shape     = "data/shapes",
}

// What a pack holds, by side: assets/ is the client's alone, data/ is both
// sides', server/ is the server's alone (the server sends assets/ and data/).
@(private)
PACK_LAYOUT_HELP :: "not a pack file; a pack holds pack.json and the directories assets/textures/, assets/sounds/ (client only), data/blocks/, data/items/, data/block_tags/, data/item_tags/, data/recipes/, data/shapes/ (both sides) and server/structures/ (server only)"

@(private)
KIND_NAMES := [Content_Kind]string {
	.Texture   = "a texture",
	.Sound     = "a sound set",
	.Block     = "a block",
	.Item      = "an item",
	.Block_Tag = "a block tag",
	.Item_Tag  = "an item tag",
	.Recipe    = "a recipe",
	.Structure = "a structure",
	.Shape     = "a shape",
}

@(private)
KIND_ADJ := [Content_Kind]string {
	.Texture   = "texture",
	.Sound     = "sound set",
	.Block     = "block",
	.Item      = "item",
	.Block_Tag = "block tag",
	.Item_Tag  = "item tag",
	.Recipe    = "recipe",
	.Structure = "structure",
	.Shape     = "shape",
}

@(private)
BLOCK_FIELDS := []string {
	"collides",
	"opaque",
	"targetable",
	"breakable",
	"placeable",
	"replaceable",
	"shades",
	"cull_same",
	"liquid",
	"light",
	"render",
	"layer",
	"textures",
	"sound",
	"drop",
	"support",
	"states",
	"default",
	"shape",
	"collision",
	"selection",
	"render_shape",
	"place",
	"climbable",
	"override",
}
@(private)
ITEM_FIELDS := []string{"stack", "places", "tool", "armor", "equip", "modifiers", "override"}
@(private)
TEXTURE_FIELDS := []string{"generator", "image", "override"}
@(private)
SOUND_FIELDS := []string{"generator", "break", "place", "step", "override"}
@(private)
TAG_FIELDS := []string{"values", "replace", "override"}
@(private)
RECIPE_FIELDS := []string{"type", "inputs", "pattern", "key", "output", "override"}
@(private)
PACK_FIELDS := []string{"format", "namespace", "version", "title", "description", "requires"}

@(private)
Def_Field :: struct {
	name:  string,
	value: Json_Value,
	pack:  int,
	file:  string,
	over:  bool, // set by an override
}

@(private)
Tag_Entry :: struct {
	text:   string,
	line:   i32,
	column: i32,
	pack:   int,
	file:   string,
}

@(private)
Merged_Def :: struct {
	id:     string,
	pack:   int,
	file:   string,
	line:   i32,
	column: i32,
	fields: [dynamic]Def_Field,
	values: [dynamic]Tag_Entry, // tags
	data:   []u8, // structures
	auto:   bool, // an item made from a placeable block
	aux:    int, // auto: the block's index
}

@(private)
Reg_Error :: struct {
	order: int,
	e:     Pack_Error,
}

// Asset_File: a PNG or an Ogg of a pack; a texture or sound set that names it
// marks it used, and one nothing names is an error.
@(private)
Asset_File :: struct {
	pack: int,
	path: string,
	data: []u8,
	used: bool,
}

@(private)
Reg_Build :: struct {
	assets:  [dynamic]Asset_File,
	sources: []Pack_Source,
	side:    Registry_Side,
	errs:    [dynamic]Reg_Error,
	packs:   [dynamic]Pack_Info,
	defs:    [Content_Kind][dynamic]Merged_Def,
	index:   [Content_Kind]map[string]int,
	by_dir:  [][Content_Kind][dynamic]Pack_File, // per pack
}

@(private)
fail :: proc(b: ^Reg_Build, pack: int, file: string, line, column: i32, message: string) {
	name := b.sources[pack].namespace if pack >= 0 && pack < len(b.sources) else ""
	append(&b.errs, Reg_Error{order = pack, e = {name, file, line, column, message}})
}

@(private)
fail_field :: proc(b: ^Reg_Build, f: ^Def_Field, v: Json_Value, message: string) {
	fail(b, f.pack, f.file, v.line, v.column, message)
}

// edit_distance: Levenshtein distance of a and b.
@(private)
edit_distance :: proc(a, b: string) -> int {
	if abs(len(a) - len(b)) > 3 {return 99}
	prev := make([]int, len(b) + 1, context.temp_allocator)
	cur := make([]int, len(b) + 1, context.temp_allocator)
	for j in 0 ..= len(b) {prev[j] = j}
	for i in 1 ..= len(a) {
		cur[0] = i
		for j in 1 ..= len(b) {
			cost := 0 if a[i - 1] == b[j - 1] else 1
			cur[j] = min(min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost)
		}
		prev, cur = cur, prev
	}
	return prev[len(b)]
}

// suggestion: `; did you mean "x"?` for the closest of options within two
// edits, else the list (or nothing when it is long and listed false).
@(private)
suggestion :: proc(word: string, options: []string, list := true) -> string {
	best, best_d := "", 3
	for o in options {
		if d := edit_distance(word, o); d < best_d {
			best, best_d = o, d
		}
	}
	if best != "" {return fmt.aprintf("; did you mean \"%s\"?", best)}
	if list && len(options) > 0 {
		return fmt.aprintf("; the valid ones are %s", join_quoted(options))
	}
	return ""
}

@(private)
join_quoted :: proc(options: []string) -> string {
	sb := strings.builder_make()
	for o, i in options {
		if i > 0 {strings.write_string(&sb, ", ")}
		fmt.sbprintf(&sb, "\"%s\"", o)
	}
	return strings.to_string(sb)
}

@(private)
index_keys :: proc(m: map[string]int) -> []string {
	keys := make([dynamic]string)
	for k in m {append(&keys, k)}
	slice.sort(keys[:])
	return keys[:]
}

@(private)
valid_path :: proc(path: string) -> bool {
	if len(path) == 0 || len(path) > MAX_PACK_PATH {return false}
	for c in transmute([]u8)path {
		if !((c >= 'a' && c <= 'z') ||
			   (c >= '0' && c <= '9') ||
			   c == '_' ||
			   c == '.' ||
			   c == '/' ||
			   c == '-') {return false}
	}
	return true
}

// Registry_Side: the server builds from every file of every pack; a client
// from assets/ and data/ only (it never has server/, and refuses one).
Registry_Side :: enum {
	Server,
	Client,
}

registry_build :: proc(
	sources: []Pack_Source,
	side := Registry_Side.Server,
	allocator := context.allocator,
) -> (
	reg: ^Registry,
	errs: []Pack_Error,
) {
	reg = new(Registry, allocator)
	reg.allocator = allocator
	reg.arena = new(virtual.Arena, allocator)
	if virtual.arena_init_growing(reg.arena) != nil {
		free(reg.arena, allocator)
		free(reg, allocator)
		return nil, nil
	}
	context.allocator = virtual.arena_allocator(reg.arena)

	b := Reg_Build {
		sources = sources,
		side    = side,
	}
	build_packs(&b)
	if len(b.errs) == 0 {
		resolve_all(&b, reg)
	}
	if len(b.errs) > 0 {
		list := make([]Reg_Error, len(b.errs), context.temp_allocator)
		copy(list, b.errs[:])
		slice.stable_sort_by(list, proc(x, y: Reg_Error) -> bool {
			if x.order != y.order {return x.order < y.order}
			if x.e.file != y.e.file {return x.e.file < y.e.file}
			if x.e.line != y.e.line {return x.e.line < y.e.line}
			return x.e.column < y.e.column
		})
		n := min(len(list), MAX_ERRORS)
		out := make([]Pack_Error, n + (1 if len(list) > n else 0), allocator)
		for i in 0 ..< n {
			e := list[i].e
			out[i] = {
				strings.clone(e.pack, allocator),
				strings.clone(e.file, allocator),
				e.line,
				e.column,
				strings.clone(e.message, allocator),
			}
		}
		if len(list) > n {
			out[n] = {
				message = fmt.aprintf("... and %d more", len(list) - n, allocator = allocator),
			}
		}
		virtual.arena_destroy(reg.arena)
		free(reg.arena, allocator)
		free(reg, allocator)
		return nil, out
	}
	return reg, nil
}

// build_packs: reads every pack's files into merged definitions.
@(private)
build_packs :: proc(b: ^Reg_Build) {
	if len(b.sources) > MAX_PACKS {
		fail(b, -1, "", 0, 0, fmt.aprintf("%d packs; the limit is %d", len(b.sources), MAX_PACKS))
		return
	}
	b.by_dir = make([][Content_Kind][dynamic]Pack_File, len(b.sources))
	for src, pi in b.sources {read_pack_manifest(b, pi, src)}
	if len(b.errs) > 0 {return}
	// Kind by kind, so a block's item exists before the item files merge.
	for kind in Content_Kind {
		if kind == .Item {seed_block_items(b)}
		for pi in 0 ..< len(b.sources) {
			for f in b.by_dir[pi][kind] {read_definitions(b, pi, kind, f)}
		}
		if kind == .Structure {continue}
	}
}

// asset_suffix: the extension of the art or sound files that sit beside a
// kind's definitions ("" for a kind with none).
@(private)
asset_suffix :: proc(kind: Content_Kind) -> string {
	#partial switch kind {
	case .Texture:
		return ".png"
	case .Sound:
		return ".ogg"
	}
	return ""
}

@(private)
read_pack_manifest :: proc(b: ^Reg_Build, pi: int, src: Pack_Source) {
	info: Pack_Info
	info.namespace = src.namespace
	if !id_part_valid(src.namespace, 32) {
		fail(
			b,
			pi,
			"",
			0,
			0,
			fmt.aprintf(
				"directory \"%s\" is not a namespace; use 1 to 32 of a-z, 0-9 and _",
				src.namespace,
			),
		)
	}
	if pi > 0 && src.namespace == BASE_NAMESPACE {
		fail(b, pi, "", 0, 0, "the namespace voxiverse is the base game's; use your own")
	}
	files := make([]Pack_File, len(src.files))
	copy(files, src.files)
	slice.sort_by(files, proc(x, y: Pack_File) -> bool {return x.path < y.path})
	if len(files) > MAX_PACK_FILES {
		fail(b, pi, "", 0, 0, fmt.aprintf("%d files; the limit is %d", len(files), MAX_PACK_FILES))
		return
	}
	total := 0
	manifest: Maybe([]u8)
	loot_reported := false
	for f in files {
		total += len(f.data)
		if !valid_path(f.path) {
			fail(
				b,
				pi,
				f.path,
				0,
				0,
				fmt.aprintf(
					"path is over %d bytes or has a character outside a-z, 0-9 and _./-; rename it",
					MAX_PACK_PATH,
				),
			)
			continue
		}
		if len(f.data) > JSON_MAX_FILE {
			fail(
				b,
				pi,
				f.path,
				0,
				0,
				fmt.aprintf("file is %d bytes; the limit is %d", len(f.data), JSON_MAX_FILE),
			)
			continue
		}
		if b.side == .Client && strings.has_prefix(f.path, "server/") {
			fail(
				b,
				pi,
				f.path,
				0,
				0,
				"a client has no server/ files; the server does not send them",
			)
			continue
		}
		if f.path == "pack.json" {
			manifest = f.data
			continue
		}
		parts := strings.split(f.path, "/")
		matched := false
		if len(parts) == 3 {
			dir := f.path[:len(parts[0]) + 1 + len(parts[1])]
			for kind in Content_Kind {
				if dir != KIND_DIRS[kind] {continue}
				if asset_suffix(kind) != "" &&
				   strings.has_suffix(parts[2], asset_suffix(kind)) &&
				   len(parts[2]) > len(asset_suffix(kind)) {
					append(&b.assets, Asset_File{pack = pi, path = f.path, data = f.data})
					matched = true
					continue
				}
				want := ".vxs" if kind == .Structure else ".json"
				if strings.has_suffix(parts[2], want) && len(parts[2]) > len(want) {
					append(&b.by_dir[pi][kind], f)
					matched = true
				} else {
					fail(
						b,
						pi,
						f.path,
						0,
						0,
						fmt.aprintf("not a pack file: %s/ holds %s files", dir, want),
					)
					matched = true
				}
			}
		}
		if !matched {
			if len(parts) > 1 && parts[0] == "server" && parts[1] == "loot_tables" {
				if !loot_reported {
					fail(
						b,
						pi,
						"server/loot_tables/",
						0,
						0,
						"loot tables are read from M53 on; remove the directory",
					)
					loot_reported = true
				}
			} else {
				fail(b, pi, f.path, 0, 0, PACK_LAYOUT_HELP)
			}
		}
	}
	info.files = len(files)
	if total > MAX_PACK_BYTES {
		fail(
			b,
			pi,
			"",
			0,
			0,
			fmt.aprintf("pack is %d bytes; the limit is %d", total, MAX_PACK_BYTES),
		)
	}
	data, has := manifest.?
	if !has {
		fail(b, pi, "", 0, 0, "the pack has no pack.json; add one")
		append(&b.packs, info)
		return
	}
	root, err, ok := json_parse(string(data))
	if !ok {
		fail(b, pi, "pack.json", err.line, err.column, err.message)
		append(&b.packs, info)
		return
	}
	if root.kind != .Object {
		fail(b, pi, "pack.json", root.line, root.column, "pack.json holds one object")
		append(&b.packs, info)
		return
	}
	seen: [6]bool
	for m in root.members {
		idx := -1
		for n, i in PACK_FIELDS {if n == m.key {idx = i}}
		if idx < 0 {
			fail(
				b,
				pi,
				"pack.json",
				m.key_line,
				m.key_column,
				fmt.aprintf("\"%s\" is not a pack field%s", m.key, suggestion(m.key, PACK_FIELDS)),
			)
			continue
		}
		seen[idx] = true
		v := m.value
		switch m.key {
		case "format":
			if v.kind != .Int || v.i != 1 {
				fail(
					b,
					pi,
					"pack.json",
					v.line,
					v.column,
					"format is 1; this game reads format 1 packs",
				)
			}
		case "namespace":
			if v.kind != .String {
				fail(b, pi, "pack.json", v.line, v.column, "namespace is a string")
			} else if v.s != src.namespace {
				fail(
					b,
					pi,
					"pack.json",
					v.line,
					v.column,
					fmt.aprintf(
						"namespace \"%s\" does not match the directory \"%s\"; rename one",
						v.s,
						src.namespace,
					),
				)
			}
		case "version", "title", "description":
			if v.kind != .String {
				fail(b, pi, "pack.json", v.line, v.column, fmt.aprintf("%s is a string", m.key))
			} else {
				switch m.key {
				case "version":
					info.version = v.s
				case "title":
					info.title = v.s
				case "description":
					info.description = v.s
				}
			}
		case "requires":
			if v.kind != .Array {
				fail(b, pi, "pack.json", v.line, v.column, "requires is a list of namespaces")
				break
			}
			req := make([dynamic]string)
			for item in v.items {
				if item.kind != .String {
					fail(
						b,
						pi,
						"pack.json",
						item.line,
						item.column,
						"requires holds namespaces as strings",
					)
					continue
				}
				found := false
				for p in b.packs[:pi] {if p.namespace == item.s {found = true}}
				if !found {
					fail(
						b,
						pi,
						"pack.json",
						item.line,
						item.column,
						fmt.aprintf(
							"requires \"%s\", which is not loaded before this pack; list it earlier in the universe's packs",
							item.s,
						),
					)
				}
				append(&req, item.s)
			}
			info.requires = req[:]
		}
	}
	for n, i in PACK_FIELDS {
		if !seen[i] && (n == "format" || n == "namespace" || n == "version") {
			fail(b, pi, "pack.json", 1, 1, fmt.aprintf("\"%s\" is missing; add it", n))
		}
	}
	append(&b.packs, info)
}

@(private)
fields_of :: proc(kind: Content_Kind) -> []string {
	#partial switch kind {
	case .Block:
		return BLOCK_FIELDS
	case .Item:
		return ITEM_FIELDS
	case .Texture:
		return TEXTURE_FIELDS
	case .Sound:
		return SOUND_FIELDS
	case .Block_Tag, .Item_Tag:
		return TAG_FIELDS
	case .Recipe:
		return RECIPE_FIELDS
	case .Shape:
		return SHAPE_FIELDS
	}
	return nil
}

@(private)
source_name :: proc(b: ^Reg_Build, m: ^Merged_Def, from: int) -> string {
	if m.pack == from {return fmt.aprintf("%s:%d:%d", m.file, m.line, m.column)}
	return fmt.aprintf("%s/%s:%d:%d", b.sources[m.pack].namespace, m.file, m.line, m.column)
}

// seed_block_items: every placeable block has an item of the same id.
@(private)
seed_block_items :: proc(b: ^Reg_Build) {
	for &blk, i in b.defs[.Block] {
		placeable := true
		for f in blk.fields {
			if f.name == "placeable" && f.value.kind == .Bool {placeable = f.value.b}
		}
		if !placeable {continue}
		b.index[.Item][blk.id] = len(b.defs[.Item])
		append(
			&b.defs[.Item],
			Merged_Def {
				id = blk.id,
				pack = blk.pack,
				file = blk.file,
				line = blk.line,
				column = blk.column,
				auto = true,
				aux = i,
			},
		)
	}
}

@(private)
read_definitions :: proc(b: ^Reg_Build, pi: int, kind: Content_Kind, file: Pack_File) {
	ns := b.sources[pi].namespace
	if kind == .Structure {
		name := strings.trim_suffix(file.path[len("server/structures/"):], ".vxs")
		if !id_part_valid(name, 48) {
			fail(
				b,
				pi,
				file.path,
				0,
				0,
				fmt.aprintf("\"%s\" is not a structure name; use 1 to 48 of a-z, 0-9 and _", name),
			)
			return
		}
		id := strings.concatenate({ns, ":", name})
		if prev, dup := b.index[.Structure][id]; dup {
			fail(
				b,
				pi,
				file.path,
				0,
				0,
				fmt.aprintf(
					"\"%s\" is defined twice (first at %s); rename one",
					name,
					b.defs[.Structure][prev].file,
				),
			)
			return
		}
		b.index[.Structure][id] = len(b.defs[.Structure])
		append(
			&b.defs[.Structure],
			Merged_Def{id = id, pack = pi, file = file.path, data = file.data},
		)
		return
	}
	root, err, ok := json_parse(string(file.data))
	if !ok {
		fail(b, pi, file.path, err.line, err.column, err.message)
		return
	}
	if root.kind != .Object {
		fail(
			b,
			pi,
			file.path,
			root.line,
			root.column,
			"a definition file holds one object whose keys are names; write {\"name\": {...}}",
		)
		return
	}
	valid := fields_of(kind)
	for m in root.members {
		def := m.value
		if def.kind != .Object {
			fail(
				b,
				pi,
				file.path,
				def.line,
				def.column,
				fmt.aprintf("\"%s\" must be an object of fields", m.key),
			)
			continue
		}
		// The id: a bare key is in this pack's namespace.
		full := m.key
		other_ns := false
		if strings.contains(m.key, ":") {
			id, id_ok := id_parse(m.key)
			if !id_ok {
				fail(
					b,
					pi,
					file.path,
					m.key_line,
					m.key_column,
					fmt.aprintf(
						"\"%s\" is not an id; use namespace:name in a-z, 0-9 and _",
						m.key,
					),
				)
				continue
			}
			full = m.key
			other_ns = id.namespace != ns
		} else {
			if !id_part_valid(m.key, 48) {
				fail(
					b,
					pi,
					file.path,
					m.key_line,
					m.key_column,
					fmt.aprintf("\"%s\" is not a name; use 1 to 48 of a-z, 0-9 and _", m.key),
				)
				continue
			}
			full = strings.concatenate({ns, ":", m.key})
		}
		override := false
		for fm in def.members {
			if fm.key == "override" {
				if fm.value.kind != .Bool {
					fail(
						b,
						pi,
						file.path,
						fm.value.line,
						fm.value.column,
						"override is true or false",
					)
				} else {
					override = fm.value.b
				}
			}
		}
		is_tag := kind == .Block_Tag || kind == .Item_Tag
		at, exists := b.index[kind][full]
		switch {
		case !exists && (override || other_ns) && !is_tag:
			if override {
				fail(
					b,
					pi,
					file.path,
					m.key_line,
					m.key_column,
					fmt.aprintf(
						"\"%s\" does not exist, so it cannot be overridden%s",
						m.key,
						suggestion(full, index_keys(b.index[kind]), false),
					),
				)
			} else {
				fail(
					b,
					pi,
					file.path,
					m.key_line,
					m.key_column,
					fmt.aprintf(
						"\"%s\" is in another pack's namespace; define your own ids as \"%s:name\", or set \"override\": true to change that one",
						m.key,
						ns,
					),
				)
			}
			continue
		case !exists && other_ns && is_tag:
			fail(
				b,
				pi,
				file.path,
				m.key_line,
				m.key_column,
				fmt.aprintf(
					"\"%s\" does not exist; tags of another namespace can only be added to",
					m.key,
				),
			)
			continue
		case exists && !override && !is_tag:
			first := &b.defs[kind][at]
			fail(
				b,
				pi,
				file.path,
				m.key_line,
				m.key_column,
				fmt.aprintf(
					"\"%s\" is defined twice (first at %s); rename one, or set \"override\": true",
					m.key,
					source_name(b, first, pi),
				),
			)
			continue
		}
		if !exists {
			at = len(b.defs[kind])
			b.index[kind][full] = at
			append(
				&b.defs[kind],
				Merged_Def {
					id = full,
					pack = pi,
					file = file.path,
					line = m.key_line,
					column = m.key_column,
				},
			)
		}
		target := &b.defs[kind][at]
		over := exists
		if is_tag {
			// replace drops what the earlier packs gave; this file's values follow.
			for fm in def.members {
				if fm.key == "replace" &&
				   fm.value.kind == .Bool &&
				   fm.value.b {clear(&target.values)}
			}
		}
		for fm in def.members {
			if fm.key == "override" {continue}
			known := false
			for v in valid {if v == fm.key {known = true}}
			if !known {
				fail(
					b,
					pi,
					file.path,
					fm.key_line,
					fm.key_column,
					fmt.aprintf(
						"\"%s\" is not a %s field%s",
						fm.key,
						KIND_ADJ[kind],
						suggestion(fm.key, valid),
					),
				)
				continue
			}
			if is_tag {
				read_tag_field(b, target, pi, file.path, fm)
				continue
			}
			// A conflict: another pack (not the base) overrode this field, and this
			// one does not build on it.
			for f in target.fields {
				if f.name == fm.key && over && f.over && f.pack != pi && f.pack != 0 && pi != 0 {
					known_req := false
					for r in b.packs[pi].requires {if r == b.sources[f.pack].namespace {known_req = true}}
					// (the requires of a pack still being read: look at the manifest)
					if !known_req {
						fail(
							b,
							pi,
							file.path,
							fm.key_line,
							fm.key_column,
							fmt.aprintf(
								"%s.%s is also set by %s (%s:%d:%d); add \"%s\" to %s's requires to override it knowingly",
								full,
								fm.key,
								b.sources[f.pack].namespace,
								f.file,
								f.value.line,
								f.value.column,
								b.sources[f.pack].namespace,
								ns,
							),
						)
					}
				}
			}
			replaced := false
			for &f in target.fields {
				if f.name == fm.key {
					f = {fm.key, fm.value, pi, file.path, over}
					replaced = true
				}
			}
			if !replaced {append(&target.fields, Def_Field{fm.key, fm.value, pi, file.path, over})}
		}
	}
}

@(private)
read_tag_field :: proc(
	b: ^Reg_Build,
	target: ^Merged_Def,
	pi: int,
	file: string,
	fm: Json_Member,
) {
	switch fm.key {
	case "replace":
		if fm.value.kind != .Bool {
			fail(b, pi, file, fm.value.line, fm.value.column, "replace is true or false")
		}
	case "values":
		if fm.value.kind != .Array {
			fail(b, pi, file, fm.value.line, fm.value.column, "values is a list of ids and #tags")
			return
		}
		for item in fm.value.items {
			if item.kind != .String {
				fail(b, pi, file, item.line, item.column, "values holds ids as strings")
				continue
			}
			dup := false
			for x in target.values {if x.text == item.s {dup = true}}
			if !dup {append(&target.values, Tag_Entry{item.s, item.line, item.column, pi, file})}
		}
	}
}
