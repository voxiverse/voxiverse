package fuzz_tool

import "client:."
import "common:base/fuzz"
import "common:game"
import "common:netcode"
import "common:ogg"
import "server:."

// every_target: the harness's table. A package that adds a decoder of untrusted input lists
// its targets here (and in docs/fuzzing.md).
every_target :: proc() -> []fuzz.Target {
	out := make([dynamic]fuzz.Target)
	append(&out, ..client.client_fuzz_targets())
	append(&out, ..game.game_fuzz_targets())
	append(&out, ..game.net_fuzz_targets())
	append(&out, ..netcode.net_fuzz_targets())
	append(&out, ..ogg.ogg_fuzz_targets())
	append(&out, ..server.server_fuzz_targets())
	return out[:]
}
