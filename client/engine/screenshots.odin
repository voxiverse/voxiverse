package engine

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "client:gpu"
import "common:base"

// Screenshots (F2, or `screenshot [name]`): PNGs in screenshots/ next to the
// executable (build/screenshots in development). They arrive a frame or two
// after the request, once the GPU is done with that frame.

screenshot_request :: proc(app: ^App, name: string) {
	n := name
	if n == "" {
		now := time.now()
		y, mon, d := time.date(now)
		h, min, s := time.clock(now)
		n = fmt.tprintf("%04d%02d%02d-%02d%02d%02d", y, mon, d, h, min, s)
	}
	append(&app.screenshot_names, strings.clone(n))
	gpu.request_screenshot(&app.g)
}

// screenshots_save writes any screenshots the GPU has finished.
screenshots_save :: proc(app: ^App) {
	for len(app.screenshot_names) > 0 {
		pixels, w, h, ok := gpu.screenshot_take(&app.g, context.temp_allocator)
		if !ok {return}
		name := pop_front(&app.screenshot_names)
		defer delete(name)
		png, err := base.png_encode(w, h, pixels, context.temp_allocator)
		if err != nil {
			log.errorf("screenshot cannot encode error=%v", err)
			continue
		}
		dir := path_next_to_exe(app.screenshot_dir if app.screenshot_dir != "" else "screenshots")
		os.make_directory_all(dir)
		path :=
			filepath.join(
				{dir, strings.concatenate({name, ".png"}, context.temp_allocator)},
				context.temp_allocator,
			) or_else name
		if werr := os.write_entire_file(path, png); werr != nil {
			log.errorf("screenshot cannot write path=%s error=%v", path, werr)
			if app.scene.phase == .Shooting {
				app.script_failed, app.quit = true, true
			}
			continue
		}
		log.infof("screenshot saved path=%s size=%dx%d", path, w, h)
		if app.scene.phase == .Shooting {
			counts_path :=
				filepath.join(
					{dir, strings.concatenate({name, ".counts"}, context.temp_allocator)},
					context.temp_allocator,
				) or_else name
			if !app.scene.counted {
				log.errorf("scene %s: its picture's frame was not counted", app.scene.name)
				app.script_failed, app.quit = true, true
				continue
			}
			text := scene_counts_text(app.scene.counts, context.temp_allocator)
			if werr := os.write_entire_file(counts_path, transmute([]u8)text); werr != nil {
				log.errorf("scene cannot write path=%s error=%v", counts_path, werr)
				app.script_failed, app.quit = true, true
				continue
			}
			app.scene.phase, app.quit = .Done, true // (the scene's picture: its run is over)
		}
		toast(app, .Screenshot_Saved, on_click = open_screenshots)
	}
}

// scene_counts_text: c as `name value` lines (build images reads them back:
// tools/build/images.odin, images_counts_parse).
scene_counts_text :: proc(c: Scene_Counts, allocator := context.allocator) -> string {
	return fmt.aprintf(
		"world_meshes %d\nworld_triangles %d\ndraw_calls %d\napi_draw_calls %d\nworld_api_draw_calls %d\nframe_triangles %d\n",
		c.world_meshes,
		c.world_triangles,
		c.draw_calls,
		c.api_draw_calls,
		c.world_api_draw_calls,
		c.frame_triangles,
		allocator = allocator,
	)
}

// scene_count records what the frame just recorded drew, if it is a
// scene's picture (the screenshot was asked for before it): call after
// gpu.end_frame.
scene_count :: proc(app: ^App) {
	if app.scene.phase != .Shooting || app.scene.counted {return}
	app.scene.counts = {
		world_meshes         = app.world_pass.stats.drawn,
		world_triangles      = app.world_pass.stats.triangles,
		draw_calls           = app.g.draws.calls,
		api_draw_calls       = app.g.draws.api_calls,
		world_api_draw_calls = app.world_pass.stats.api_draws,
		frame_triangles      = app.g.draws.triangles,
	}
	app.scene.counted = true
}
