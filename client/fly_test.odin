package client

import "core:fmt"
import "core:log"
import "core:math"
import "core:strconv"

import "../base"
import "../server"

// The M3 exit check, as a console command: `fly_test <blocks> [quit]` waits
// for the world around the spawn to load, then flies the camera in a
// straight line and checks that memory stays put while it streams in new
// terrain and drops the old: the session arenas must not grow at all, and
// chunk storage must stay within the sizes fixed at join. It logs frame
// times for the flight and, with `quit`, ends the program (failing the run
// if a check failed).
//
//	voxiverse --exec "singleplayer; fly_test 1500 quit"

Fly_Test_Phase :: enum u8 {
	Off,
	Loading,
	Flying,
}

Fly_Test :: struct {
	phase:        Fly_Test_Phase,
	distance:     f64, // blocks to fly
	start:        [3]f64,
	quit:         bool,
	waited:       f32, // seconds spent loading
	frames:       base.Frame_Stats,
	client_arena: uint,
	server_arena: uint,
	rss_start:    int,
	failed:       bool,
}

FLY_TEST_SPEED :: 40 // blocks per second (a sprint in most games)
FLY_TEST_LOAD_TIMEOUT :: 60 // seconds

@(private)
fly_test_command :: proc(app: ^App, args: []string) {
	if len(args) < 1 {
		console_print(&app.console, "fly_test <blocks> [quit]", .Warning)
		return
	}
	distance, ok := strconv.parse_f64(args[0])
	if !ok || distance <= 0 {
		console_print(&app.console, "fly_test: give a distance in blocks", .Warning)
		return
	}
	if app.session == nil {enter_world(app)}
	if app.session == nil {return}
	t := &app.fly_test
	frames := t.frames // keep the (large) stats buffer's storage
	t^ = {
		phase    = .Loading,
		distance = distance,
		quit     = len(args) > 1 && args[1] == "quit",
		frames   = frames,
	}
	t.frames.count = 0
	log.infof("fly_test waiting for the world to load blocks=%.0f", distance)
}

@(private)
fly_test_update :: proc(app: ^App) {
	t := &app.fly_test
	s := app.session
	if t.phase == .Off || s == nil {return}
	dt := app.last_frame_ms / 1000
	switch t.phase {
	case .Off:
	case .Loading:
		t.waited += dt
		if s.state != .Playing {
			if t.waited > FLY_TEST_LOAD_TIMEOUT {fly_test_finish(app, "never joined the world")}
			return
		}
		if !world_settled(app) {
			if t.waited >
			   FLY_TEST_LOAD_TIMEOUT {fly_test_finish(app, "the world did not finish loading")}
			return
		}
		// Above the spawn's hills, facing +x.
		s.camera.position.y += 20
		s.camera.yaw, s.camera.pitch = -math.PI / 2, -0.4
		t.start = s.camera.position
		t.client_arena = s.arena.total_used
		t.server_arena = server.stats(&s.server).arena_used
		t.rss_start = base.resident_memory()
		t.phase = .Flying
		screenshot_request(app, "fly_test_start")
		log.infof(
			"fly_test loaded seconds=%.1f chunks=%d speed=%d",
			t.waited,
			s.world.chunks.count,
			FLY_TEST_SPEED,
		)
	case .Flying:
		if s.state != .Playing {
			fly_test_finish(app, "left the world mid-flight")
			return
		}
		base.frame_stats_add(&t.frames, app.last_frame_ms)
		s.camera.position.x += f64(min(dt, 0.1)) * FLY_TEST_SPEED // a hitch must not skip terrain
		if s.camera.position.x - t.start.x >= t.distance {fly_test_finish(app, "")}
	}
}

@(private = "file")
fly_test_finish :: proc(app: ^App, error: string) {
	t := &app.fly_test
	s := app.session
	failures := make([dynamic]string, context.temp_allocator)
	if error != "" {append(&failures, error)}
	if error == "" {
		st := server.stats(&s.server)
		if s.arena.total_used != t.client_arena {
			append(
				&failures,
				fmt.tprintf(
					"client session arena grew from %d to %d bytes",
					t.client_arena,
					s.arena.total_used,
				),
			)
		}
		if st.arena_used != t.server_arena {
			append(
				&failures,
				fmt.tprintf(
					"server session arena grew from %d to %d bytes",
					t.server_arena,
					st.arena_used,
				),
			)
		}
		w := &s.world
		capacity := len(w.chunks.items) - 1
		if w.arrays.allocated > capacity {append(&failures, "client chunk arrays past capacity")}
		if st.arrays_allocated >
		   server.block_capacity(
			   &s.server,
		   ) {append(&failures, "server chunk arrays past capacity")}
		sum := base.frame_stats_summary(&t.frames)
		log.infof(
			"fly_test flew blocks=%.0f frames=%d avg_ms=%.2f p50=%.2f p99=%.2f max=%.2f",
			s.camera.position.x - t.start.x,
			sum.count,
			sum.avg,
			sum.p50,
			sum.p99,
			sum.max,
		)
		log.infof(
			"fly_test memory client_chunks=%d client_capacity=%d client_arrays_mib=%.1f client_arena=%d server_chunks=%d server_arrays_mib=%.1f server_arena=%d stale_meshes=%d",
			w.chunks.count,
			capacity,
			f64(w.arrays.committed) / (1 << 20),
			s.arena.total_used,
			st.chunks_loaded,
			f64(st.arrays_bytes) / (1 << 20),
			st.arena_used,
			w.stats.stale_meshes,
		)
		if rss := base.resident_memory(); rss > 0 && t.rss_start > 0 {
			log.infof(
				"fly_test resident memory start_mib=%.1f end_mib=%.1f",
				f64(t.rss_start) / (1 << 20),
				f64(rss) / (1 << 20),
			)
		}
	}
	for f in failures {log.errorf("fly_test %s", f)}
	if len(failures) == 0 {log.info("fly_test passed")}
	if s != nil {screenshot_request(app, "fly_test_end")} 	// saved at exit too
	t.failed = len(failures) > 0
	t.phase = .Off
	if t.quit {app.quit = true}
}
