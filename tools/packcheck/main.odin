package packcheck

import "core:fmt"
import "core:os"

import "../../common/game"
import "../../server"

// Checks packs: the base pack plus the given pack directories, in order, the
// way a universe loads them. Prints every error, one per line
// (<pack>/<file>:<line>:<column>: <what is wrong>; <the fix>), and exits
// non-zero if there is one. The validator a pack author (or an agent) runs.
//
//	build packs                     the base pack alone
//	build packs path/to/farmfix path/to/moretrees

main :: proc() {
	sources := make([dynamic]game.Pack_Source)
	append(&sources, game.base_pack_source())
	failed := false
	for dir in os.args[1:] {
		src, errs := server.pack_read_dir(dir)
		for e in errs {
			fmt.println(game.pack_error_text(e))
			failed = true
		}
		append(&sources, src)
	}
	if failed {os.exit(1)}
	reg, errs := game.registry_build(sources[:])
	if reg == nil {
		for e in errs {fmt.println(game.pack_error_text(e))}
		os.exit(1)
	}
	fmt.printfln(
		"ok: %d packs, %d blocks, %d items, %d textures, %d sound sets, %d recipes, %d structures, registry %016x",
		len(reg.packs),
		reg.blocks.count,
		len(game.registry_every_item(reg)),
		len(reg.textures),
		len(reg.sounds),
		len(reg.recipes),
		len(reg.structures),
		reg.hash,
	)
}
