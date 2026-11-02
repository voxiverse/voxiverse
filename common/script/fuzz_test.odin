package script

import "core:testing"

import "common:base/fuzz"

// test_fuzz_smoke: the four fuzz targets at seed 51 (300 source mutations, 200 generated
// programs, 100 bytecode mutations, 100 snapshot mutations), their regression files first.
@(test)
test_fuzz_smoke :: proc(t: ^testing.T) {
	cases := [?]int{300, 200, 100, 100} // in script_fuzz_targets' order
	for &target, i in script_fuzz_targets() {
		report := fuzz.run_target(
			&target,
			{seed = 51, cases = cases[i], out_dir = "build/fuzz", regress = true},
		)
		defer fuzz.report_destroy(&report)
		testing.expectf(t, report.cases >= cases[i], "%s ran %d cases", target.name, report.cases)
		for f in report.failures {testing.expect(t, false, f)}
	}
}
