package fuzz_tool

import "client:engine"
import "common:base/fuzz"
import "common:game"
import "common:netcode"
import "common:ogg"
import "common:script"
import "server:core"

// every_target: the harness's table. A package that adds a decoder of untrusted input lists
// its targets here (and in docs/fuzzing.md).
every_target :: proc() -> []fuzz.Target {
	out := make([dynamic]fuzz.Target)
	append(&out, ..engine.client_fuzz_targets())
	append(&out, ..game.game_fuzz_targets())
	append(&out, ..game.net_fuzz_targets())
	append(&out, ..netcode.net_fuzz_targets())
	append(&out, ..ogg.ogg_fuzz_targets())
	append(&out, ..script.script_fuzz_targets())
	append(&out, ..core.server_fuzz_targets())
	return out[:]
}
