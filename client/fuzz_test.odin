package client

import "core:testing"

import "common:base/fuzz"

// The target's smoke test (200 cases at seed 84, the seeds and every regression file of
// testdata/fuzz/<target>/regress/).

@(test)
test_fuzz_net_client_session_smoke :: proc(t: ^testing.T) {
	for &target in client_fuzz_targets() {
		report := fuzz.run_smoke(&target)
		defer fuzz.report_destroy(&report)
		for f in report.failures {testing.expect(t, false, f)}
	}
}
