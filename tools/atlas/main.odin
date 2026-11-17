package atlas

import "core:fmt"
import "core:os"
import "core:path/filepath"

import "client:texture"

// Writes the block texture atlas (client/texture: atlas_make) into a
// directory. The driver runs it before anything compiles the client
// (tools/build/atlas.odin).
//
//	atlas build/textures

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln("usage: atlas <directory>")
		os.exit(2)
	}
	dir := os.args[1]
	if err := os.make_directory_all(dir); err != nil && err != .Exist {
		fmt.eprintfln("atlas: cannot make %s: %v", dir, err)
		os.exit(1)
	}
	pixels, index := texture.atlas_make()
	ok := write(dir, texture.ATLAS_PIXELS, pixels)
	ok = write(dir, texture.ATLAS_INDEX, transmute([]u8)index) && ok
	if !ok {os.exit(1)}
}

write :: proc(dir, name: string, data: []u8) -> bool {
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	if err := os.write_entire_file(path, data); err != nil {
		fmt.eprintfln("atlas: cannot write %s: %v", path, err)
		return false
	}
	return true
}
