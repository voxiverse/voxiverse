package build

import "core:fmt"
import "core:os"

// The block texture atlas is made here, at build time, not by the client at
// its start: tools/atlas runs the generators (client/texture) and writes
// ATLAS_DIR, which client/mesh carries inside the executable (#load). It is
// build output, never committed, and made again before anything compiles the
// client, so it cannot be stale.

ATLAS_DIR :: "build/textures" // (build/atlas is the tool)
// ATLAS_IMPORTS: what tools/atlas is built from besides its own folder.
ATLAS_IMPORTS :: []string{"client/texture"}

// write_atlas brings ATLAS_DIR up to date: the tool is built again when its sources
// changed, and run when it was, or when a file of the atlas is missing or older.
write_atlas :: proc() -> bool {
	exe := build_tool("atlas", ATLAS_IMPORTS) or_return
	exe_info, err := os.stat(exe, context.temp_allocator)
	if err != nil {return false}
	for name in ([]string{"blocks.rgba", "blocks.txt"}) {
		info, missing := os.stat(path_join({ATLAS_DIR, name}), context.temp_allocator)
		if missing != nil || info.modification_time._nsec < exe_info.modification_time._nsec {
			if !run({exe, ATLAS_DIR}) {
				fmt.eprintln("build: the block texture atlas could not be made")
				return false
			}
			break
		}
	}
	return true
}
