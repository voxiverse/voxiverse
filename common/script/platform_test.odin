package script

import "base:runtime"

import platform "common:platform"

import "common:base"

// The clocks read the OS through the platform layer, installed at boot: a test binary has no
// main to do it, so it boots before its tests run.
@(init)
boot_platform_for_tests :: proc "contextless" () {
	context = runtime.default_context()
	host: base.Host
	platform.boot(&host)
}
