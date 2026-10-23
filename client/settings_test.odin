package client

import "core:os"
import "core:testing"

import "../base"

// Every variable table names real fields of supported types, with defaults
// inside their ranges.
@(test)
test_variable_tables :: proc(t: ^testing.T) {
	app: App
	for v in app_variables(&app) {
		testing.expectf(
			t,
			base.var_table_check(v.table),
			"table %q has a bad range or default",
			v.table.prefix,
		)
	}
}

@(test)
test_settings_round_trip :: proc(t: ^testing.T) {
	path := "build/test/settings_test.cfg"
	os.make_directory_all("build/test")
	os.set_env("VX_SETTINGS", path)
	defer os.unset_env("VX_SETTINGS")
	defer os.remove(path)

	a: App
	settings_load(&a) // no file yet: defaults
	testing.expect(t, a.settings == SETTINGS_DEFAULTS)
	a.settings.fov, a.settings.view_radius, a.settings.invert_mouse = 95, 20, true
	settings_save(&a)

	b: App
	settings_load(&b)
	testing.expect(t, a.settings == b.settings)

	// Scripted changes are never marked for saving.
	b.scripted = true
	settings_changed(&b)
	testing.expect(t, !b.settings_dirty)
}

@(test)
test_fps_counter :: proc(t: ^testing.T) {
	f: Fps
	gpu := new(base.Frame_Stats)
	defer free(gpu)
	for _ in 0 ..< 49 {fps_update(&f, 10, gpu)}
	testing.expect_value(t, f.fps, 0) // under half a second: nothing yet
	for _ in 0 ..< 3 {base.frame_stats_add(gpu, 4)}
	fps_update(&f, 10, gpu) // 50 frames in 500 ms
	testing.expectf(t, abs(f.fps - 100) < 1e-3, "fps %v", f.fps)
	testing.expectf(t, abs(f.frame_ms - 10) < 1e-3, "frame %v", f.frame_ms)
	testing.expect_value(t, f.gpu_ms, 4)
	// The next window stands alone: 250 frames of 2 ms.
	base.frame_stats_add(gpu, 1)
	for _ in 0 ..< 250 {fps_update(&f, 2, gpu)}
	testing.expectf(t, abs(f.fps - 500) < 1e-2, "fps %v", f.fps)
	testing.expect_value(t, f.gpu_ms, 1)
}
