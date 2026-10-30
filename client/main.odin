package client

import "core:flags"
import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"

import "../base"

// Entry point: debugging setup, then the App's lifetime and frame loop.
// `--frames N` exits after N frames and fails the run on any validation
// finding or leak (CI and quick checks); `--capture-frame N` captures that
// frame when started from RenderDoc; `--exec "cmd; cmd"` runs console
// commands at startup (scripted checks, screenshots, reproducing bugs);
// `--benchmark <scenario>` runs a benchmark (benchmark.odin) and quits;
// `--check <name>` an exit check (exit_check.odin).

Options :: struct {
	frames:        int `usage:"exit after this many frames (0: run until closed)"`,
	capture_frame: int `usage:"when started from RenderDoc, capture this frame (1 = first)"`,
	exec:          string `usage:"console commands to run at startup, separated by ';'"`,
	benchmark:     string `usage:"run a benchmark scenario (load, views, flight, edits) with fixed settings, write its result, quit"`,
	null_audio:    bool `usage:"mix into the null device (real time, no sound card) instead of the card"`,
	smoke:         bool `usage:"with --benchmark: one short repetition (CI: the scenario still works)"`,
	bench_size:    string `usage:"with --benchmark: draw at WIDTHxHEIGHT instead of 1280x720 (results under <scenario>-WIDTHxHEIGHT)"`,
	check:         string `usage:"run an exit check (fly, tour, blast) after any --exec script, and quit: fails the run if it fails"`,
	version:       bool `usage:"print the version and quit"`,
}

main :: proc() {
	opts: Options
	flags.parse_or_exit(&opts, os.args, .Unix, context.temp_allocator)
	if opts.version {
		fmt.printfln("Voxiverse %s (%s build)", base.version_text(), base.build_name())
		os.exit(0)
	}
	dbg: base.Debug
	context = base.debug_begin(&dbg, "voxiverse.log", "main")
	log.infof("Voxiverse %s (%s build)", base.version_text(), base.build_name())
	if base.PROFILE {
		path := path_next_to_exe("voxiverse.spall")
		if base.profile_start(path) {
			base.profile_name_process(base.profile_process_name("client"))
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
	scenario: Scenario
	if opts.benchmark != "" {
		found: bool
		if scenario, found = scenario_find(opts.benchmark); !found {
			log.errorf(
				"no benchmark scenario %q (there are: %s)",
				opts.benchmark,
				scenario_names(),
			)
			return false
		}
		app.benchmark = true
	}
	check: Check_Info
	bench_size := BENCH_SIZE
	if opts.bench_size != "" {
		size, ok := parse_size(opts.bench_size)
		if !ok {
			fmt.eprintfln(
				"--bench-size: '%s' is not WIDTHxHEIGHT (such as 2560x1440)",
				opts.bench_size,
			)
			os.exit(2)
		}
		bench_size = size
	}
	if opts.check != "" {
		found: bool
		if check, found = check_find(opts.check); !found {
			names := make([dynamic]string, context.temp_allocator)
			for c in CHECKS {append(&names, c.name)}
			log.errorf(
				"no check %q (there are: %s)",
				opts.check,
				strings.join(names[:], ", ", context.temp_allocator),
			)
			return false
		}
		app.checking = true
	}
	check_pending := opts.check != ""

	// The console shows the log too (from here on).
	base.log_set_listener(sink, console_listener, &app.console)
	defer base.log_set_listener(sink, nil, nil)

	app.null_audio = opts.null_audio || opts.check == "audio"
	ok := app_init(app)
	if ok {
		if app.benchmark {bench_begin(app, scenario, opts.smoke, bench_size)}
		script: Script
		script_init(&script, opts.exec)
		defer script_destroy(&script)
		frames := 0
		last := time.tick_now()
		for opts.frames == 0 || frames < opts.frames {
			free_all(context.temp_allocator)
			script_run(app, &script)
			if check_pending && script_done(&script) {
				// The check's view (its settings are the benchmarks' otherwise).
				check_pending = false
				app.fixed_view = {check.view_radius, check.view_height}
				log.infof("check %s: %s", check.name, check.description)
				check.start(app)
			}
			capture := opts.capture_frame > 0 && frames + 1 == opts.capture_frame
			if !app_frame(app, capture, frames + 1) {break}
			{
				base.profile_scope("benchmark driver")
				bench_update(app) // between frames: it may leave and join worlds
			}
			frames += 1
			if cap := frame_cap(app); cap > 0 {
				if spent := time.tick_since(last); spent < cap {
					base.profile_scope("frame cap (sleep)")
					time.sleep(cap - spent)
				}
			}
			now := time.tick_now()
			app.last_frame_ms = f32(time.duration_milliseconds(time.tick_diff(last, now)))
			app.seconds = math.mod(app.seconds + app.last_frame_ms / 1000, 1000)
			base.frame_stats_add(&app.frame_stats, app.last_frame_ms)
			if app.screen == .Game {
				base.frame_stats_add(
					&app.triangle_stats,
					f32(app.world_pass.stats.triangles) / 1000,
				)
				base.metric_add(.World_Triangles, f32(app.world_pass.stats.triangles) / 1000)
				base.metric_add(.World_Meshes, f32(app.world_pass.stats.drawn))
				base.metric_add(.Draw_Calls, f32(app.g.draws.calls))
				base.metric_add(.Frame_Triangles, f32(app.g.draws.triangles) / 1000)
			}
			base.metric_add(.Frame, app.last_frame_ms)
			fps_update(&app.fps, app.last_frame_ms, &app.g.gpu_frame_stats)
			last = now
		}
		log_frame_stats(&app.frame_stats)
		if o := app.world_pass.occlusion_stats; o.frames > 0 {
			log.infof(
				"render occlusion frames=%d chunks_drawn=%.0f hidden=%.0f (%.0f%% of them passed no pixel)",
				o.frames,
				f64(o.queried) / f64(o.frames),
				f64(o.hidden) / f64(o.frames),
				100 * f64(o.hidden) / f64(max(o.queried, 1)),
			)
		}
		if t := base.frame_stats_summary(&app.triangle_stats); t.count > 0 {
			log.infof(
				"render triangles_k frames=%d avg=%.0f p50=%.0f p99=%.0f max=%.0f",
				t.count,
				t.avg,
				t.p50,
				t.p99,
				t.max,
			)
		}
		if app.ui.errors > 0 {
			log.errorf("%d UI error(s) during this run (see above)", app.ui.errors)
			ok = false
		}
		if app.benchmark && (app.bench.failed || !app.bench.done) {
			if !app.bench.done {log.error("bench the run ended before the scenario finished")}
			ok = false
		}
		if app.fly_test.failed || app.fly_test.phase != .Off {
			if app.fly_test.phase !=
			   .Off {log.error("fly_test the run ended before the test finished")}
			ok = false
		}
		if app.tour_test.failed || app.tour_test.phase != .Off {
			if app.tour_test.phase !=
			   .Off {log.error("tour_test the run ended before the test finished")}
			ok = false
		}
		if app.audio_check.failed || app.audio_check.phase != .Off {
			if app.audio_check.phase !=
			   .Off {log.error("audio_check the run ended before the test finished")}
			ok = false
		}
		if app.blast_test.failed || app.blast_test.phase != .Off {
			if app.blast_test.phase !=
			   .Off {log.error("blast_test the run ended before the test finished")}
			ok = false
		}
	}
	server_failed := app.server_failed
	// app_destroy frees the console: later lines must not reach it.
	base.log_set_listener(sink, nil, nil)
	issues := app_destroy(app) // leaves any world, so server failures are known after
	if app.server_failed || server_failed || app.script_failed {ok = false}
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
