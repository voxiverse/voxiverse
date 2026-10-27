package game

import "base:runtime"
import "core:fmt"
import "core:path/filepath"
import "core:strings"

// The base pack, compiled in: assets/packs/voxiverse/. Nothing beside the
// executable. #load_directory is not recursive, so one per category.

@(private = "file")
BASE_PACK_JSON := #load("../../assets/packs/voxiverse/pack.json")
@(private = "file")
BASE_BLOCKS := #load_directory("../../assets/packs/voxiverse/blocks")
@(private = "file")
BASE_ITEMS := #load_directory("../../assets/packs/voxiverse/items")
@(private = "file")
BASE_TEXTURES := #load_directory("../../assets/packs/voxiverse/textures")
@(private = "file")
BASE_SOUNDS := #load_directory("../../assets/packs/voxiverse/sounds")
@(private = "file")
BASE_BLOCK_TAGS := #load_directory("../../assets/packs/voxiverse/block_tags")
@(private = "file")
BASE_STRUCTURES := #load_directory("../../assets/packs/voxiverse/structures")

// base_pack_source: the base pack's files, for registry_build (and for
// tools, which check other packs against it).
base_pack_source :: proc(allocator := context.allocator) -> Pack_Source {
	context.allocator = allocator
	files := make([dynamic]Pack_File)
	append(&files, Pack_File{"pack.json", BASE_PACK_JSON})
	add :: proc(files: ^[dynamic]Pack_File, dir: string, loaded: []runtime.Load_Directory_File) {
		for f in loaded {
			append(files, Pack_File{join_path(dir, filepath.base(f.name)), f.data})
		}
	}
	add(&files, "blocks", BASE_BLOCKS)
	add(&files, "items", BASE_ITEMS)
	add(&files, "textures", BASE_TEXTURES)
	add(&files, "sounds", BASE_SOUNDS)
	add(&files, "block_tags", BASE_BLOCK_TAGS)
	add(&files, "structures", BASE_STRUCTURES)
	return {BASE_NAMESPACE, files[:]}
}

@(private = "file")
join_path :: proc(dir, name: string) -> string {
	return strings.concatenate({dir, "/", name})
}

// registry_base: the registry of the base pack alone.
registry_base :: proc(allocator := context.allocator) -> ^Registry {
	src := base_pack_source(context.temp_allocator)
	reg, errs := registry_build({src}, allocator)
	if reg == nil {
		for e in errs {fmt.eprintln(pack_error_text(e))}
		panic("the base pack does not build")
	}
	return reg
}
