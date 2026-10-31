package netcode

import "core:testing"

import "common:base/fuzz"

// Each target's smoke test (200 cases at seed 84, the seeds and every regression file of
// testdata/fuzz/<target>/regress/).

@(private = "file")
smoke :: proc(t: ^testing.T, name: string) {
	for &target in net_fuzz_targets() {
		if target.name != name {continue}
		report := fuzz.run_smoke(&target)
		defer fuzz.report_destroy(&report)
		for f in report.failures {testing.expect(t, false, f)}
		return
	}
	testing.expectf(t, false, "no target %s", name)
}

@(test)
test_fuzz_net_packets_smoke :: proc(t: ^testing.T) {smoke(t, "net.packets")}

@(test)
test_fuzz_net_handshake_smoke :: proc(t: ^testing.T) {smoke(t, "net.handshake")}
