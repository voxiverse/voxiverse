package server

import "core:testing"

import "common:base/fuzz"

// Each target's smoke test (200 cases at seed 84, the seeds and every regression file of
// testdata/fuzz/<target>/regress/).

@(private = "file")
smoke :: proc(t: ^testing.T, name: string) {
	for &target in server_fuzz_targets() {
		if target.name != name {continue}
		report := fuzz.run_smoke(&target)
		defer fuzz.report_destroy(&report)
		for f in report.failures {testing.expect(t, false, f)}
		return
	}
	testing.expectf(t, false, "no target %s", name)
}

@(test)
test_fuzz_save_tx_smoke :: proc(t: ^testing.T) {smoke(t, "save.tx")}

@(test)
test_fuzz_save_player_smoke :: proc(t: ^testing.T) {smoke(t, "save.player")}

@(test)
test_fuzz_save_import_smoke :: proc(t: ^testing.T) {smoke(t, "save.import")}

@(test)
test_fuzz_save_config_smoke :: proc(t: ^testing.T) {smoke(t, "save.config")}

@(test)
test_fuzz_text_parsers_smoke :: proc(t: ^testing.T) {smoke(t, "text.parsers")}

@(test)
test_fuzz_net_server_session_smoke :: proc(t: ^testing.T) {smoke(t, "net.server_session")}

@(test)
test_fuzz_commands_player_smoke :: proc(t: ^testing.T) {smoke(t, "commands.player")}
