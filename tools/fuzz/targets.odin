package fuzz_tool

import "common:base/fuzz"
import "common:game"
import "common:ogg"
import "server:."

// every_target: the harness's table. A package that adds a decoder of untrusted input lists
// its targets here (and in docs/fuzzing.md).
every_target :: proc() -> []fuzz.Target {
	out := make([dynamic]fuzz.Target)
	append(&out, ..game.game_fuzz_targets())
	append(&out, ..ogg.ogg_fuzz_targets())
	append(&out, ..server.server_fuzz_targets())
	return out[:]
}
