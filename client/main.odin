package client

import "core:flags"
import "core:log"
import "core:os"
import "core:time"

import "../base"

// Entry point: debugging setup, then the App's lifetime and frame loop.
// `--frames N` exits after N frames and fails the run on any validation
// finding or leak (CI and quick checks); `--capture-frame N` captures that
// frame when started from RenderDoc; `--exec "cmd; cmd"` runs console
// commands at startup (scripted checks, screenshots, reproducing bugs).

Options :: struct {
	frames:        int `usage:"exit after this many frames (0: run until closed)"`,
	capture_frame: int `usage:"when started from RenderDoc, capture this frame (1 = first)"`,
	exec:          string `usage:"console commands to run at startup, separated by ';'"`,
}

main :: proc() {
	dbg: base.Debug
	context = base.debug_begin(&dbg, "voxiverse.log", "main")

	opts: Options
	flags.parse_or_exit(&opts, os.args, .Unix)
	if base.PROFILE {
		path := path_next_to_exe("voxiverse.spall")
		if base.profile_start(path) {
			log.infof("profiling to %s (open with Spall: https://gravitymoth.com/spall/)", path)
		}
	}
	ok := run(opts, &dbg.sink)
	base.profile_stop()
	ok = base.debug_end(&dbg) && ok
	os.exit(0 if ok else 1)
}

run :: proc(opts: Options, sink: ^base.Log_Sink) -> bool {
	app := new(App)
	defer free(app)

	// The console shows the log too (from here on).
	base.log_set_listener(sink, console_listener, &app.console)
	defer base.log_set_listener(sink, nil, nil)

	ok := app_init(app)
	if ok {
		script: Script
		script_init(&script, opts.exec)
		defer script_destroy(&script)
		frames := 0
		last := time.tick_now()
		for opts.frames == 0 || frames < opts.frames {
			free_all(context.temp_allocator)
			script_run(app, &script)
			capture := opts.capture_frame > 0 && frames + 1 == opts.capture_frame
			if !app_frame(app, capture) {break}
			frames += 1
			now := time.tick_now()
			app.last_frame_ms = f32(time.duration_milliseconds(time.tick_diff(last, now)))
			base.frame_stats_add(&app.frame_stats, app.last_frame_ms)
			fps_update(&app.fps, app.last_frame_ms, &app.g.gpu_frame_stats)
			last = now
		}
		log_frame_stats(&app.frame_stats)
		if app.ui.errors > 0 {
			log.errorf("%d UI error(s) during this run (see above)", app.ui.errors)
			ok = false
		}
		if app.fly_test.failed || app.fly_test.phase != .Off {
			if app.fly_test.phase !=
			   .Off {log.error("fly_test the run ended before the test finished")}
			ok = false
		}
	}
	server_failed := app.server_failed
	issues := app_destroy(app) // leaves any world, so server failures are known after
	if app.server_failed || server_failed {ok = false}
	if issues > 0 {
		log.errorf("%d validation finding(s) during this run", issues)
		return false
	}
	return ok
}

// log_frame_stats prints the run's frame times: wall clock per frame, vsync
// included. (GPU times are logged by gpu.destroy, once all are in.)
log_frame_stats :: proc(s: ^base.Frame_Stats) {
	sum := base.frame_stats_summary(s)
	if sum.count == 0 {return}
	log.infof(
		"frame times frames=%d avg_ms=%.2f p50=%.2f p99=%.2f max=%.2f",
		sum.count,
		sum.avg,
		sum.p50,
		sum.p99,
		sum.max,
	)
}
