package tests

import "core:os"
import "core:path/filepath"
import "core:testing"

import "server:core"

// A new Earth universe's server starts cleanly: the climate model is decoded
// from assets/planet/earth_climate.bin, not built from scratch at start.
@(test)
test_earth_universe_starts :: proc(t: ^testing.T) {
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
	started := core.harness_start(h, config)
	if !testing.expect(t, started) {return}
	defer core.harness_stop(h)
	testing.expect(t, h.started, "server harness started cleanly")
}
