package client

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"


// Shader hot reload (development builds, `debug.hot_reload_shaders`): when a
// file in assets/shaders changes, run the build driver's `shaders` command
// (recompiles what changed with the pinned glslang) and rebuild the
// pipelines that use it. A shader that fails to compile logs glslang's
// message and keeps the old pipeline running.

Shader_Watch :: struct {
	sources: string, // assets/shaders
	repo:    string,
	driver:  string, // build/build-driver
	times:   map[string]time.Time, // source file -> last seen modification time
	timer:   f32,
	ready:   bool,
}

@(private = "file")
WATCH_INTERVAL :: 0.5 // seconds

// shader_watch_init finds the sources next to the executable's build/
// folder; without them (a shipped game) it stays off.
shader_watch_init :: proc(w: ^Shader_Watch) {
	w^ = {}
	when !ODIN_DEBUG {return}
	exe_dir, err := os.get_executable_directory(context.temp_allocator)
	if err != nil {return}
	repo := filepath.dir(exe_dir)
	sources := filepath.join({repo, "assets", "shaders"}, context.temp_allocator) or_else ""
	driver :=
		filepath.join(
			{exe_dir, "build-driver.exe" when ODIN_OS == .Windows else "build-driver"},
			context.temp_allocator,
		) or_else ""
	if !os.exists(sources) || !os.exists(driver) {
		log.debugf(
			"shader hot reload off: no sources or build driver sources=%s driver=%s",
			sources,
			driver,
		)
		return
	}
	w.repo, w.sources, w.driver =
		strings.clone(repo), strings.clone(sources), strings.clone(driver)
	w.times = make(map[string]time.Time)
	scan(w) // the starting state: nothing has changed yet
	w.ready = true
	log.debugf("shader hot reload on sources=%s", sources)
}

shader_watch_destroy :: proc(w: ^Shader_Watch) {
	for k in w.times {delete(k)}
	delete(w.times)
	delete(w.repo)
	delete(w.sources)
	delete(w.driver)
	w^ = {}
}

// shader_watch_update checks for changes every half second.
shader_watch_update :: proc(app: ^App, dt: f32) {
	w := &app.shader_watch
	if !w.ready || !app.debug.hot_reload_shaders {return}
	w.timer += dt
	if w.timer < WATCH_INTERVAL {return}
	w.timer = 0
	changed := scan(w)
	if len(changed) == 0 {return}

	state, stdout, stderr, err := os.process_exec(
		{working_dir = w.repo, command = {w.driver, "shaders"}},
		context.temp_allocator,
	)
	if err != nil || !state.exited || state.exit_code != 0 {
		log.errorf(
			"shader compile failed; keeping the old shaders exit_code=%d error=%v",
			state.exit_code,
			err,
		)
		for line in strings.split_lines(strings.concatenate({string(stdout), string(stderr)}, context.temp_allocator), context.temp_allocator) {
			if strings.trim_space(line) != "" {log.error(line)}
		}
		return
	}
	// Reload each pass whose shaders changed (an include: every pass that
	// uses it), once.
	reload: bit_set[Pass]
	for name in changed {
		for info, p in PASSES {
			if filepath.stem(name) == info.shader ||
			   (filepath.ext(name) == ".glsl" && info.scene) {
				reload += {p}
			}
		}
	}
	for p in reload {
		info := PASSES[p]
		vert, frag, read := pass_shaders(info)
		if !read {continue}
		if info.reload(app, vert, frag) {
			log.infof("shader reloaded pass=%s", info.shader)
		} else {
			log.errorf("shader reload failed pass=%s", info.shader)
		}
	}
}

// scan records modification times and returns the files that changed.
@(private = "file")
scan :: proc(w: ^Shader_Watch) -> []string {
	changed := make([dynamic]string, context.temp_allocator)
	entries, err := os.read_all_directory_by_path(w.sources, context.temp_allocator)
	if err != nil {return nil}
	for e in entries {
		ext := filepath.ext(e.name)
		if ext != ".vert" && ext != ".frag" && ext != ".comp" && ext != ".glsl" {continue}
		old, seen := w.times[e.name]
		if !seen {
			w.times[strings.clone(e.name)] = e.modification_time // new: the starting state
		} else if old != e.modification_time {
			w.times[e.name] = e.modification_time
			append(&changed, e.name)
		}
	}
	return changed[:]
}
