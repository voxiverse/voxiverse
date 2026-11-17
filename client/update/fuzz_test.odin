package update

import "core:testing"

import "common:base/fuzz"

// The targets' smoke tests (200 cases at seed 84, the seeds and every regression file of
// testdata/fuzz/<target>/regress/).

@(test)
test_fuzz_update_releases_smoke :: proc(t: ^testing.T) {
	smoke(t, "update.releases")
}

@(test)
test_fuzz_update_sums_smoke :: proc(t: ^testing.T) {
	smoke(t, "update.sums")
}

@(private = "file")
smoke :: proc(t: ^testing.T, name: string) {
	for &target in update_fuzz_targets() {
		if target.name != name {continue}
		report := fuzz.run_smoke(&target)
		defer fuzz.report_destroy(&report)
		for f in report.failures {testing.expect(t, false, f)}
		return
	}
	testing.expectf(t, false, "no target %s", name)
}
