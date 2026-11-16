package protocol

import "core:testing"

import "common:base/fuzz"

// The wire's fuzz targets' smoke tests (net_fuzz_targets, fuzz_net.odin).

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
		report := fuzz.run_target(
			&target,
			{seed = 84, cases = cases, out_dir = "build/fuzz", regress = true},
		)
		defer fuzz.report_destroy(&report)
		for f in report.failures {testing.expect(t, false, f)}
		return
	}
	testing.expectf(t, false, "no target %s", name)
}
