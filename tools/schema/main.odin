package schema

import "core:fmt"
import "core:os"
import "core:strings"

import "../../game"

// schema rewrites the generated block of the Wireshark dissector
// (tools/wireshark/voxiverse.lua, between `-- schema begin` and `-- schema end`)
// from the game's state schema, so the dissector decodes State and Snapshot
// messages by kind, key and field name. Run it as `./build.sh schema` after
// changing what the server replicates; game's test_dissector_schema_current
// fails while the block is stale.
//
//	build schema [file]

main :: proc() {
	path := "tools/wireshark/voxiverse.lua"
	if len(os.args) > 1 {path = os.args[1]}
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.eprintfln("schema: cannot read %s: %v", path, err)
		os.exit(1)
	}
	s := game.game_schema()
	b := strings.builder_make()
	game.schema_lua(&s, &b)
	source := string(data)
	updated, ok := game.schema_lua_splice(source, strings.to_string(b), context.allocator)
	if !ok {
		fmt.eprintfln("schema: %s has no `-- schema begin` ... `-- schema end` block", path)
		os.exit(1)
	}
	if updated == source {
		fmt.printfln("schema: %s is current (hash %016x)", path, s.hash)
		return
	}
	if werr := os.write_entire_file(path, updated); werr != nil {
		fmt.eprintfln("schema: cannot write %s: %v", path, werr)
		os.exit(1)
	}
	fmt.printfln("schema: %s updated (hash %016x)", path, s.hash)
}
