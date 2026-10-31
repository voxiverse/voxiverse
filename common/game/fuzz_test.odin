package game

import "core:testing"

import "common:base/fuzz"

// Each target's smoke test (200 cases at seed 84, the seeds and every regression file of
// testdata/fuzz/<target>/regress/): `build test` alone exercises every target.

@(private = "file")
smoke :: proc(t: ^testing.T, name: string) {
	for &target in game_fuzz_targets() {
		if target.name != name {continue}
		report := fuzz.run_smoke(&target)
		defer fuzz.report_destroy(&report)
		for f in report.failures {testing.expect(t, false, f)}
		return
	}
	testing.expectf(t, false, "no target %s", name)
}

@(test)
test_fuzz_pack_json_smoke :: proc(t: ^testing.T) {smoke(t, "pack.json")}

@(test)
test_fuzz_pack_registry_smoke :: proc(t: ^testing.T) {smoke(t, "pack.registry")}

@(test)
test_fuzz_pack_png_smoke :: proc(t: ^testing.T) {smoke(t, "pack.png")}

@(test)
test_fuzz_pack_archive_smoke :: proc(t: ^testing.T) {smoke(t, "pack.archive")}

@(test)
test_fuzz_save_region_smoke :: proc(t: ^testing.T) {smoke(t, "save.region")}

@(test)
test_fuzz_save_journal_smoke :: proc(t: ^testing.T) {smoke(t, "save.journal")}

@(test)
test_fuzz_save_structure_smoke :: proc(t: ^testing.T) {smoke(t, "save.structure")}

@(test)
test_fuzz_net_client_decode_smoke :: proc(t: ^testing.T) {smoke_net(t, "net.client_decode", 25000)}

@(test)
test_fuzz_net_server_decode_smoke :: proc(t: ^testing.T) {smoke_net(t, "net.server_decode", 25000)}

@(test)
test_fuzz_net_state_smoke :: proc(t: ^testing.T) {smoke_net(t, "net.state", 3000)}

@(private = "file")
// smoke_net: the suite on every OS runs at least as many cases as the loops these targets
// replaced (25 000 decodes each way, 3 000 state messages), not run_smoke's 200.
smoke_net :: proc(t: ^testing.T, name: string, cases: int) {
	for &target in net_fuzz_targets() {
		if target.name != name {continue}
		report := fuzz.run_target(&target, {seed = 84, cases = cases, out_dir = "build/fuzz", regress = true})
		defer fuzz.report_destroy(&report)
		for f in report.failures {testing.expect(t, false, f)}
		return
	}
	testing.expectf(t, false, "no target %s", name)
}
