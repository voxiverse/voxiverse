package client

import "core:log"
import "core:math"

import "../base"

// The GPU's check, as a console command: `view_test <frames> [quit]` waits
// for the world around the player to load and mesh, then turns the camera
// through eight directions at two pitches (the horizon, and down onto the
// land), holding each for <frames> frames, and records the GPU's frame time
// and the triangles drawn. The same views every run from the same place:
// what changes in the renderer shows as time and triangles alone (logged,
// and a line in build/perf-history.jsonl). Run with vsync off.
//
//	voxiverse --exec "set vsync 0; singleplayer; view_test 120 quit"

View_Test_Phase :: enum u8 {
	Off,
	Loading,
	Viewing,
}

View_Test :: struct {
	using check: Exit_Check,
	phase:       View_Test_Phase,
	per_view:    int, // frames each view is held
	view:        int,
	frame:       int, // into this view
	waited:      f32,
	gpu:         base.Frame_Stats, // GPU ms a frame, settled frames only
	triangles:   base.Frame_Stats, // thousands a frame
}

VIEW_TEST_YAWS :: 8
VIEW_TEST_PITCHES :: [2]f32{-0.1, -0.6}
VIEW_TEST_SETTLE :: 8 // frames after turning before measuring (GPU timings arrive late)
VIEW_TEST_LOAD_TIMEOUT :: 60

@(private)
view_test_command :: proc(app: ^App, args: []string) {
	t := &app.view_test
	frames, ok := exit_check_start(app, &t.check, "view_test", args)
	if !ok {return}
	t.phase, t.per_view, t.view, t.frame, t.waited =
		.Loading, max(int(frames), VIEW_TEST_SETTLE + 1), 0, 0, 0
	t.gpu, t.triangles = {}, {}
	log.infof("view_test waiting for the world frames_per_view=%d", t.per_view)
}

@(private)
view_test_update :: proc(app: ^App) {
	t := &app.view_test
	s := app.session
	if t.phase == .Off {return}
	if s == nil || (t.phase == .Viewing && s.state != .Playing) {
		view_test_finish(app, "left the world")
		return
	}
	switch t.phase {
	case .Off:
	case .Loading:
		t.waited += app.last_frame_ms / 1000
		if !world_settled(app) {
			if t.waited >
			   VIEW_TEST_LOAD_TIMEOUT {view_test_finish(app, "the world did not finish loading")}
			return
		}
		t.phase = .Viewing
		log.infof("view_test loaded seconds=%.1f", t.waited)
	case .Viewing:
		pitches := VIEW_TEST_PITCHES
		yaw := f32(t.view % VIEW_TEST_YAWS) * 2 * math.PI / VIEW_TEST_YAWS
		s.camera.yaw, s.camera.pitch = yaw, pitches[t.view / VIEW_TEST_YAWS]
		if t.frame >= VIEW_TEST_SETTLE {
			g := &app.g.gpu_frame_stats
			if g.count >
			   0 {base.frame_stats_add(&t.gpu, g.recent[(g.count - 1) % base.FRAME_STATS_WINDOW])}
			base.frame_stats_add(&t.triangles, f32(app.world_pass.stats.triangles) / 1000)
		}
		t.frame += 1
		if t.frame < t.per_view {return}
		t.frame = 0
		t.view += 1
		if t.view == VIEW_TEST_YAWS * len(VIEW_TEST_PITCHES) {view_test_finish(app, "")}
	}
}

@(private = "file")
view_test_finish :: proc(app: ^App, error: string) {
	t := &app.view_test
	failures := make([dynamic]string, context.temp_allocator)
	if error != "" {append(&failures, error)}
	if error == "" {
		gpu := base.frame_stats_summary(&t.gpu)
		tri := base.frame_stats_summary(&t.triangles)
		log.infof(
			"view_test views=%d gpu_ms avg=%.3f p50=%.3f p99=%.3f triangles_k avg=%.0f max=%.0f",
			t.view,
			gpu.avg,
			gpu.p50,
			gpu.p99,
			tri.avg,
			tri.max,
		)
		base.perf_history_append(
			"view_test",
			{
				{"gpu_avg_ms", f64(gpu.avg)},
				{"gpu_p50_ms", f64(gpu.p50)},
				{"gpu_p99_ms", f64(gpu.p99)},
				{"triangles_k_avg", f64(tri.avg)},
				{"triangles_k_max", f64(tri.max)},
				{"meshes", f64(app.world_pass.stats.meshes)},
			},
		)
	}
	t.phase = .Off
	exit_check_finish(app, &t.check, failures[:])
}
