package tests

import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"

import "server:core"

// A new Earth universe's server starts in under a second (at -o:minimal, on CI's Linux
// runner): the climate model is decoded from assets/planet/earth_climate.bin, not built,
// which took seconds and froze the window at Ignite.
@(test)
test_earth_universe_starts_within_a_second :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "earth_start"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	os.make_directory_all(dir)
	config := core.harness_world()
	config.generator = .Earth
	config.earth = true
	config.spawn = nil
	config.save_dir = dir
	h := new(core.Harness)
	defer free(h)
	begin := time.tick_now()
	started := core.harness_start(h, config)
	took := time.tick_since(begin)
	if !testing.expect(t, started) {return}
	defer core.harness_stop(h)
	// Linux CI's runner is the budget's measure (#275); the macOS and Windows
	// runners run this unoptimized build about twice as slowly.
	limit := time.Second when ODIN_OS == .Linux else 2 * time.Second
	testing.expectf(
		t,
		took < limit,
		"an Earth universe took %v to start (at most %v)",
		took,
		limit,
	)
}
