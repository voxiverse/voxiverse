package client

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "../base"
import "../gpu"

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
		dir := path_next_to_exe("screenshots")
		os.make_directory_all(dir)
		path :=
			filepath.join(
				{dir, strings.concatenate({name, ".png"}, context.temp_allocator)},
				context.temp_allocator,
			) or_else name
		if werr := os.write_entire_file(path, png); werr != nil {
			log.errorf("screenshot cannot write path=%s error=%v", path, werr)
			continue
		}
		log.infof("screenshot saved path=%s size=%dx%d", path, w, h)
	}
}
