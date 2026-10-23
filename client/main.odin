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
	context = base.debug_begin(&dbg, "voxiverse.log")

	opts: Options
	flags.parse_or_exit(&opts, os.args, .Unix)
	if base.PROFILE {
		path := path_next_to_exe("voxiverse.spall")
		if base.profile_start(path) {
			log.infof("profiling to %s (open with Spall: https://gravitymoth.com/spall/)", path)
		}
	}
	ok := run(opts)
	base.profile_stop()
	ok = base.debug_end(&dbg) && ok
	os.exit(0 if ok else 1)
}

run :: proc(opts: Options) -> bool {
	app := new(App)
	defer free(app)

	// The console shows the log too (from here on).
	app_logger := log.create_multi_logger(context.logger, console_logger(&app.console))
	defer log.destroy_multi_logger(app_logger)
	context.logger = app_logger

	ok := app_init(app)
	if ok {
		for command in split_semicolons(opts.exec) {console_execute(app, command)}
		frames := 0
		last := time.tick_now()
		for opts.frames == 0 || frames < opts.frames {
			free_all(context.temp_allocator)
			capture := opts.capture_frame > 0 && frames + 1 == opts.capture_frame
			if !app_frame(app, capture) {break}
			frames += 1
			now := time.tick_now()
			app.last_frame_ms = f32(time.duration_milliseconds(time.tick_diff(last, now)))
			base.frame_stats_add(&app.frame_stats, app.last_frame_ms)
			last = now
		}
		log_frame_stats(&app.frame_stats)
		if app.ui.errors > 0 {
			log.errorf("%d UI error(s) during this run (see above)", app.ui.errors)
			ok = false
		}
		if app.fly_test.failed || app.fly_test.phase != .Off {
			if app.fly_test.phase !=
			   .Off {log.error("fly_test: the run ended before the test finished")}
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
		"frame time: %d frames, avg %.2f ms, p50 %.2f, p99 %.2f, max %.2f",
		sum.count,
		sum.avg,
		sum.p50,
		sum.p99,
		sum.max,
	)
}

@(private)
split_semicolons :: proc(s: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	start := 0
	for i in 0 ..= len(s) {
		if i == len(s) || s[i] == ';' {
			append(&out, s[start:i])
			start = i + 1
		}
	}
	return out[:]
}
